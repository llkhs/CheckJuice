import Foundation

/// 存储层能出的错。只有一种，但必须是个**会抛出来的**东西 —— 见 `DeviceStore.save`。
public enum StoreError: LocalizedError, Equatable {
    /// 拿不到 App Group 容器。典型原因是描述文件里没声明这个 group
    /// （自签 IPA 最常见），或者标识符跟 entitlements 对不上。
    case appGroupUnavailable

    public var errorDescription: String? {
        switch self {
        case .appGroupUnavailable:
            return "拿不到共享容器，物品不会真正存下来，小组件也读不到。"
        }
    }
}

/// App Group 配置 —— App 与 Widget 唯一的共享通道。
///
/// ⚠️ **这个标识符必须与描述文件（`.mobileprovision`）里
/// `com.apple.security.application-groups` 列出的某一个值逐字符相同。**
/// 对不上的话，`containerURL` 返回 nil，App 和 Widget 各自读到空数据，
/// 而且**不会报错** —— 这曾经是最难查的一类问题（见 `DeviceStore.save`：
/// 它原来在容器为空时静默返回成功，于是「界面一切正常、重启全没了」）。
///
/// 这个值**不会**被构建流程改写：`checkjuice.entitlements` 里写的就是它，
/// 系统只认描述文件。自签（Esign 之类）时用的描述文件如果没声明这个 group，
/// 就必须改成一个它声明过的值 —— 诊断页会直接告诉你两边分别是什么。
public enum AppGroup {
    public static let identifier = "group.com.llkhs.CheckJuice"

    /// App Group 共享容器根目录。未配置或描述文件不含该 group 时为 nil。
    public static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    /// 容器是否真的可用。诊断页和主页横幅都看这个。
    public static var isAvailable: Bool { containerURL != nil }

    /// 容器不可用时为 nil。文件名只有这一处定义，两个 store 和诊断页都从这儿取。
    public static var devicesFileURL: URL? {
        containerURL?.appendingPathComponent("devices.json")
    }

    /// 小组件读的那份快照的路径（容器不可用时为 nil）。
    public static var snapshotFileURL: URL? {
        containerURL?.appendingPathComponent("widget_snapshot.json")
    }

    /// 容器不可用时给用户看的那句话（主页横幅和诊断页共用，别抄两份）。
    public static var unavailableMessage: String {
        "拿不到共享容器「\(identifier)」（描述文件里没有它）。"
            + "物品不会真正存下来，小组件也读不到。"
    }
}
