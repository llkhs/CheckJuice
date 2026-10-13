import Foundation

/// 一次更换（或首次安装）事件的类型。
///
/// 语义约定（很重要，写错整个统计就废了）：
/// `kind` 描述的是「**上一颗**电池是被怎么处理掉的」。
/// 所以 `events[i]` 与 `events[i-1]` 之间的那段间隔，有效性由 `events[i].kind` 决定。
public enum EventKind: String, Codable, CaseIterable, Sendable {
    /// 首次安装，永远不会作为间隔的终点。
    case initial
    /// 自然耗尽 —— **有效样本**，间隔计入寿命统计。
    case exhausted
    /// 提前预防性更换 —— **截尾观测**，间隔剔除出寿命统计。
    case preventive
    /// 电池质量问题（漏液 / 提前失效）—— **截尾观测**，间隔剔除出寿命统计。
    case faulty

    /// 是否计入寿命统计。只有自然耗尽才算。
    public var countsAsLifetimeSample: Bool { self == .exhausted }

    /// 是否为截尾观测。
    ///
    /// ⚠️ 截尾观测**不进寿命统计**，但它**照样重置了起算点**——
    /// 因为当时确实装上了新电池。把这两件事混为一谈是最常见的错误：
    /// 前者决定「这颗电池的寿命算不算数」，后者决定「下一颗从哪天开始算」。
    public var isCensored: Bool { self == .preventive || self == .faulty }

    public var displayName: String {
        switch self {
        case .initial: return "首次安装"
        case .exhausted: return "自然耗尽"
        case .preventive: return "提前更换"
        case .faulty: return "电池故障"
        }
    }
}
