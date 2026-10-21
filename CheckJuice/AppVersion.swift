import Foundation

/// App 版本信息。读自 `Info.plist`，不写死任何字符串。
///
/// **为什么必须读 plist 而不是硬编码**：版本号写在 `project.yml` 的
/// `MARKETING_VERSION` 里，CI 还会用 GitHub run number 覆盖 `CURRENT_PROJECT_VERSION`。
/// 代码里再抄一份常量，两边迟早对不上，而且对不上的时候没人会发现。
enum AppVersion {
    /// `CFBundleShortVersionString` —— 面向用户的版本号，如 `0.1.1`。
    static var marketing: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    /// `CFBundleVersion` —— 构建号。CI 里等于 GitHub run number。
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    /// 设置页用的完整信息：`0.1.1 (12)`。
    static var full: String {
        "\(marketing) (\(build))"
    }

    /// 主页顶栏用的短版本号 —— 只放版本，构建号太长会挤掉图标。
    static var short: String {
        "v\(marketing)"
    }
}
