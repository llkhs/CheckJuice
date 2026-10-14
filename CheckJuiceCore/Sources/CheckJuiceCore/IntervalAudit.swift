import Foundation

/// 一段相邻更换间隔为什么进了（或没进）寿命统计。
///
/// 存在的意义是让「哪几段算数、为什么不算」变成**可显示的事实**，
/// 而不是藏在模型里的黑盒 —— 界面要靠它给每条更换记录打标。
public enum IntervalReason: String, Codable, Sendable, CaseIterable {
    /// 计入寿命统计：这是一次真实的「自然耗尽」。
    case sample
    /// 截尾观测（提前更换 / 电池故障），不进统计。
    case censored
    /// 间隔短得不可能是真实寿命（误触 / 修正 / 测试），不进统计。
    case tooShort
}

/// 一段相邻更换间隔的判定结果。**单位：小时。**
public struct IntervalAudit: Sendable, Equatable {
    public let start: Date
    public let end: Date
    public let hours: Double
    /// 终点事件的类型，即「上一颗电池是怎么结束的」。
    public let kind: EventKind
    public let reason: IntervalReason
    /// 判定时用的下限。留着是为了让界面能解释「为什么不算」——
    /// 「这段只有 2 分钟，小于 1 小时的下限」比「未计入统计」有用得多。
    public let floorHours: Double

    public var counted: Bool { reason == .sample }

    public init(
        start: Date, end: Date, hours: Double,
        kind: EventKind, reason: IntervalReason, floorHours: Double
    ) {
        self.start = start
        self.end = end
        self.hours = hours
        self.kind = kind
        self.reason = reason
        self.floorHours = floorHours
    }
}
