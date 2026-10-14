import Foundation
import CheckJuiceCore

/// 单台设备在小组件上要显示的全部信息。
///
/// 刻意是**扁平的值类型**：Widget 只需要「读 JSON → 画界面」，
/// 不该在扩展进程里再跑一遍算法、也不该再解一次设备结构。
public struct DeviceSnapshot: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var urgency: Urgency
    public var remainingHours: Double
    public var p10RemainingHours: Double
    public var p50ExhaustAt: Date
    public var confidence: Confidence
    /// 直接上屏的短文案，由 `Prediction` 统一生成，避免 App 与 Widget 各写一套。
    ///
    /// 这是**预渲染好的主文案（P10）**：Widget 扩展进程不做任何格式化、不跑任何算法，
    /// 只负责把这份快照画出来。显示格式随用户设置变化，但变化发生在主 App 里。
    /// 小组件位置太小只放这一行 —— 中位小字是 App 列表独有的（且受设置页开关控制）。
    public var headline: String

    public init(
        id: UUID, name: String, urgency: Urgency,
        remainingHours: Double, p10RemainingHours: Double, p50ExhaustAt: Date,
        confidence: Confidence, headline: String
    ) {
        self.id = id
        self.name = name
        self.urgency = urgency
        self.remainingHours = remainingHours
        self.p10RemainingHours = p10RemainingHours
        self.p50ExhaustAt = p50ExhaustAt
        self.confidence = confidence
        self.headline = headline
    }

    /// 从设备与预测构造快照。
    ///
    /// `style` 是用户在设置页选的显示样式 —— 主 App 用它把 `headline` 渲染好再写进快照，
    /// Widget 直接显示，不重复实现格式化逻辑（也就不会两处走样）。
    public init(
        device: Device,
        prediction: Prediction,
        style: ExhaustDisplayStyle = .moment,
        timeZone: TimeZone = .current,
        locale: Locale = .current
    ) {
        self.init(
            id: device.id,
            name: device.name,
            urgency: prediction.urgency,
            remainingHours: prediction.remainingHours,
            p10RemainingHours: prediction.p10RemainingHours,
            p50ExhaustAt: prediction.p50ExhaustAt,
            confidence: prediction.confidence,
            headline: prediction.remainingText(style: style, timeZone: timeZone, locale: locale)
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
            return a == b ? $0.remainingHours < $1.remainingHours : a < b
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
