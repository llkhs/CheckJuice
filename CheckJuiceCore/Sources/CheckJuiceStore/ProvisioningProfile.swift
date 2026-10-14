import Foundation

/// 从 `.mobileprovision` 里读出**真正生效的** App Group 列表。
///
/// 为什么非要有这个：`.mobileprovision` 是一层 CMS 签名包着一段 XML plist，
/// 系统只认**这个文件里**列出的 App Group。项目里写的
/// `group.com.llkhs.CheckJuice` 只是「我想要」；描述文件里有没有，才是「能不能」。
///
/// 对不上时 `containerURL(forSecurityApplicationGroupIdentifier:)` 返回 nil，
/// App 和小组件各自读到空数据 —— **而且全程不报错**。
public enum ProvisioningProfile {
    /// 文件不存在 / 不是 plist / 没有 entitlements 时返回 nil（nil ≠ 空数组：
    /// 空数组表示「描述文件说了，但一个 group 都没给」）。
    public static func appGroups(at url: URL) -> [String]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return appGroups(in: data)
    }

    public static func appGroups(in data: Data) -> [String]? {
        // 整份文件不是合法 plist，必须把中间那段 XML 切出来单独解。
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8)),
              start.lowerBound < end.lowerBound
        else { return nil }

        let plistData = data.subdata(in: start.lowerBound..<end.upperBound)
        guard let plist = try? PropertyListSerialization.propertyList(
            from: plistData, options: [], format: nil
        ) as? [String: Any] else { return nil }

        let entitlements = plist["Entitlements"] as? [String: Any]
        return entitlements?["com.apple.security.application-groups"] as? [String]
    }
}
