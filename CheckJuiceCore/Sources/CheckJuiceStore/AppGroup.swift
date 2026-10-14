import Foundation

/// 存储层能出的错。只有一种，但必须是个**会抛出来的**东西 —— 见 `DeviceStore.save`。
public enum StoreError: LocalizedError, Equatable {
    /// 拿不到 App Group 容器。典型原因是**重签名后**没有任何一个可用的组
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
/// ## 为什么不硬编码标识符
///
/// 一开始这里是 `containerURL(forSecurityApplicationGroupIdentifier:)` 直接喂
/// `group.com.llkhs.CheckJuice`。**自签环境里这必然失败**：重签名工具（Esign 之类）
/// 会把**它那张证书自己那套组**写进二进制的 entitlements，例如
/// `group.163448086d837d1e.1` … `.5`，而**仓库里写什么它看都不看**。
/// 于是容器为 nil、App 和小组件各自读空数据，**而且全程不报错**。
///
/// 但自签**本身是能用的** —— 网上那些自签装的带小组件的 App（天气、汇率之类）
/// 就是活证明。它们没做任何特殊的事，只是**用了签名工具给的那套组**。
/// 所以正确的做法不是「要求签名方满足我」，而是**问系统「我现在到底有哪些组」**。
///
/// ## 怎么算出来
///
/// 候选顺序 = `identifier`（正式签名时它能用）+ 本进程 entitlements 里的组（字典序）。
/// 取第一个真能拿到容器的。
///
/// **两边不需要通信就能算出同一个答案** —— App 和小组件各自问自己的 entitlements，
/// 而重签名工具是拿同一套组改所有二进制的。这也顺便绕开了
/// 「想共享配置得先有共享容器」的鸡生蛋问题。
public enum AppGroup {
    /// 项目里声明的组。**正式签名（付费账号 / TestFlight）时就是它生效。**
    /// 自签时它多半不被授予，会被下面的探测跳过。
    public static let identifier = "group.com.llkhs.CheckJuice"

    /// 候选组，顺序确定。
    ///
    /// 来源只有**一个文件**：主 App bundle 里的 `embedded.mobileprovision`。
    /// App 和小组件读的是同一个文件 → 得到同一个列表 → 必然选中同一个组。
    /// 这就是为什么不需要任何额外的共享存储。
    ///
    /// ⚠️ 试过用 `SecTaskCopyValueForEntitlement` 直接读本进程实际生效的 entitlements
    /// （那才是 `containerURL` 校验的东西，更权威），但 **`SecTask` 系列是 macOS-only，
    /// iOS SDK 里根本没有** —— CI 报 `cannot find 'SecTaskCreateFromSelf' in scope`。
    /// 想让 CI 替你验，就别凭印象用 API。
    public static var candidates: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for id in ([identifier] + declaredGroups) where seen.insert(id).inserted {
            out.append(id)
        }
        return out
    }

    /// 主 App 描述文件里声明的组（字典序，保证两侧顺序一致）。
    public static var declaredGroups: [String] {
        guard let url = containingAppProfileURL,
              let groups = ProvisioningProfile.appGroups(at: url) else { return [] }
        return groups.sorted()
    }

    /// 主 App bundle 的 `embedded.mobileprovision`。
    ///
    /// 小组件进程跑在 `<App>.app/PlugIns/<Widget>.appex` 里，往上就能找到主 App bundle ——
    /// **它能读这个文件**，所以两个进程有同一份权威来源。
    /// 不像 appex 自己那份描述文件，签名工具经常直接删掉。
    private static var containingAppProfileURL: URL? {
        if Bundle.main.bundleURL.pathExtension == "app" {
            return profile(in: Bundle.main.bundleURL)
        }
        var dir = Bundle.main.bundleURL
        for _ in 0..<4 {
            dir = dir.deletingLastPathComponent()
            if dir.pathExtension == "app" { return profile(in: dir) }
        }
        return nil
    }

    private static func profile(in appBundle: URL) -> URL? {
        let url = appBundle.appendingPathComponent("embedded.mobileprovision")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// 第一个真能拿到容器的候选。只解析一次。
    public static let resolvedIdentifier: String? = candidates.first {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) != nil
    }

    /// App Group 共享容器根目录。没有任何一个候选可用时为 nil。
    public static var containerURL: URL? {
        guard let id = resolvedIdentifier else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)
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
        if declaredGroups.isEmpty {
            return "找不到主 App 的描述文件，没法知道这个包被授予了哪些 App Group。"
                + "项目声明的「\(identifier)」也用不了 —— 设置页 → 排查，看详细结论。"
        }
        return "描述文件授予了 \(declaredGroups.count) 个组，但一个都拿不到容器："
            + declaredGroups.joined(separator: ", ")
            + "。设置页 → 排查，看详细结论。"
    }
}
