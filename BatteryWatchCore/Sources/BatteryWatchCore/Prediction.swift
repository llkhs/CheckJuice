import Foundation

/// 参数后验。`logMean` / `logSigma` 是 log 尺度上的均值与标准差。
public struct Posterior: Sendable, Equatable {
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
public enum Confidence: String, Sendable, CaseIterable {
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
public enum Urgency: String, Sendable, CaseIterable {
    /// 🔴 已超过预测中位日 —— 随时可能没电。
    case overdue
    /// 🟠 已进入风险窗口（P10）—— 该换了。
    case risk
    /// 🟡 该备货 —— 还没到窗口，但该把电池买回来了。
    case stockUp
    /// 🟢 正常。
    case normal

    public var displayName: String {
        switch self {
        case .overdue: return "已逾期"
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

/// 给 UI / 小组件用的最终结论。
public struct Prediction: Sendable, Equatable {
    /// 预测中位寿命（天）。对数正态的中位数比均值稳健。
    public var medianDays: Double
    /// P10 下界寿命（天）—— 风险窗口起点。
    public var p10Days: Double
    /// 预计耗尽日。
    public var medianDate: Date
    /// 风险窗口起点。
    public var riskDate: Date
    /// 距预计耗尽日还有几天（负数 = 逾期）。
    public var remainingDays: Int
    /// 距风险窗口还有几天（负数 = 已进入）。
    public var riskRemainingDays: Int
    /// 当前这颗电池已用天数。
    public var ageDays: Int
    /// 已用天数 / 预测中位寿命。
    public var ratio: Double
    /// 预测分布宽度 = sqrt(σ_post² + σ_within²)，已封顶。
    public var sigmaPrediction: Double
    public var urgency: Urgency
    public var confidence: Confidence
    public var posterior: Posterior

    public init(
        medianDays: Double,
        p10Days: Double,
        medianDate: Date,
        riskDate: Date,
        remainingDays: Int,
        riskRemainingDays: Int,
        ageDays: Int,
        ratio: Double,
        sigmaPrediction: Double,
        urgency: Urgency,
        confidence: Confidence,
        posterior: Posterior
    ) {
        self.medianDays = medianDays
        self.p10Days = p10Days
        self.medianDate = medianDate
        self.riskDate = riskDate
        self.remainingDays = remainingDays
        self.riskRemainingDays = riskRemainingDays
        self.ageDays = ageDays
        self.ratio = ratio
        self.sigmaPrediction = sigmaPrediction
        self.urgency = urgency
        self.confidence = confidence
        self.posterior = posterior
    }
}

public extension Prediction {
    /// 小组件 / 列表上显示的一行短文本。
    var shortDescription: String {
        switch urgency {
        case .overdue: return "逾期 \(abs(remainingDays)) 天"
        case .risk: return "≤ \(abs(riskRemainingDays)) 天"
        case .stockUp, .normal: return "\(remainingDays) 天"
        }
    }

    /// 剩余比例（0...1），用于进度条。
    var consumedFraction: Double {
        min(max(ratio, 0), 1)
    }
}
