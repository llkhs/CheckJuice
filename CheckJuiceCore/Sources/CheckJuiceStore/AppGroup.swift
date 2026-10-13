import Foundation

/// App Group 配置 —— App 与 Widget 唯一的共享通道。
///
/// ⚠️ **这个标识符必须与描述文件（`.mobileprovision`）里
/// `com.apple.security.application-groups` 列出的某一个值逐字符相同。**
/// 对不上的话，App 和 Widget 会各自拿到两个不同的容器，Widget 永远读到空数据，
/// 而且**不会报错** —— 只会静默显示"无设备"，这是最难查的一类问题。
///
/// 当前值是**占位**。签名阶段由 CI 从描述文件读出真实值后替换
/// （逻辑见 `.github/workflows/`），不需要手工维护。
public enum AppGroup {
    public static let identifier = "group.com.llkhs.CheckJuice"

    /// App Group 共享容器根目录。未配置或描述文件不含该 group 时为 nil。
    public static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }
}
