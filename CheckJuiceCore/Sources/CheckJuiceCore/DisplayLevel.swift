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
