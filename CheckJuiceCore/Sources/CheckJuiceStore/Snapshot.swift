import Foundation
import CheckJuiceCore

/// 单台设备在小组件上要显示的全部信息。
///
/// 刻意是**扁平的值类型**：Widget 只需要「读 JSON → 画界面」，
/// 不该在扩展进程里再跑一遍算法、也不该再解一次设备结构。
public struct DeviceSnapshot: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var batteryDisplayName: String
    public var urgency: Urgency
    public var remainingDays: Int
    public var riskRemainingDays: Int
    public var medianDate: Date
    public var confidence: Confidence
    /// 直接上屏的短文案，由 `Prediction` 统一生成，避免 App 与 Widget 各写一套。
    public var headline: String

    public init(
        id: UUID, name: String, batteryDisplayName: String, urgency: Urgency,
        remainingDays: Int, riskRemainingDays: Int, medianDate: Date,
        confidence: Confidence, headline: String
    ) {
        self.id = id
        self.name = name
        self.batteryDisplayName = batteryDisplayName
        self.urgency = urgency
        self.remainingDays = remainingDays
        self.riskRemainingDays = riskRemainingDays
        self.medianDate = medianDate
        self.confidence = confidence
        self.headline = headline
    }

    public init(device: Device, prediction: Prediction) {
        self.init(
            id: device.id,
            name: device.name,
            batteryDisplayName: device.kind.displayName,
            urgency: prediction.urgency,
            remainingDays: prediction.remainingDays,
            riskRemainingDays: prediction.riskRemainingDays,
            medianDate: prediction.medianDate,
            confidence: prediction.confidence,
            headline: prediction.shortDescription
        )
    }
}

/// 小组件读的那一份快照。
public struct WidgetSnapshot: Codable, Sendable {
    public var generatedAt: Date
    public var devices: [DeviceSnapshot]

    public init(generatedAt: Date, devices: [DeviceSnapshot]) {
        self.generatedAt = generatedAt
        self.devices = devices
    }

    public static let empty = WidgetSnapshot(generatedAt: .distantPast, devices: [])

    /// 按紧急度排序，最该处理的排最前 —— 小组件空间有限，只显示得下前几台。
    public var sortedByUrgency: [DeviceSnapshot] {
        let rank: [Urgency: Int] = [.overdue: 0, .risk: 1, .stockUp: 2, .normal: 3]
        return devices.sorted {
            let a = rank[$0.urgency] ?? 9
            let b = rank[$1.urgency] ?? 9
            return a == b ? $0.remainingDays < $1.remainingDays : a < b
        }
    }
}

/// 快照的读写。主 App 写，Widget 读。
public struct SnapshotStore: Sendable {
    private static let fileName = "widget_snapshot.json"

    private let fileURL: URL?

    public init() {
        self.fileURL = AppGroup.containerURL?.appendingPathComponent(Self.fileName)
    }

    public func load() -> WidgetSnapshot {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return .empty }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(WidgetSnapshot.self, from: data)) ?? .empty
    }

    public func save(_ snapshot: WidgetSnapshot) throws {
        guard let fileURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
    }
}
