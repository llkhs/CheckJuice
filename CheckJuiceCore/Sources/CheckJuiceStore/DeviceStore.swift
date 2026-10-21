import Foundation
import CheckJuiceCore

/// 设备清单的持久化。
///
/// 存 JSON 而不是 SwiftData / CoreData：数据量是「几十台设备」级别，
/// 用 ORM 是杀鸡用牛刀；而且 JSON 天然适配 App Group 容器，
/// 将来真要换存储，也只是把这一层换掉，`CheckJuiceCore` 一行不动。
public struct DeviceStore: Sendable {
    /// 公开是为了诊断页能显示**确切的**路径 —— App Group 出错时它会是 nil，
    /// 而这件事除了「数据重启就没了」以外不带任何提示。
    public let fileURL: URL?

    /// `fileURL` 可注入：生产走 App Group 容器的默认路径，测试传临时目录。
    /// 不然这套编解码**没有任何可测的入口** —— 而它正是 App 与小组件之间的契约。
    public init(fileURL: URL? = AppGroup.devicesFileURL) {
        self.fileURL = fileURL
    }

    /// 读取全部设备。文件不存在或损坏时返回空数组 —— 绝不让损坏的数据把 App 卡死。
    public func load() -> [Device] {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // ⚠️ 这里曾经有一次「把时刻对齐到分钟」的迁移，已移除。
        // 它造成过真机事故：同一分钟内创建的四台设备被压成同一时间戳
        // （全部 10:46:00），排序无从区分。而且它把「真实此刻」往回挪了，
        // 数据反而更不准。详见 `DeviceEditorView.now` 的注释。
        return (try? decoder.decode([Device].self, from: data)) ?? []
    }

    /// 存不进去就**抛错**，不装作成功。
    ///
    /// 原来这里是 `guard let fileURL else { return }` —— 拿到空容器时静默返回成功，
    /// 于是「添加物品 → 界面正常 → 重启全没了 → 小组件一直空着」，
    /// 而且一个字都不报。这是这个 App 最不能接受的失败方式。
    public func save(_ devices: [Device]) throws {
        guard let fileURL else { throw StoreError.appGroupUnavailable }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(devices)
        try data.write(to: fileURL, options: .atomic)
    }
}
