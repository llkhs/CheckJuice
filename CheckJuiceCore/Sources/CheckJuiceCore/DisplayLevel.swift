import Foundation

/// 首页 / 小组件上那一行的**颜色分级**。
///
/// 跟 `Urgency` 是两件事，别混：
/// - `Urgency` 是模型的**紧急度**，四级，用于排序（`risk` 单列一档）。
/// - `DisplayLevel` 是**上屏的颜色**，三级，只回答「这一行该用什么颜色」。
///
/// 为什么要拆开：用户要的是「剩余小时 ≤ 提前提醒量 → 黄，耗尽 → 红」这种直白规则，
/// 而模型内部的紧急度还带着「P10 已过」这一档，排序时有用、上屏时不必单独配色。
/// 把「算什么」和「怎么显示」混在一个枚举里，改配色就得动模型 —— 那会碰黄金数值。
///
/// ⚠️ **判据必须用 `p10RemainingHours`，不是 `remainingHours`。**
/// 主行显示的就是 P10（最坏情况）。若拿中位剩余去比提前量，
/// 风险窗口远早于中位日 → 黄色几乎永不触发（DESIGN 3.6 记着这个坑，已被推翻过一次）。
public enum DisplayLevel: String, Codable, Sendable, CaseIterable {
    /// 🔴 已过预测的中位耗尽时刻。
    case exhausted
    /// 🟡 距风险窗口不足提前提醒量 —— 含「已经进入风险窗口」（P10 ≤ 0）。
    case soon
    /// 默认色。
    case normal

    public static func make(
        remainingHours: Double,
        p10RemainingHours: Double,
        notifyLeadHours: Double
    ) -> DisplayLevel {
        if remainingHours < 0 { return .exhausted }
        // `notifyLeadHours` 可以是 0（用户不想要提前提醒）。
        // 那时 `p10 <= 0` 仍然算 soon —— 风险窗口已开，跟「提前量」无关。
        if p10RemainingHours <= 0 { return .soon }
        if p10RemainingHours <= notifyLeadHours { return .soon }
        return .normal
    }

    /// 从一次预测 + 这台设备的提前量得出。
    public static func make(prediction: Prediction, notifyLeadHours: Double) -> DisplayLevel {
        make(
            remainingHours: prediction.remainingHours,
            p10RemainingHours: prediction.p10RemainingHours,
            notifyLeadHours: notifyLeadHours
        )
    }

    public var displayName: String {
        switch self {
        case .exhausted: return "耗尽中"
        case .soon: return "该处理"
        case .normal: return "正常"
        }
    }
}

/// 首页列表的排序方式。
///
/// 放 Core 而不是 App：它要靠 `DisplaySettings` 持久化，而后者在 Store 模块 ——
/// 跟 `ExhaustDisplayStyle` 同一个位置，避免两套「设置枚举」分居两地。
public enum SortMode: String, Codable, Sendable, CaseIterable, Identifiable {
    /// 最该处理的排最前（默认）。用模型给的紧急度，不是显示颜色。
    case urgency
    /// 剩余时间少的在前。
    case remaining
    /// 按名称。
    case name
    /// 最近添加的在前。
    case recent

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .urgency: return "紧急度"
        case .remaining: return "剩余时间"
        case .name: return "名称"
        case .recent: return "最近添加"
        }
    }

    public var symbolName: String {
        switch self {
        case .urgency: return "exclamationmark.triangle"
        case .remaining: return "hourglass"
        case .name: return "textformat.abc"
        case .recent: return "clock"
        }
    }
}

/// 一台设备 + 它的预测。列表、导出、排序都用这个形状。
public typealias DevicePrediction = (device: Device, prediction: Prediction)

extension SortMode {
    /// 按本方式排序。
    ///
    /// **列表和导出必须共用这一份。** 曾经导出直接用了
    /// `LifetimeModel.predictions(for:)`（那个写死按紧急度排），
    /// 于是 JSON 里写着 `sortMode: "name"`、数组顺序却是紧急度 —— 字段在撒谎。
    /// 当时排序逻辑住在 App 层，`swift test` 够不着，所以没人发现。
    /// 稳定的 tiebreak。
    ///
    /// ⚠️ Swift 的 `sorted(by:)` **不保证稳定**。真机反馈「排列有问题」，
    /// 实际是四台设备的创建时刻一模一样（都点到同一秒），比较函数返回 false，
    /// 顺序就由内部算法决定 —— 每次求值可能不同，看起来像乱跳。
    /// 用 id 兜底后，相同 key 的相对顺序永远一致。
    ///
    /// **顺序**：先比名称，再比 `id`。
    ///
    /// 名称优先是因为：同一秒添加的几台，用 UUID 排出来的结果虽然稳定，
    /// 但对人是乱的（实测得到 2,3,4,1）。按名称排出来是 1,2,3,4，
    /// 至少看得懂。`id` 只作为最后的兜底 —— 同名同时间的两台也需要**某一**种
    /// 确定顺序，至于哪一种无所谓。
    private static func tieBreak(_ a: DevicePrediction, _ b: DevicePrediction) -> Bool {
        switch a.device.name.localizedStandardCompare(b.device.name) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return a.device.id.uuidString < b.device.id.uuidString
        }
    }

    public func sorted(_ items: [DevicePrediction]) -> [DevicePrediction] {
        switch self {
        case .urgency:
            return items.sorted { lhs, rhs in
                let a = SortMode.urgencyRank(lhs.prediction.urgency)
                let b = SortMode.urgencyRank(rhs.prediction.urgency)
                if a != b { return a < b }
                if lhs.prediction.remainingHours != rhs.prediction.remainingHours {
                    return lhs.prediction.remainingHours < rhs.prediction.remainingHours
                }
                return Self.tieBreak(lhs, rhs)
            }
        case .remaining:
            // 按**屏幕上那个数**排（P10 剩余）。用户看到「还剩 30 小时」排在
            // 「还剩 90 小时」前面才符合直觉；拿中位排会显得乱序。
            return items.sorted { lhs, rhs in
                if lhs.prediction.p10RemainingHours != rhs.prediction.p10RemainingHours {
                    return lhs.prediction.p10RemainingHours < rhs.prediction.p10RemainingHours
                }
                return Self.tieBreak(lhs, rhs)
            }
        case .name:
            return items.sorted { lhs, rhs in
                switch lhs.device.name.localizedStandardCompare(rhs.device.name) {
                case .orderedAscending: return true
                case .orderedDescending: return false
                case .orderedSame: return Self.tieBreak(lhs, rhs)
                }
            }
        case .recent:
            // 「添加时间」= 最早那条记录的时刻（创建时填的基准点）。
            // 不用 id 或文件顺序：那两者对用户不可见，也没法解释「为什么它排前面」。
            return items.sorted { lhs, rhs in
                let a = lhs.device.sortedEvents.first?.at ?? .distantPast
                let b = rhs.device.sortedEvents.first?.at ?? .distantPast
                if a != b { return a > b }
                return Self.tieBreak(lhs, rhs)
            }
        }
    }

    static func urgencyRank(_ urgency: Urgency) -> Int {
        switch urgency {
        case .overdue: return 0
        case .risk: return 1
        case .stockUp: return 2
        case .normal: return 3
        }
    }
}
