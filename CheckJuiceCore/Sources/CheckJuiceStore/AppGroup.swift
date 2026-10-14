import Foundation
import Security

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
    /// 自签时它多半不在 entitlements 里，会被下面的探测跳过。
    public static let identifier = "group.com.llkhs.CheckJuice"

    private static let entitlementKey = "com.apple.security.application-groups"

    /// 本进程**实际生效**的 entitlements 里声明的组。
    ///
    /// 用 `SecTaskCreateFromSelf` 直接问内核，不去解析 `.mobileprovision` ——
    /// 系统在 `containerURL` 里校验的就是这份 entitlements，问同一份才不会自欺。
    /// （解析描述文件还会踩到「appex 里那个文件被签名工具删了」这种坑。）
    public static var entitledGroups: [String] {
        guard let task = SecTaskCreateFromSelf(nil),
              let raw = SecTaskCopyValueForEntitlement(
                  task, entitlementKey as CFString, nil
              ) as? [String]
        else { return [] }
        return raw
    }

    /// 按确定性顺序排列的候选组。
    ///
    /// 三个来源，顺序固定（`identifier` → entitlements → 描述文件），
    /// **所以 App 和小组件独立计算也会得到同一个列表**。
    ///
    /// 描述文件那一路是兜底：万一本进程 entitlements 读不出来，
    /// 两边都还能从**主 App 的** `embedded.mobileprovision` 里得到同一份组清单
    /// （小组件在主 App 的 bundle 里，读得到它）。
    public static var candidates: [String] {
        var seen = Set<String>()
        var out: [String] = []
        let sources = [entitledGroups.sorted(), profileGroups]
        for id in ([identifier] + sources.flatMap { $0 }) where seen.insert(id).inserted {
            out.append(id)
        }
        return out
    }

    /// 描述文件里声明的组。兜底用。
    private static var profileGroups: [String] {
        var groups: [String] = []
        for url in profileURLs {
            if let list = ProvisioningProfile.appGroups(at: url) {
                groups.append(contentsOf: list)
            }
        }
        return groups.sorted()
    }

    /// 自己 bundle 的描述文件 + **外层 App bundle** 的描述文件。
    ///
    /// 后者是关键：小组件跑在 `<App>.app/PlugIns/<Widget>.appex` 里，能读到主 App 的
    /// 描述文件，于是两个进程有了一份**共同的**组清单。
    private static var profileURLs: [URL] {
        var urls: [URL] = []
        if let own = Bundle.main.url(forResource: "embedded",
                                     withExtension: "mobileprovision") {
            urls.append(own)
        }
        if let containing = containingAppProfileURL, !urls.contains(containing) {
            urls.append(containing)
        }
        return urls
    }

    private static var containingAppProfileURL: URL? {
        var dir = Bundle.main.bundleURL
        for _ in 0..<4 {
            dir = dir.deletingLastPathComponent()
            if dir.pathExtension == "app" {
                let profile = dir.appendingPathComponent("embedded.mobileprovision")
                return FileManager.default.fileExists(atPath: profile.path) ? profile : nil
            }
        }
        return nil
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
        if entitledGroups.isEmpty {
            return "这个 App 现在一个可用的 App Group 都没有，"
                + "物品不会真正存下来，小组件也读不到。（设置页 → 诊断 看详情）"
        }
        return "系统授予了 \(entitledGroups.count) 个组，但一个都拿不到容器："
            + entitledGroups.joined(separator: ", ")
            + "。（设置页 → 诊断 看详情）"
    }
}
