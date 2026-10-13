import Foundation

/// 来自「同型号设备」历史的先验，log 尺度。
///
/// 用途：你有 3 个同款温湿度计，其中 2 个已经换过 5 次电池。
/// 新买的第 3 个不必从零开始猜——直接借它们的后验当先验，`tau` 收紧到 0.25 左右，
/// 冷启动的窗口立刻从 ±50% 收到 ±25%。这是这个模型最实用的一招。
public struct ReferencePrior: Codable, Hashable, Sendable {
    /// log 尺度上的中位寿命。
    public var logMedian: Double
    /// 不确定度（log 尺度标准差）。
    public var tau: Double

    public init(logMedian: Double, tau: Double) {
        self.logMedian = logMedian
        self.tau = tau
    }

    /// 从「中位寿命（天）」构造。
    public init(medianLifeDays: Double, tau: Double) {
        self.logMedian = log(medianLifeDays)
        self.tau = tau
    }

    /// 中位寿命（天）。
    public var medianLifeDays: Double { exp(logMedian) }
}

/// 一次更换（或首次安装）事件。
public struct ReplacementEvent: Codable, Hashable, Sendable {
    public var at: Date
    public var kind: EventKind
    public var note: String

    public init(at: Date, kind: EventKind = .exhausted, note: String = "") {
        self.at = at
        self.kind = kind
        self.note = note
    }
}

/// 一台被盯着的设备。
public struct Device: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: BatteryKind
    public var events: [ReplacementEvent]
    /// 提前多少天提醒（同时决定 🟡 该备货 的判定阈值）。
    public var notifyLeadDays: Int
    /// 用户手填的预期寿命（天），覆盖 `kind` 的典型值。
    public var nominalLifeDays: Double?
    /// 借用同型号设备的历史当先验。
    public var referencePrior: ReferencePrior?

    public init(
        id: UUID = UUID(),
        name: String,
        kind: BatteryKind,
        events: [ReplacementEvent] = [],
        notifyLeadDays: Int = 14,
        nominalLifeDays: Double? = nil,
        referencePrior: ReferencePrior? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.events = events
        self.notifyLeadDays = notifyLeadDays
        self.nominalLifeDays = nominalLifeDays
        self.referencePrior = referencePrior
    }

    /// 按时间升序排列的事件。
    public var sortedEvents: [ReplacementEvent] {
        events.sorted { $0.at < $1.at }
    }

    /// 当前这颗电池的起算时间 = 最后一次事件的日期。
    ///
    /// 注意：**截尾观测（提前更换 / 故障）同样会重置起算点**，
    /// 因为它确实换上了一颗新电池。只有「算不算寿命样本」会被剔除。
    public var installedAt: Date? {
        sortedEvents.last?.at
    }

    /// 便捷构造：今天刚装上一颗新电池。
    public static func newlyAdded(
        name: String,
        kind: BatteryKind,
        on date: Date,
        notifyLeadDays: Int = 14
    ) -> Device {
        Device(
            name: name,
            kind: kind,
            events: [ReplacementEvent(at: date, kind: .initial)],
            notifyLeadDays: notifyLeadDays
        )
    }
}
