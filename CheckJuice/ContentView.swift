import SwiftUI
import CheckJuiceCore

/// 显示分级 → 颜色。放在 App 层，因为 `Color` 是 SwiftUI 的东西，
/// Core 包要保持零 UI 依赖。
///
/// 三级：耗尽红 / 该处理黄 / 正常。
/// **不再用 `Urgency` 上色** —— 那四级里的「橙色风险窗口」已经并进黄色。
extension DisplayLevel {
    var tint: Color {
        switch self {
        case .exhausted: return .red
        case .soon: return .yellow
        case .normal: return .secondary
        }
    }

    /// 主文案（「还剩 X 小时」）的颜色。正常态用正文色，不用灰色 ——
    /// 这是每一行最重要的信息，别为了「不打扰」把它压暗。
    var textColor: Color {
        self == .normal ? .primary : tint
    }

    var symbolName: String {
        switch self {
        case .exhausted: return "battery.0"
        case .soon: return "battery.25"
        case .normal: return "battery.100"
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

    /// 待确认删除的那台设备。
    ///
    /// **存整个 `Device` 而不是 id**：确认框要把名字念给用户听，
    /// 拆成 id + name 两个 `@State` 就会出现「清了 id 忘了清 name」的错位窗口，
    /// 而这里只可能是整台设备一起进、一起出。`Device` 本来就是 `Hashable` 的。
    @State private var pendingDelete: Device?

    /// 已生成的导出文件。非 nil 就弹分享面板。
    @State private var exportFile: ExportItem?

    /// `ShareLink` 的 item 要有 identity；`URL` 本身不满足 `Identifiable`。
    private struct ExportItem: Identifiable {
        let id = UUID()
        let url: URL
        init(_ url: URL) { self.url = url }
    }

    /// 排序切换。用 `Menu` + `Picker` 而不是分段控件：
    /// 四个选项横排在导航栏里放不下，而 `Picker` 在 `Menu` 里会自动打勾。
    private var sortMenu: some View {
        Menu {
            Picker("排序方式", selection: Binding(
                get: { model.sortMode },
                set: { model.setSortMode($0) }
            )) {
                ForEach(SortMode.allCases) { mode in
                    Label(mode.displayName, systemImage: mode.symbolName).tag(mode)
                }
            }
        } label: {
            Label("排序", systemImage: "arrow.up.arrow.down")
        }
    }

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
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            pendingDelete = item.device
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
                ToolbarItemGroup(placement: .primaryAction) {
                    if model.developerMode {
                        Button {
                            exportFile = (try? model.makeExportFile()).map(ExportItem.init)
                        } label: {
                            Label("导出", systemImage: "square.and.arrow.up")
                        }
                    }
                    sortMenu
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
            // 导出：先生成文件再弹分享面板，而不是把 `ShareLink` 直接塞进工具栏 ——
            // `ShareLink` 需要提前拿到真实的文件 URL，否则点开是空分享。
            .sheet(item: $exportFile) { item in
                ExportSheet(url: item.url)
            }
            .confirmationDialog(
                "移到回收站？",
                isPresented: Binding(
                    get: { pendingDelete != nil },
                    set: { if !$0 { pendingDelete = nil } }
                ),
                titleVisibility: .visible,
                presenting: pendingDelete
            ) { device in
                Button("移到回收站", role: .destructive) { model.delete(id: device.id) }
            } message: { device in
                Text("「\(device.name)」会先放在回收站里，"
                     + "\(Int(Device.trashRetentionDays)) 天内可以在「设置 → 回收站」找回来，之后自动清除。")
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
            Image(systemName: item.level.symbolName)
                .font(.title2)
                .foregroundStyle(item.level.tint)
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
                    // 主数字的颜色 = 「还剩多久」这个信息本身的紧急程度。
                    // 红色：已经过了中位耗尽时刻；黄色：离风险窗口不足提前提醒量。
                    .foregroundStyle(item.level.textColor)
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


/// 导出完成后的小面板：告诉你文件叫什么、多大，然后交给系统分享。
///
/// 不让「点一下就静默生成了一个文件」——用户不知道文件在哪、叫什么，
/// 也就没法把它发给任何人。
private struct ExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let url: URL

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                Image(systemName: "doc.text")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)

                Text(url.lastPathComponent)
                    .font(.headline)
                    .monospaced()

                Text(sizeText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ShareLink(item: url) {
                    Label("分享 / 存到「文件」", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 6)

                Text("包含每台设备的原始更换时刻、当前预测、后验参数和模型配置 —— "
                     + "拿这份 JSON 就能复现一次完整的计算。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .navigationTitle("导出完成")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private var sizeText: String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let bytes = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
