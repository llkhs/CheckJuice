import Foundation

/// 小组件留下的「我在哪儿」纸条。
///
/// **为什么需要存在**：小组件读空时，现象和「真的没有物品」一模一样 ——
/// 都是「还没有物品」四个字。而原因可能是两个进程解析到了**不同的 App Group**，
/// 于是各自在各自的容器里读写，谁也看不见谁，**全程不报错**。
///
/// 有了这张纸条，主 App 的诊断页可以挨个候选组容器去翻：
/// 翻到纸条就知道小组件实际落在哪块地方、它当时 entitlements 里有什么。
/// 一次真机测试就能定位，而不是每轮重签重装重新猜。
public enum WidgetEnv {
    public static let fileName = "widget_env.json"

    public struct Record: Codable, Sendable {
        /// 本进程解析出的组（nil = 一个都没拿到容器）。
        public var resolvedGroup: String?
        /// 本进程 entitlements 里的组 —— 系统校验 `containerURL` 时看的就是它。
        public var entitledGroups: [String]
        public var writtenAt: Date
        /// 谁写的。目前只有小组件写，留个字段以免以后搞不清来源。
        public var process: String
    }

    /// 把本进程的解析结果写进**它自己解析到的**容器。写不进去就返回 false。
    @discardableResult
    public static func writeHere(process: String = "widget") -> Bool {
        guard let container = AppGroup.containerURL else { return false }
        let record = Record(resolvedGroup: AppGroup.resolvedIdentifier,
                            entitledGroups: AppGroup.entitledGroups,
                            writtenAt: Date(),
                            process: process)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            try encoder.encode(record)
                .write(to: container.appendingPathComponent(fileName), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// 从指定容器里读一张纸条。没有或读不动都返回 nil。
    public static func read(from container: URL) -> Record? {
        guard let data = try? Data(contentsOf: container.appendingPathComponent(fileName))
        else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Record.self, from: data)
    }
}
