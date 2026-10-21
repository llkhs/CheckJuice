import Foundation
import CheckJuiceCore

/// 显示相关设置。
///
/// **存在 App Group 共享域，不是 App 私有的 `UserDefaults.standard`。**
///
/// 理由：iOS 17 的交互式小组件（`Button(intent:)`）是在**扩展进程**里就地换电池、
/// 重建快照的 —— 那个进程也要按同样的样式渲染文案。设置只存在 App 进程里的话，
/// 小组件只能读到默认值，显示就跟 App 对不上。
///
/// 今天小组件只读预渲染好的字符串，看起来放哪都行；但放共享域是**零成本**的
/// （同一套 API 换个 suite 名），而将来发现放错了就得写迁移。所以现在就放对。
public enum DisplaySettings {
    private static let styleKey = "displayStyle"
    private static let showMedianKey = "showMedianSubline"
    private static let sortModeKey = "sortMode"
    private static let developerModeKey = "developerMode"

    /// App Group 未配置时（未签名的调试构建）`UserDefaults(suiteName:)` 会返回 nil，
    /// 退回标准域 —— 让代码在没签名的情况下也能跑，不至于一开就崩。
    private static var defaults: UserDefaults {
        UserDefaults(suiteName: AppGroup.identifier) ?? .standard
    }

    /// 主文案样式。默认 **`.remaining`** —— 本 App 的主打就是「还剩多少工作时间」。
    public static var style: ExhaustDisplayStyle {
        get {
            guard let raw = defaults.string(forKey: styleKey),
                  let value = ExhaustDisplayStyle(rawValue: raw)
            else { return .remaining }
            return value
        }
        set { defaults.set(newValue.rawValue, forKey: styleKey) }
    }

    /// 列表主文案下面那行「中位」小字是否显示。默认显示。
    ///
    /// 主文案报最坏情况（P10）、小字报中位 —— 并排显示的价值在于让人看见
    /// 「最坏」和「典型」差多远。但有人就是嫌乱，给个开关。
    /// 小组件不受这个开关影响：它空间太小，只显示主文案。
    public static var showMedian: Bool {
        get {
            guard defaults.object(forKey: showMedianKey) != nil else { return true }
            return defaults.bool(forKey: showMedianKey)
        }
        set { defaults.set(newValue, forKey: showMedianKey) }
    }

    /// 首页列表的排序方式。默认按紧急度。
    ///
    /// 存共享域而不是标准域：虽然今天只有 App 用，但跟其它显示设置放一起，
    /// 少一个「为什么这个键在这儿、那个键在那儿」的疑问。
    public static var sortMode: SortMode {
        get {
            guard let raw = defaults.string(forKey: sortModeKey),
                  let value = SortMode(rawValue: raw)
            else { return .urgency }
            return value
        }
        set { defaults.set(newValue.rawValue, forKey: sortModeKey) }
    }

    /// 开发者模式。打开后主页多一个「导出」按钮。
    ///
    /// 默认关。这不是给普通用户的功能，默认开着只会让工具栏多一个看不懂的图标。
    public static var developerMode: Bool {
        get { defaults.bool(forKey: developerModeKey) }
        set { defaults.set(newValue, forKey: developerModeKey) }
    }
}
