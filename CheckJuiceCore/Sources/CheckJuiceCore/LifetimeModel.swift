import Foundation

/// 分组统计结果（log 尺度）。
public struct WeightedLogStats: Sendable, Equatable {
    /// 加权均值。
    public var mean: Double
    /// 加权方差。样本不足时为 `nil`（方差不可识别）。
    public var variance: Double?
    /// Kish 有效样本量。
    public var effectiveSampleSize: Double
}

/// 电池寿命预测模型。
///
/// 数学骨架：**对数正态 + 正态共轭**。
/// 寿命非负且右偏（偶尔碰上一颗特别差的电池，但不会有负数），
/// 所以建模 `log(寿命) ~ Normal(m, σ²)`——天然非负，且有闭式解，
/// 不需要采样、不需要数值优化。
///
/// 本实现与 Python 参考实现 `reference/lifetime_model.py` **逐行等价**，
/// 数值一致性由 `GoldenValueTests` 用导出的黄金期望值锁定。
///
/// 刻意**不声明 `Sendable`**：`Calendar` 是否 Sendable 依赖 SDK 版本，
/// 而本机没有 Swift 工具链、无法编译验证。核心类型的 `Sendable` 已经足够，
/// 不为了一个用不上的修饰符去赌 CI。
public struct LifetimeModel {
    public let config: ModelConfig
    public let calendar: Calendar

    public init(config: ModelConfig = .standard, calendar: Calendar = .checkJuiceUTC) {
        self.config = config
        self.calendar = calendar
    }

    // MARK: - 日期工具

    /// 相差多少个「日历天」。用 startOfDay 计算，规避夏令时导致的 23/25 小时天。
    public func dayCount(from: Date, to: Date) -> Int {
        let start = calendar.startOfDay(for: from)
        let end = calendar.startOfDay(for: to)
        return calendar.dateComponents([.day], from: start, to: end).day ?? 0
    }

    /// 加若干天。
    public func date(byAddingDays days: Int, to date: Date) -> Date {
        calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: date)) ?? date
    }

    /// 四舍五入（正数下等价于 away-from-zero）。
    ///
    /// ⚠️ 必须显式定义：Python 内建 `round()` 是银行家舍入（`round(0.5) == 0`），
    /// 与 Swift 的 `.rounded()` 在 `.5` 边界上会差 1 天。参考实现里已用
    /// `floor(x + 0.5)` 钉死口径，这里保持一致。
    public static func roundHalfUp(_ x: Double) -> Int {
        guard x.isFinite else { return 0 }
        let r = (x + 0.5).rounded(.down)
        guard r > Double(Int.min), r < Double(Int.max) else { return 0 }
        return Int(r)
    }

    // MARK: - 先验

    /// 返回 `(log 中位寿命, 不确定度)`。
    /// 优先级：参照设备 > 用户手填 > 电池种类典型值。
    public func prior(of device: Device) -> (logMedian: Double, tau: Double) {
        if let reference = device.referencePrior {
            return (reference.logMedian, reference.tau)
        }
        if let life = device.nominalLifeDays, life > 0 {
            return (log(life), config.tauUser)
        }
        return (log(device.kind.typicalLifeDays), config.tauDefault)
    }

    // MARK: - 观测提取

    /// 把事件序列拆成有效间隔与截尾间隔。
    ///
    /// * 有效间隔：终点事件为 `.exhausted` → 计入寿命统计
    /// * 截尾间隔：终点事件为 `.preventive` / `.faulty` → 剔除出寿命统计
    ///   （但起算点照样重置，这一点由 `Device.installedAt` 保证）
    public func observedIntervals(
        _ device: Device
    ) -> (exhausted: [Double], censored: [(days: Double, kind: EventKind)]) {
        let events = device.sortedEvents
        var exhausted: [Double] = []
        var censored: [(days: Double, kind: EventKind)] = []
        guard events.count >= 2 else { return (exhausted, censored) }

        for index in 1..<events.count {
            let previous = events[index - 1]
            let current = events[index]
            let days = Double(dayCount(from: previous.at, to: current.at))
            guard days > 0 else { continue }

            if current.kind.countsAsLifetimeSample {
                exhausted.append(days)
            } else if current.kind.isCensored {
                censored.append((days, current.kind))
            }
            // .initial 不作为间隔终点，忽略。
        }
        return (exhausted, censored)
    }

    // MARK: - 加权统计

    /// 对 log 尺度的观测做指数加权统计。
    ///
    /// 近期观测权重更大（`w_i = β^(n-1-i)`），因为设备老化和季节变化是渐进的。
    /// 加权方差使用可靠性权重下的无偏估计，分母为 `Σw − Σw²/Σw`。
    public func weightedLogStats(_ values: [Double]) -> WeightedLogStats {
        let n = values.count
        guard n > 0 else {
            return WeightedLogStats(mean: 0, variance: nil, effectiveSampleSize: 0)
        }

        var weights = [Double](repeating: 0, count: n)
        for i in 0..<n {
            weights[i] = pow(config.beta, Double(n - 1 - i))
        }

        var sumW = 0.0
        var sumW2 = 0.0
        var sumWX = 0.0
        for i in 0..<n {
            sumW += weights[i]
            sumW2 += weights[i] * weights[i]
            sumWX += weights[i] * values[i]
        }
        let mean = sumWX / sumW

        let denominator = sumW - sumW2 / sumW
        var variance: Double?
        if n >= config.minSamplesForVariance && denominator > 1e-9 {
            var accumulator = 0.0
            for i in 0..<n {
                let deviation = values[i] - mean
                accumulator += weights[i] * deviation * deviation
            }
            variance = accumulator / denominator
        }

        return WeightedLogStats(
            mean: mean,
            variance: variance,
            effectiveSampleSize: sumW * sumW / sumW2
        )
    }

    // MARK: - 拟合

    /// 共轭更新：把观测到的寿命间隔融进先验，得到参数后验。
    /// 没有事件（或只有首次安装）时返回 `nil`。
    public func fit(_ device: Device) -> Posterior? {
        guard device.installedAt != nil else { return nil }

        let (priorMean, priorTau) = prior(of: device)
        let observations = observedIntervals(device).exhausted

        // 纯先验：此时「设备内波动」完全未知，与先验不确定度同宽。
        guard !observations.isEmpty else {
            return Posterior(
                logMean: priorMean,
                logSigma: priorTau,
                effectiveSampleSize: 0,
                observedCount: 0,
                withinDeviceSigma: priorTau
            )
        }

        let logs = observations.map { log($0) }
        let stats = weightedLogStats(logs)

        // 设备内固有波动。样本不足时不敢信样本方差，用兜底值。
        let withinSigma: Double
        if let sampleVariance = stats.variance {
            withinSigma = max(sampleVariance.squareRoot(), config.sigmaMin)
        } else {
            withinSigma = config.sigmaUnidentified
        }

        // 后验精度 = 先验精度 + 数据精度
        let priorPrecision = 1.0 / (priorTau * priorTau)
        let dataPrecision = stats.effectiveSampleSize / (withinSigma * withinSigma)
        let precision = priorPrecision + dataPrecision
        let posteriorMean =
            (priorMean * priorPrecision + stats.effectiveSampleSize * stats.mean / (withinSigma * withinSigma))
            / precision
        let posteriorSigma = max(1.0 / precision.squareRoot(), config.sigmaMin)

        return Posterior(
            logMean: posteriorMean,
            logSigma: posteriorSigma,
            effectiveSampleSize: stats.effectiveSampleSize,
            observedCount: observations.count,
            withinDeviceSigma: withinSigma
        )
    }

    // MARK: - 预测

    /// 产出完整预测。设备没有事件时返回 `nil`。
    public func predict(_ device: Device, today: Date) -> Prediction? {
        guard let installed = device.installedAt, let posterior = fit(device) else {
            return nil
        }

        let medianDays = exp(posterior.logMean)

        // ★ 关键设计（相对初稿的修订）：
        // 风险窗口要预测的是「**当前这一颗**电池什么时候死」，而不是「期望寿命的下界」。
        // 单颗电池的寿命本身就有 σ_within 的固有波动，再加上对 m 的不确定度 σ_post，
        // 预测分布宽度应为 σ_pred = sqrt(σ_post² + σ_within²)。
        // 只用 σ_post 会把窗口系统性开晚，而本 App 的失败代价正是「没电了才发现」。
        let varianceSum = posterior.logSigma * posterior.logSigma
            + posterior.withinDeviceSigma * posterior.withinDeviceSigma
        let sigmaPrediction = min(varianceSum.squareRoot(), config.sigmaPredictionCap)

        let p10Days = exp(posterior.logMean - config.z10 * sigmaPrediction)

        let medianDate = date(byAddingDays: Self.roundHalfUp(medianDays), to: installed)
        let riskDate = date(byAddingDays: Self.roundHalfUp(p10Days), to: installed)

        let ageDays = dayCount(from: installed, to: today)
        let remainingDays = dayCount(from: today, to: medianDate)
        let riskRemainingDays = dayCount(from: today, to: riskDate)
        let ratio = medianDays > 0 ? Double(ageDays) / medianDays : 1.0

        let urgency: Urgency
        if remainingDays < 0 {
            urgency = .overdue                                   // 已过预测中位日
        } else if riskRemainingDays <= 0 {
            urgency = .risk                                      // 已进入风险窗口（P10 之后）
        } else if riskRemainingDays <= device.notifyLeadDays {
            urgency = .stockUp                                   // 距风险窗口开启不足 lead 天
        } else {
            urgency = .normal
        }

        // ⚠️ 置信度必须显式展示。1 个样本和 10 个样本的预测绝不能画等号。
        let confidence: Confidence
        switch posterior.observedCount {
        case 0, 1: confidence = .low
        case 2, 3: confidence = .medium
        default: confidence = .high
        }

        return Prediction(
            medianDays: medianDays,
            p10Days: p10Days,
            medianDate: medianDate,
            riskDate: riskDate,
            remainingDays: remainingDays,
            riskRemainingDays: riskRemainingDays,
            ageDays: ageDays,
            ratio: ratio,
            sigmaPrediction: sigmaPrediction,
            urgency: urgency,
            confidence: confidence,
            posterior: posterior
        )
    }

    // MARK: - 批量

    /// 为一批设备出预测并按紧急度排序（最紧急在前）。
    /// 小组件与列表页都走这个入口，保证两处排序逻辑一致。
    public func predictions(for devices: [Device], today: Date) -> [(device: Device, prediction: Prediction)] {
        devices
            .compactMap { device in
                guard let prediction = predict(device, today: today) else { return nil }
                return (device: device, prediction: prediction)
            }
            .sorted { lhs, rhs in
                let l = urgencyRank(lhs.prediction.urgency)
                let r = urgencyRank(rhs.prediction.urgency)
                if l != r { return l < r }
                return lhs.prediction.riskRemainingDays < rhs.prediction.riskRemainingDays
            }
    }

    private func urgencyRank(_ urgency: Urgency) -> Int {
        switch urgency {
        case .overdue: return 0
        case .risk: return 1
        case .stockUp: return 2
        case .normal: return 3
        }
    }
}

public extension Calendar {
    /// 模型内部统一使用的 UTC 日历：日粒度运算不受时区 / 夏令时影响。
    ///
    /// 测试与跨设备同步用这个。面向用户的 App 应传入 `Calendar.current`，
    /// 这样「今天」的边界与用户的直觉一致。
    static let checkJuiceUTC: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()
}
