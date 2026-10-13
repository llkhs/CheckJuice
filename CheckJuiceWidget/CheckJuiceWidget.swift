import WidgetKit
import SwiftUI
import CheckJuiceCore
import CheckJuiceStore

struct CheckJuiceEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct CheckJuiceProvider: TimelineProvider {
    func placeholder(in context: Context) -> CheckJuiceEntry {
        CheckJuiceEntry(date: Date(), snapshot: .empty)
    }

    func getSnapshot(in context: Context,
                     completion: @escaping (CheckJuiceEntry) -> Void) {
        completion(CheckJuiceEntry(date: Date(), snapshot: SnapshotStore().load()))
    }

    func getTimeline(in context: Context,
                     completion: @escaping (Timeline<CheckJuiceEntry>) -> Void) {
        let entry = CheckJuiceEntry(date: Date(), snapshot: SnapshotStore().load())
        // 兜底刷新。正常情况下主 App 一改数据就会 reloadAllTimelines，
        // 这里只是防止 App 长时间没打开导致小组件停在旧值上。
        let next = Calendar.current.date(byAdding: .hour, value: 6, to: Date())
            ?? Date().addingTimeInterval(6 * 3600)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

struct CheckJuiceWidgetView: View {
    let entry: CheckJuiceEntry

    var body: some View {
        if entry.snapshot.devices.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "battery.100")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("还没有物品")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(entry.snapshot.devices.prefix(3))) { device in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(device.urgency.tint)
                            .frame(width: 8, height: 8)
                        Text(device.name)
                            .font(.caption)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(device.headline)
                            .font(.caption)
                            .monospacedDigit()
                            .fontWeight(.semibold)
                            .foregroundStyle(device.urgency.tint)
                    }
                }
                if entry.snapshot.devices.count > 3 {
                    Text("还有 \(entry.snapshot.devices.count - 3) 项")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

/// 小组件扩展里 `Color` 同样是 SwiftUI 的东西，所以这里要有一份和 App 层一致的映射。
extension Urgency {
    var tint: Color {
        switch self {
        case .overdue: return .red
        case .risk: return .orange
        case .stockUp: return .yellow
        case .normal: return .green
        }
    }
}

struct CheckJuiceWidget: Widget {
    let kind = "CheckJuiceWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CheckJuiceProvider()) { entry in
            CheckJuiceWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Check Juice")
        .description("一眼看清哪些东西快没电了。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct CheckJuiceWidgetBundle: WidgetBundle {
    var body: some Widget {
        CheckJuiceWidget()
    }
}
