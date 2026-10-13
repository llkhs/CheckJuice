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
/// ## ⚠️ 时间单位一律是**小时**（`Double`），时刻类型是 `Date`
///
/// 早期版本按「日历天」建模，那是错的，两个理由：
///
/// 1. **`Calendar` 的日粒度只有整数天**。真实的 93.6 小时间隔会被读成
///    3 天（72 小时），误差 −23%。而且这种截断**恒向下**，是系统性低估
///    而非随机噪声——它会把预测系统性地推晚，而本 App 的失败代价恰恰是
///    「没电了才发现」。
/// 2. **分辨率不够**。一块标称 4 天的纽扣电池，「1 天」就等于 25% 的粒度，
///    数字看着精确，其实全是量化噪声。
///
/// 对 300 天的电池这两种算法只差 0.16%，看着无所谓；但同一份代码要同时
/// 服务「4 小时」和「3 年」两个量级，就必须选细的那个。
public struct LifetimeModel {
    public let config: ModelConfig
    /// 时区只影响**显示取整**（`floorToHour`），不参与任何模型运算。
    public let timeZone: TimeZone

    public init(config: ModelConfig = .standard, timeZone: TimeZone = .current) {
        self.config = config
        self.timeZone = timeZone
    }

    // MARK: - 时间工具

    /// 两个时刻之间的**精确**小时数（含小数）。
    ///
    /// `Date` 是绝对时刻，`timeIntervalSince` 直接给出秒差——与时区、夏令时无关。
    /// 绝不要退回「日历天 + `dateComponents`」：那会把 93.6 小时砍成 72 小时。
    public static func hoursBetween(from: Date, to: Date) -> Double {
        to.timeIntervalSince(from) / 3600.0
    }

    /// 从某时刻加上若干小时。
    public static func date(byAddingHours hours: Double, to date: Date) -> Date {
        date.addingTimeInterval(hours * 3600.0)
    }

    /// 把时刻**向下**取整到本地整点。
    ///
    /// 显示「将在 XX 耗尽」时必须向下取整：宁可说「23:00」，不要说「次日 00:00」。
    /// 本 App 所有取整一律朝保守方向。
    ///
    /// 与 Python 参考实现的 `floor_to_hour` 口径一致（那边用 naive datetime，即 UTC）。
    /// 测试里请显式传 `TimeZone(secondsFromGMT: 0)!`，否则本地时区会让结果对不上。
    public static func floorToHour(_ date: Date, in timeZone: TimeZone = .current) -> Date {
        let offset = Double(timeZone.secondsFromGMT(for: date))
        let localSeconds = date.timeIntervalSince1970 + offset
        let flooredLocal = (localSeconds / 3600.0).rounded(.down) * 3600.0
        return Date(timeIntervalSince1970: flooredLocal - offset)
    }

    /// 把小时数**朝零截断**到整数小时。
    ///
    /// 为什么朝零而不是向下：两个方向都要「宁少不多」。
    ///   * 剩余 619.4 小时 → 报「619」，不吹牛说自己撑得久；
    ///   * 逾期 619.4 小时 → 报「619」，不把逾期说得比实际更严重。
    /// 若用 `floor`，负数会变成 620 —— 那是**夸大**逾期程度，一样是撒谎。
    ///
    /// 取代了旧版的 `roundHalfUp` —— 那玩意存在的唯一理由是把「浮点天」对齐到
    /// 「整数天」，而「天」这个粒度本身就是 bug。换成小时后不再需要它。
    public static func wholeHours(_ hours: Double) -> Int {
        guard hours.isFinite else { return 0 }
        let truncated = hours.rounded(.towardZero)
        guard truncated > Double(Int.min), truncated < Double(Int.max) else { return 0 }
        return Int(truncated)
    }

    // MARK: - 先验

    /// 返回 `(log 中位寿命, 不确定度)`。
    /// 优先级：参照设备 > 用户手填 > 电池种类典型值。
    public func prior(of device: Device) -> (logMedian: Double, tau: Double) {
        if let reference = device.referencePrior {
            return (reference.logMedian, reference.tau)
        }
        if let life = device.nominalLifeHours, life > 0 {
            return (log(life), config.tauUser)
        }
        return (log(device.kind.typicalLifeHours), config.tauDefault)
    }

    // MARK: - 观测提取

    /// 把事件序列拆成有效间隔与截尾间隔。**单位：小时（含小数）。**
    ///
    /// * 有效间隔：终点事件为 `.exhausted` → 计入寿命统计
    /// * 截尾间隔：终点事件为 `.preventive` / `.faulty` → 剔除出寿命统计
    ///   （但起算点照样重置，这一点由 `Device.installedAt` 保证）
    ///
    /// ⚠️ 旧版这里写的是 `Double(dayCount(from:to:))` —— 整数天，
    /// 会把 93.6 小时读成 3 天（−23%），而且**恒向下**、是系统性低估。
    public func observedIntervals(
        _ device: Device
    ) -> (exhausted: [Double], censored: [(hours: Double, kind: EventKind)]) {
        let events = device.sortedEvents
        var exhausted: [Double] = []
        var censored: [(hours: Double, kind: EventKind)] = []
        guard events.count >= 2 else { return (exhausted, censored) }

        for index in 1..<events.count {
            let previous = events[index - 1]
            let current = events[index]
            let hours = Self.hoursBetween(from: previous.at, to: current.at)
            guard hours > 0 else { continue }

            if current.kind.countsAsLifetimeSample {
                exhausted.append(hours)
            } else if current.kind.isCensored {
                censored.append((hours, current.kind))
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

    /// 产出完整预测。`now` 是「现在」这个**时刻**。设备没有事件时返回 `nil`。
    public func predict(_ device: Device, now: Date) -> Prediction? {
        guard let installed = device.installedAt, let posterior = fit(device) else {
            return nil
        }

        let medianHours = exp(posterior.logMean)

        // ★ 关键设计（相对初稿的修订）：
        // 风险窗口要预测的是「**当前这一颗**电池什么时候死」，而不是「期望寿命的下界」。
        // 单颗电池的寿命本身就有 σ_within 的固有波动，再加上对 m 的不确定度 σ_post，
        // 预测分布宽度应为 σ_pred = sqrt(σ_post² + σ_within²)。
        // 只用 σ_post 会把窗口系统性开晚，而本 App 的失败代价正是「没电了才发现」。
        let varianceSum = posterior.logSigma * posterior.logSigma
            + posterior.withinDeviceSigma * posterior.withinDeviceSigma
        let sigmaPrediction = min(varianceSum.squareRoot(), config.sigmaPredictionCap)

        let p10Hours = exp(posterior.logMean - config.z10 * sigmaPrediction)

        // ⚠️ 核心数值**一律不取整**。`p50ExhaustAt` / `p10ExhaustAt` 保留完整精度，
        // 只有最终**显示**时才用 `floorToHour` 对齐到整点。
        // 旧版先 `roundHalfUp` 成整天再加天 —— 那等于在模型数值上又砍一刀精度，
        // 对 4 天寿命的纽扣电池就是 25% 的额外误差。
        let p50ExhaustAt = Self.date(byAddingHours: medianHours, to: installed)
        let p10ExhaustAt = Self.date(byAddingHours: p10Hours, to: installed)

        let ageHours = Self.hoursBetween(from: installed, to: now)
        let remainingHours = Self.hoursBetween(from: now, to: p50ExhaustAt)
        let p10RemainingHours = Self.hoursBetween(from: now, to: p10ExhaustAt)
        let ratio = medianHours > 0 ? ageHours / medianHours : 1.0

        let urgency: Urgency
        if remainingHours < 0 {
            urgency = .overdue                    // 已过预测的中位耗尽时刻
        } else if p10RemainingHours <= 0 {
            urgency = .risk                       // 已进入风险窗口（P10 之后）
        } else if p10RemainingHours <= device.notifyLeadHours {
            urgency = .stockUp                    // 距风险窗口开启不足 lead 小时
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
            medianHours: medianHours,
            p10Hours: p10Hours,
            p50ExhaustAt: p50ExhaustAt,
            p10ExhaustAt: p10ExhaustAt,
            remainingHours: remainingHours,
            p10RemainingHours: p10RemainingHours,
            ageHours: ageHours,
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
    public func predictions(for devices: [Device], now: Date) -> [(device: Device, prediction: Prediction)] {
        devices
            .compactMap { device in
                guard let prediction = predict(device, now: now) else { return nil }
                return (device: device, prediction: prediction)
            }
            .sorted { lhs, rhs in
                let l = urgencyRank(lhs.prediction.urgency)
                let r = urgencyRank(rhs.prediction.urgency)
                if l != r { return l < r }
                return lhs.prediction.p10RemainingHours < rhs.prediction.p10RemainingHours
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
