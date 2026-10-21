import Foundation

/// 参数后验。`logMean` / `logSigma` 是 log 尺度上的均值与标准差。
///
/// `Codable` 是给**开发者模式导出**用的：复现一次预测需要后验参数，
/// 只导「还剩几小时」没法验证任何东西。
public struct Posterior: Sendable, Equatable, Codable {
    /// 后验均值（log 尺度）。
    public var logMean: Double
    /// σ_post：对**期望寿命**的不确定度。
    public var logSigma: Double
    /// Kish 有效样本量。
    public var effectiveSampleSize: Double
    /// 原始有效间隔数。
    public var observedCount: Int
    /// σ_within：**设备内固有波动**（电池颗与颗之间的差异）。
    public var withinDeviceSigma: Double

    public init(
        logMean: Double,
        logSigma: Double,
        effectiveSampleSize: Double,
        observedCount: Int,
        withinDeviceSigma: Double
    ) {
        self.logMean = logMean
        self.logSigma = logSigma
        self.effectiveSampleSize = effectiveSampleSize
        self.observedCount = observedCount
        self.withinDeviceSigma = withinDeviceSigma
    }
}

/// 置信度。
///
/// ⚠️ **必须显式展示给用户**。1 个样本和 10 个样本的预测绝不能画等号。
/// 这是这个 App 的诚信底线：宁可承认「我不知道」，也不要给一个看起来很准的假数字。
public enum Confidence: String, Codable, Sendable, CaseIterable {
    case low
    case medium
    case high

    public var displayName: String {
        switch self {
        case .low: return "低"
        case .medium: return "中"
        case .high: return "高"
        }
    }

    /// 给用户看的一句话解释。
    public var explanation: String {
        switch self {
        case .low: return "样本不足，误差可能达 ±50%，仅供参考"
        case .medium: return "已有几次更换记录，估计基本可用"
        case .high: return "样本充足，预测较可靠"
        }
    }
}

/// 紧急度分级。
public enum Urgency: String, Codable, Sendable, CaseIterable {
    /// 🔴 已超过预测的中位耗尽**时刻** —— 随时可能没电。
    case overdue
    /// 🟠 已进入风险窗口（P10）—— 该换了。
    case risk
    /// 🟡 该备货 —— 还没到窗口，但该把电池买回来了。
    case stockUp
    /// 🟢 正常。
    case normal

    public var displayName: String {
        switch self {
        case .overdue: return "耗尽中"
        case .risk: return "风险窗口"
        case .stockUp: return "该备货"
        case .normal: return "正常"
        }
    }

    public var symbolName: String {
        switch self {
        case .overdue: return "exclamationmark.triangle.fill"
        case .risk: return "exclamationmark.circle.fill"
        case .stockUp: return "cart.fill"
        case .normal: return "checkmark.circle.fill"
        }
    }
}

/// 给 UI / 小组件用的最终结论。**所有时间量的单位都是小时。**
public struct Prediction: Sendable, Equatable {
    /// 预测中位寿命（小时）。对数正态的中位数比均值稳健。
    public var medianHours: Double
    /// P10 下界寿命（小时）—— 风险窗口起点。
    public var p10Hours: Double
    /// 预计耗尽**时刻**（中位）。
    ///
    /// 注意是「时刻」而不是「日期」：对一块标称撑 4 天的纽扣电池来说，
    /// 「哪一天耗尽」远不如「几点耗尽」有用 —— 后者才能回答
    /// 「我早上 8 点出门，它撑得到我晚上回来吗」。
    public var p50ExhaustAt: Date
    /// 风险窗口起点**时刻**（P10，早于 `p50ExhaustAt`）。
    public var p10ExhaustAt: Date
    /// 距中位耗尽时刻还有几小时（**含小数**，负数 = 逾期）。
    ///
    /// 用 `Double` 而不是 `Int`：取整是**显示层**的事，不该污染模型输出。
    /// UI 需要整数时调 `LifetimeModel.wholeHours`（朝零截断，双向保守）。
    public var remainingHours: Double
    /// 距风险窗口还有几小时（含小数，负数 = 已进入）。
    public var p10RemainingHours: Double
    /// 当前这颗电池已用小时数。
    public var ageHours: Double
    /// 已用时长 / 预测中位寿命。
    public var ratio: Double
    /// 预测分布宽度 = sqrt(σ_post² + σ_within²)，已封顶。
    public var sigmaPrediction: Double
    public var urgency: Urgency
    public var confidence: Confidence
    public var posterior: Posterior

    public init(
        medianHours: Double,
        p10Hours: Double,
        p50ExhaustAt: Date,
        p10ExhaustAt: Date,
        remainingHours: Double,
        p10RemainingHours: Double,
        ageHours: Double,
        ratio: Double,
        sigmaPrediction: Double,
        urgency: Urgency,
        confidence: Confidence,
        posterior: Posterior
    ) {
        self.medianHours = medianHours
        self.p10Hours = p10Hours
        self.p50ExhaustAt = p50ExhaustAt
        self.p10ExhaustAt = p10ExhaustAt
        self.remainingHours = remainingHours
        self.p10RemainingHours = p10RemainingHours
        self.ageHours = ageHours
        self.ratio = ratio
        self.sigmaPrediction = sigmaPrediction
        self.urgency = urgency
        self.confidence = confidence
        self.posterior = posterior
    }
}

/// 主数字的显示样式（App 设置页可选）。原始值持久化到 UserDefaults。
public enum ExhaustDisplayStyle: String, Codable, Sendable, CaseIterable, Identifiable {
    /// 「10月18日 周日 08:00」—— 给时刻，方便对着自己的日程看。
    case moment
    /// 「还剩 84 小时」/「约 137 天」/「约 4 个月」—— 给剩余量，单位自适应。
    case remaining

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .moment: return "耗尽时刻"
        case .remaining: return "剩余时长"
        }
    }
}

public extension Prediction {
    /// **本 App 的主打数字**：还要多久耗尽 —— 以及列表/小组件上那一行主文案。
    ///
    /// ⚠️ 两种样式报的都是 **P10（最坏情况）**，不是中位数。这是刻意的：
    /// 用户拿这个数字回答的问题是「**撑不撑得过今天 / 这趟出门**」。
    /// 中位数只意味着「有一半概率比这更早耗尽」—— 拿它做决定就是抛硬币。
    /// 中位数放在 `medianText()` 里当小字，让用户看得见两者的差距。
    ///
    /// 取整一律朝**保守**方向：时刻向下取整到整点、小时数朝零截断到整数。
    /// 宁可说早一点，不可以说晚 —— 这个 App 的失败代价是「没电了才发现」。
    ///
    /// 📌 历史坑（已修，别再踩）：这里曾经用 `remainingHours`（距**中位**耗尽时刻）
    /// 当主数字，还在注释里留了一段「必须用 remainingHours、别用 p10」的告诫。
    /// 那本质上是在拿中位数当保证：某设备年龄 200 天 / P10 189 天，
    /// 中位说「还有 99 天」，实际早就进了风险窗口。现在信口头号反过来了。
    func remainingText(
        style: ExhaustDisplayStyle,
        timeZone: TimeZone = .current,
        locale: Locale = .current
    ) -> String {
        switch style {
        case .remaining:
            return Self.adaptiveHours(p10RemainingHours)

        case .moment:
            let moment = LifetimeModel.floorToHour(p10ExhaustAt, in: timeZone)
            let text = Self.momentFormatter(timeZone: timeZone, locale: locale).string(from: moment)
            return p10RemainingHours < 0 ? "耗尽中 · \(text)" : text
        }
    }

    /// 副文案：**中位**预测。主文案报最坏情况时，这个让人知道差多远。
    func medianText(
        style: ExhaustDisplayStyle,
        timeZone: TimeZone = .current,
        locale: Locale = .current
    ) -> String {
        switch style {
        case .remaining:
            return "中位 · " + Self.adaptiveHours(remainingHours)

        case .moment:
            let moment = LifetimeModel.floorToHour(p50ExhaustAt, in: timeZone)
            let text = Self.momentFormatter(timeZone: timeZone, locale: locale).string(from: moment)
            // 不判「中位是否已过」：P50 ≥ P10 恒成立，中位过了主文案一定已经报「耗尽中」了，
            // 再标一次是多余。
            return "中位 · \(text)"
        }
    }

    /// 单位自适应的剩余时长文案 —— **纯显示层**，内部一律精确小时。
    ///
    /// 不让 5 号电池显示「还剩 1443 小时」这种假精度：那 1443 小时背后 P10~P90
    /// 可能横跨几百小时，把一个不确定量写成 4 位有效数字就是在撒谎。
    /// 阈值取 48 小时 / 1440 小时（2 天 / 60 天）—— 更细的粒度没有决策价值。
    ///
    /// 负数（已耗尽）也走同一套量级分支，只是措辞不同且**不加「约」**：
    /// 耗尽 3 个月说「耗尽中 3 个月」，不说「耗尽中 2160 小时」。
    /// 与 Python 的 `format_remaining_short` 必须逐字符一致（黄金数值会断言）。
    static func adaptiveHours(_ hours: Double) -> String {
        guard hours.isFinite else { return "—" }

        // ⚠️ **符号必须用原始值判断，不能先截断。**
        // 旧实现先 `wholeHours(-0.892)` → 0，于是「已耗尽 53 分钟」会显示成
        // 「还剩 0 小时」—— 已经没电了却告诉用户还剩着。
        let exhausted = hours < 0
        let magnitude = abs(hours)

        if magnitude >= 1440 {
            let n = Int(magnitude / 720)
            return exhausted ? "耗尽中 \(n) 个月" : "约 \(n) 个月"
        }
        if magnitude >= 48 {
            let n = Int(magnitude / 24)
            return exhausted ? "耗尽中 \(n) 天" : "约 \(n) 天"
        }
        if magnitude >= 1 {
            let n = Int(magnitude)              // 朝零截断，与 `wholeHours` 同口径
            return exhausted ? "耗尽中 \(n) 小时" : "还剩 \(n) 小时"
        }

        // 不足 1 小时改用分钟。
        //
        // **为什么必须有这一档**：真机反馈里，1 小时的电池还剩 22 分钟时显示
        // 「还剩 0 小时」。用户分不出「马上没电」和「真的没了」，
        // 而这两个状态该做的事完全不同（一个该准备换，一个该已经换了）。
        // 短命电池是这个 App 的主力场景，这一档不能省。
        let minutes = Int(magnitude * 60)
        if minutes >= 1 {
            return exhausted ? "耗尽中 \(minutes) 分钟" : "还剩 \(minutes) 分钟"
        }
        return exhausted ? "刚刚耗尽" : "不足 1 分钟"
    }

    /// 风险窗口起点（P10）的文本 —— 「最早可能耗尽」。
    ///
    /// 这是本模型真正的卖点：中位数只代表 50% 的概率，只盯着它换电池必然翻车。
    /// 「撑不撑得过今天」应该问的是这个时刻，而不是中位数。
    func riskWindowText(
        timeZone: TimeZone = .current,
        locale: Locale = .current
    ) -> String {
        let moment = LifetimeModel.floorToHour(p10ExhaustAt, in: timeZone)
        return Self.momentFormatter(timeZone: timeZone, locale: locale).string(from: moment)
    }

    /// 剩余比例（0...1）。**只用于画进度条，不参与任何判定。**
    var consumedFraction: Double {
        min(max(ratio, 0), 1)
    }

    /// 「10月18日 周日 08:00」。
    ///
    /// 用显式 `dateFormat` 而不是 `setLocalizedDateFormatFromTemplate`：
    /// 本 App 只面向中文用户，显式格式可预测，不受设备区域设置漂移影响。
    /// 时刻在调用前已 `floorToHour`，所以 `mm` 必然是 "00"。
    ///
    /// 刻意不做静态缓存：`static var` 在 Swift 6 严格并发下会报数据竞争，
    /// 而本机无法编译验证。`DateFormatter` 单次创建的开销在列表规模下可忽略。
    private static func momentFormatter(timeZone: TimeZone, locale: Locale) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.locale = locale
        formatter.dateFormat = "M月d日 EEE HH:mm"
        return formatter
    }
}
