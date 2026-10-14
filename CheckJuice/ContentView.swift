import SwiftUI
import CheckJuiceCore

/// 紧急度 → 颜色。放在 App 层，因为 `Color` 是 SwiftUI 的东西，
/// Core 包要保持零 UI 依赖。
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

/// 「已经用了多久」。量级换算（≥60 天说月 / ≥2 天说天 / 否则说小时）
/// 统一在 `DurationText` 里，别在这儿再抄一份阈值。
struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var showingAdd = false
    @State private var showingSettings = false

    /// 滑动「已换电池」后待记账的那台。**存 id 不存 `Device` 值** ——
    /// 值快照会过期，表单却是异步弹出来的。
    @State private var replacementTarget: ReplacementTarget?

    /// `.sheet(item:)` 要一个 Identifiable 包装：直接用 `UUID?` 的话，
    /// 关闭时把 state 置 nil 会让内容在整个收起动画里先消失。
    private struct ReplacementTarget: Identifiable { let id: UUID }

    var body: some View {
        NavigationStack {
            List {
                if let storageError = model.storageError {
                    Section {
                        Label {
                            Text(storageError)
                                .font(.footnote)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                        }
                        .foregroundStyle(.red)
                    }
                }

                ForEach(model.ranked) { item in
                    NavigationLink {
                        DeviceEditorView(editingID: item.device.id)
                    } label: {
                        DeviceRow(
                            item: item,
                            style: model.displayStyle,
                            showMedian: model.showMedianSubline
                        )
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            model.delete(id: item.device.id)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        Button {
                            replacementTarget = ReplacementTarget(id: item.device.id)
                        } label: {
                            Label("已换电池", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .tint(.blue)
                    }
                }
            }
            .overlay {
                if model.ranked.isEmpty {
                    ContentUnavailableView(
                        "还没有物品",
                        systemImage: "battery.100",
                        description: Text("点右上角 + 添加第一个要盯电池的东西")
                    )
                }
            }
            .navigationTitle("Check Juice")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingSettings = true
                    } label: {
                        Label("设置", systemImage: "gearshape")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAdd = true
                    } label: {
                        Label("添加", systemImage: "plus")
                    }
                }
            }
            .sheet(item: $replacementTarget) { target in
                RecordReplacementView(deviceID: target.id)
            }
            .sheet(isPresented: $showingAdd) {
                // 推入导航栈时外面已经有栈了，弹 sheet 得自己包一层。
                NavigationStack { DeviceEditorView(editingID: nil) }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView(
                    style: model.displayStyle,
                    showMedianSubline: model.showMedianSubline,
                    onStyleChange: { model.setDisplayStyle($0) },
                    onShowMedianChange: { model.setShowMedianSubline($0) }
                )
            }
        }
    }
}

struct DeviceRow: View {
    let item: RankedDevice
    let style: ExhaustDisplayStyle
    /// 是否显示中位小字。主文案报最坏情况（P10），这行报中位。
    let showMedian: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.prediction.urgency.symbolName)
                .font(.title2)
                .foregroundStyle(item.prediction.urgency.tint)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.device.name)
                    .font(.headline)
                Text("已用 " + DurationText.short(item.prediction.ageHours))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text(item.prediction.remainingText(style: style))
                    .font(.title3)
                    .monospacedDigit()
                    .fontWeight(.semibold)
                if showMedian {
                    Text(item.prediction.medianText(style: style))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

