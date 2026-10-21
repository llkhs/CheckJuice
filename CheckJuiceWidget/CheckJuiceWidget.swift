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
        // 先留一张「我在哪儿、我看到了什么」的纸条，再干活。
        // 失败必须留痕：小组件读空时，主 App 的人需要知道是**哪个进程在哪块地方**读空的，
        // 否则只能继续猜。诊断页会去每个候选组里翻这张纸条。
        WidgetEnv.writeHere()
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
                            .fill(device.level.tint)
                            .frame(width: 8, height: 8)
                        Text(device.name)
                            .font(.caption)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(device.headline)
                            .font(.caption)
                            .monospacedDigit()
                            .fontWeight(.semibold)
                            .foregroundStyle(device.level.tint)
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
///
/// **三级**，跟 App 列表用同一套判据（`DisplayLevel`，在主 App 里算好写进快照）。
/// 以前这里是四级的 `Urgency` 配色，其中橙色「风险窗口」已并进黄色。
extension DisplayLevel {
    var tint: Color {
        switch self {
        case .exhausted: return .red
        case .soon: return .yellow
        case .normal: return .secondary
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
