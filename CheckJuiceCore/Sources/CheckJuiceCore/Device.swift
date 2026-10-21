import Foundation

/// 来自「**同款设备**」历史的先验，log 尺度。
///
/// 用途：你有 3 个同款温湿度计，其中 2 个已经换过 5 次电池。
/// 新买的第 3 个不必从零开始猜——直接借它们的后验当先验，`tau` 收紧到 0.25 左右，
/// 冷启动的窗口立刻从 ±50% 收到 ±25%。这是这个模型最实用的一招。
///
/// 说明：目前界面还没有入口去填它，是留给核心库的能力。
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
///
/// 用户创建时只填 `name` 和 `nominalLifeHours`（「大概能用多久」）。
/// **没有电池型号这个字段** —— 型号根本不决定寿命：同一颗 CR2032 在高功耗传感器里
/// 撑几天，在电子秤上撑几年；让用户先做一道选择题纯属添乱。
/// 之后每换一次电池补一个 `ReplacementEvent`，样本越多先验被压得越扁。
public struct Device: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String

    /// 用户填的「大概能用多久」（**小时**）= 模型唯一的冷启动先验。
    ///
    /// 建库时用 `log(nominalLifeHours) ± tauUser` 当先验；一旦攒够真实寿命样本，
    /// 共轭更新会把先验压扁，这个估计值的权重自然衰减。
    public var nominalLifeHours: Double

    public var events: [ReplacementEvent]

    /// 提前多少**小时**提示备货（同时决定 🟡 该备货 的判定阈值）。
    public var notifyLeadHours: Double

    /// 借用同款设备的历史当先验（界面上暂无入口）。
    public var referencePrior: ReferencePrior?

    /// 被丢进回收站的时刻；`nil` = 正常存在。
    ///
    /// **为什么是软删除而不是直接从库里抹掉**：电池寿命预测的全部价值都在历史样本上，
    /// 而样本要靠几个月甚至几年才攒得起来。手滑删掉一台记录了三年的设备、
    /// 然后发现「反正得重新填」，这代价和误删照片不是一个量级。
    ///
    /// 可选类型 → 合成 `Codable` 走 `decodeIfPresent`，老的 JSON 少这个键照常解码，
    /// 所以不需要任何迁移代码。
    public var deletedAt: Date?

    /// 在回收站里。
    public var isTrashed: Bool { deletedAt != nil }

    /// 回收站保留时长：**15 天**后自动清掉。
    ///
    /// 取 15 天是因为「发现某台设备被误删」通常发生在想起来要用它的那一刻，
    /// 而这多半跟一次换电池周期有关。30 天太长、7 天太短。
    public static let trashRetentionDays: Double = 15

    /// 新物品的默认提前量：**1 小时**。
    ///
    /// 原来写的是 336（14 天）—— 那个值默认的是「上网下单、等快递」的场景。
    /// 但这个 App 真正被盯的是**短命电池**（几小时到几天），用户多半是从抽屉里
    /// 摸一颗就换上，4 小时对应的是「出门前先看一眼够不够撑完这一趟」。
    /// 长寿命设备（烟感那种一年一颗的）在编辑页把单位切到「天」就行。
    /// 取 1 而不是 4：短命电池（1~5 小时）才是主力场景，4 小时会直接让它们一建好就变黄。
    public static let defaultNotifyLeadHours: Double = 1

    /// 把所有时刻对齐到分钟。
    ///
    /// **为什么要这么干**：界面只能表达「年月日时分」——`DatePicker` 的
    /// `displayedComponents: [.date, .hourAndMinute]` 没有秒这一位。
    /// 但早期默认值用的是 `Date()`，带小数秒，于是「看到的 14:21」和
    /// 「实际存的 14:21:48.373」不是一回事。用户根本没机会选那几十秒。
    ///
    /// 对齐之后**看到的 = 存的 = 算的**。量化误差对 4 小时电池约 0.4%，
    /// 远小于模型本身的不确定性（σ_pred 封顶 0.70 ≈ ±100%）。
    ///
    /// 这是**幂等**的：已经对齐的值再跑一遍不会变，所以可以在读路径上每次都跑。
    public var normalizedToMinute: Device {
        var copy = self
        copy.events = events.map { event in
            var e = event
            e.at = LifetimeModel.floorToMinute(event.at)
            return e
        }
        // `deletedAt` 是系统时间戳，不对齐 —— 它不参与预测，
        // 而且是「被删那一刻」的审计记录，没有理由改。
        return copy
    }

    /// 在回收站里已经躺够 `trashRetentionDays` 了吗。
    ///
    /// 判定放 Core 不放 App 层：这是个纯粹的、有边界的时间比较，
    /// 而**边界条件正是最容易写错的地方**（`<` 还是 `<=`、用小时还是用天）。
    /// 放在 View 里就没法用 `swift test` 钉住 —— 那只能靠手点验。
    public func isTrashExpired(now: Date) -> Bool {
        guard let deletedAt else { return false }
        return now.timeIntervalSince(deletedAt) >= Device.trashRetentionDays * 24 * 3600
    }

    /// 回收站里还剩几天被自动清掉（向上取整到「天」）。
    ///
    /// 向上取整是**故意偏保守**：剩 0.1 天时说「还剩 1 天」而不是「0 天」，
    /// 用户不会因为看到 0 而以为早就没了；真正归零只在「下次打开就清」时出现。
    public func daysLeftInTrash(now: Date) -> Int {
        guard let deletedAt else { return 0 }
        let leftHours = Device.trashRetentionDays * 24 - now.timeIntervalSince(deletedAt) / 3600
        return max(0, Int(ceil(leftHours / 24)))
    }

    public init(
        id: UUID = UUID(),
        name: String,
        nominalLifeHours: Double,
        events: [ReplacementEvent] = [],
        notifyLeadHours: Double = Device.defaultNotifyLeadHours,
        referencePrior: ReferencePrior? = nil,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.nominalLifeHours = nominalLifeHours
        self.events = events
        self.notifyLeadHours = notifyLeadHours
        self.referencePrior = referencePrior
        self.deletedAt = deletedAt
    }

    /// 按时间升序排列的事件。
    ///
    /// **不变式：最旧的那条一定是 `.initial`。** 用户可能在编辑页把某条记录改到更早、
    /// 或删掉最旧的一条，与其让每个调用点各自记得处理，不如在这里兜住。
    ///
    /// ⚠️ **别把它的作用搞反**：`.initial` **只能当间隔起点，不能当终点**
    /// （`auditIntervals` 里 `current.kind == .initial` 直接 `continue`）。
    /// 它到下一次更换的那段间隔**是**真样本 —— 「上次什么时候换的电池」是用户
    /// 明确告诉我们的真实起点，从它算起的时长完全算数。这一点是冷启动的第一份证据，
    /// 丢掉它等于让「填写历史更换时间」这个功能白做。
    public var sortedEvents: [ReplacementEvent] {
        var ordered = events.sorted { $0.at < $1.at }
        if let first = ordered.first, first.kind != .initial {
            ordered[0].kind = .initial
        }
        return ordered
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
        nominalLifeHours: Double,
        at moment: Date,
        notifyLeadHours: Double = Device.defaultNotifyLeadHours
    ) -> Device {
        Device(
            name: name,
            nominalLifeHours: nominalLifeHours,
            events: [ReplacementEvent(at: moment, kind: .initial)],
            notifyLeadHours: notifyLeadHours
        )
    }
}
