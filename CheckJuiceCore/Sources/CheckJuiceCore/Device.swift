import Foundation

/// 来自「同型号设备」历史的先验，log 尺度。
///
/// 用途：你有 3 个同款温湿度计，其中 2 个已经换过 5 次电池。
/// 新买的第 3 个不必从零开始猜——直接借它们的后验当先验，`tau` 收紧到 0.25 左右，
/// 冷启动的窗口立刻从 ±50% 收到 ±25%。这是这个模型最实用的一招。
public struct ReferencePrior: Codable, Hashable, Sendable {
    /// log 尺度上的中位寿命（单位：小时）。
    ///
    /// ⚠️ **换单位时这里是陷阱**：`logMedian` 是**对数值**，不随线性单位等比缩放。
    /// 一份以「天」为单位存的 log 中位数要迁到小时制，必须 **+log(24)**，不是 ×24。
    /// 乘 24 会把 300 天的电池算成 12.5 天（`exp(5.70 × 24) ≈ 12.5 天`）。
    /// 真实代码里这个值来自另一台设备的 `Posterior.logMean`，那台也换成小时后自动一致；
    /// 只有硬编码的测试数据要手写对。
    public var logMedian: Double
    /// 不确定度（log 尺度标准差）。
    public var tau: Double

    public init(logMedian: Double, tau: Double) {
        self.logMedian = logMedian
        self.tau = tau
    }

    /// 从「中位寿命（**小时**）」构造。
    public init(medianLifeHours: Double, tau: Double) {
        self.logMedian = log(medianLifeHours)
        self.tau = tau
    }

    /// 中位寿命（**小时**）。
    public var medianLifeHours: Double { exp(logMedian) }
}

/// 一次更换（或首次安装）事件。
public struct ReplacementEvent: Codable, Hashable, Sendable {
    /// 事件发生的**绝对时刻**。
    ///
    /// 精确到分钟即可 —— 模型按小时算，但绝不按「整日」算：
    /// 整日会丢掉小数，而丢掉的那部分**恒向下**，是系统性低估。
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

    /// 提前多少**小时**提示备货（同时决定 🟡 该备货 的判定阈值）。
    public var notifyLeadHours: Double

    /// 用户手填的预期寿命（**小时**），覆盖 `kind` 的典型值。
    public var nominalLifeHours: Double?

    /// 借用同型号设备的历史当先验。
    public var referencePrior: ReferencePrior?

    /// 默认提前量：336 小时 = 14 天。留出快递 / 出门采购的时间。
    public static let defaultNotifyLeadHours: Double = 336

    public init(
        id: UUID = UUID(),
        name: String,
        kind: BatteryKind,
        events: [ReplacementEvent] = [],
        notifyLeadHours: Double = Device.defaultNotifyLeadHours,
        nominalLifeHours: Double? = nil,
        referencePrior: ReferencePrior? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.events = events
        self.notifyLeadHours = notifyLeadHours
        self.nominalLifeHours = nominalLifeHours
        self.referencePrior = referencePrior
    }

    /// 按时间升序排列的事件。
    public var sortedEvents: [ReplacementEvent] {
        events.sorted { $0.at < $1.at }
    }

    /// 当前这颗电池的起算时刻 = 最后一次事件的时刻。
    ///
    /// 注意：**截尾观测（提前更换 / 故障）同样会重置起算点**，
    /// 因为它确实换上了一颗新电池。只有「算不算寿命样本」会被剔除。
    public var installedAt: Date? {
        sortedEvents.last?.at
    }

    /// 便捷构造：`moment` 这一刻刚装上一颗新电池。
    public static func newlyAdded(
        name: String,
        kind: BatteryKind,
        at moment: Date,
        notifyLeadHours: Double = Device.defaultNotifyLeadHours
    ) -> Device {
        Device(
            name: name,
            kind: kind,
            events: [ReplacementEvent(at: moment, kind: .initial)],
            notifyLeadHours: notifyLeadHours
        )
    }
}
