import Foundation
import CheckJuiceCore

/// 设备清单的持久化。
///
/// 存 JSON 而不是 SwiftData / CoreData：数据量是「几十台设备」级别，
/// 用 ORM 是杀鸡用牛刀；而且 JSON 天然适配 App Group 容器，
/// 将来真要换存储，也只是把这一层换掉，`CheckJuiceCore` 一行不动。
public struct DeviceStore: Sendable {
    private static let fileName = "devices.json"

    private let fileURL: URL?

    public init() {
        self.fileURL = AppGroup.containerURL?.appendingPathComponent(Self.fileName)
    }

    /// 读取全部设备。文件不存在或损坏时返回空数组 —— 绝不让损坏的数据把 App 卡死。
    public func load() -> [Device] {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Device].self, from: data)) ?? []
    }

    public func save(_ devices: [Device]) throws {
        guard let fileURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(devices)
        try data.write(to: fileURL, options: .atomic)
    }
}
