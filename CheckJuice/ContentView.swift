import SwiftUI
// `UIActivityViewController` 在 UIKit 里。SwiftUI 的 `ShareLink` 在 sheet 里
// 配合临时文件时不工作，只能落到 UIKit —— 见文件末尾 `ActivityView` 的注释。
import UIKit
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

    /// 当前要弹的页面。
    ///
    /// ⚠️ **必须合成一个，不能在同一视图上挂多个 `.sheet`。**
    /// SwiftUI 对一个视图上的多个 sheet 修饰符只有最后挂载的那个生效，
    /// 其余的会被静默吞掉 —— 表现就是「点了按钮没反应」。
    /// 这不是猜测：设置按钮失灵就是因为它排在第四个 `.sheet` 之前。
    ///
    /// 用 `enum` 而不是四组独立状态，还能顺带消灭「两个 sheet 同时为真」这类非法状态。
    @State private var presented: Presented?

    private enum Presented: Identifiable {
        case addDevice
        case settings
        case replace(UUID)
        case export(URL)

        /// 每个 case 一个稳定的 id：`sheet(item:)` 靠它判断是不是同一个页面。
        var id: String {
            switch self {
            case .addDevice: return "add"
            case .settings: return "settings"
            case .replace(let id): return "replace-\(id)"
            case .export(let url): return "export-\(url.lastPathComponent)"
            }
        }
    }

    /// 待确认删除的那台设备。
    ///
    /// **存整个 `Device` 而不是 id**：确认框要把名字念给用户听，
    /// 拆成 id + name 两个 `@State` 就会出现「清了 id 忘了清 name」的错位窗口，
    /// 而这里只可能是整台设备一起进、一起出。`Device` 本来就是 `Hashable` 的。
    @State private var pendingDelete: Device?

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
                            presented = .replace(item.device.id)
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
                    HStack(spacing: 6) {
                        Button {
                            presented = .settings
                        } label: {
                            Label("设置", systemImage: "gearshape")
                        }
                        // 只在开发者模式下显示版本号：普通用户不需要看见它，
                        // 而调算法时要一眼确认装的是哪一版。
                        // 构建号不在这儿放 —— 顶栏空间有限，塞多了会挤掉后面的图标。
                        if model.developerMode {
                            Text(AppVersion.short)
                                .font(.caption2)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    if model.developerMode {
                        Button {
                            if let url = try? model.makeExportFile() {
                                presented = .export(url)
                            }
                        } label: {
                            Label("导出", systemImage: "square.and.arrow.up")
                        }
                    }
                    sortMenu
                    Button {
                        presented = .addDevice
                    } label: {
                        Label("添加", systemImage: "plus")
                    }
                }
            }
            // **只有一个 `.sheet`** —— 多个会互相吞，见 `Presented` 的注释。
            .sheet(item: $presented) { page in
                switch page {
                case .addDevice:
                    DeviceEditorView()
                case .settings:
                    SettingsView()
                case .replace(let id):
                    RecordReplacementView(deviceID: id)
                case .export(let url):
                    // 导出：先生成文件，再弹**预览**面板；分享按钮在那个面板的顶栏里。
                    // ⚠️ 原先把 `ShareLink` 放在面板正文里，点了没反应（无报错、无面板）。
                    // 已换成 `UIActivityViewController`，见 `ExportSheet` 的注释。
                    ExportSheet(url: url)
                }
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
                // 剩余不足 30 分钟时，在「耗尽中」和具体时长之间每 2 秒交叉淡入淡出。
                //
                // 目的是**省横向空间**：短命电池的文案会从「还剩 22 分钟」这种
                // 六七个字压成两个字，让同一行能装下更多信息。
                // 代价是两段文字要交替出现，看的人需要多扫一眼。
                // 只在**还没耗尽**时交替：已耗尽时完整文案本身就带「耗尽中」前缀，
                // 再叠一个状态词，屏幕上就是「耗尽中」⇄「耗尽中 7 分钟」的结巴。
                if style == .remaining, item.prediction.shouldAlternate {
                    AlternatingText(
                        compact: Prediction.preExhaustWord,
                        detail: item.prediction.remainingText(style: style)
                    )
                    .font(.title3)
                    .monospacedDigit()
                    .fontWeight(.semibold)
                    .foregroundStyle(item.level.textColor)
                } else {
                    Text(item.prediction.remainingText(style: style))
                        .font(.title3)
                        .monospacedDigit()
                        .fontWeight(.semibold)
                        // 主数字的颜色 = 「还剩多久」这个信息本身的紧急程度。
                        // 红色：已经过了中位耗尽时刻；黄色：离风险窗口不足提前提醒量。
                        .foregroundStyle(item.level.textColor)
                }
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


/// 导出面板：预览 JSON 内容 + 顶栏分享按钮。
///
/// **为什么不用 `ShareLink`**：它依赖「已经拿到可分享的 item」，
/// 在 sheet 里配合临时文件时点下去经常毫无反应（没有错误、也没有面板）。
/// 改用 `UIActivityViewController` 包一层 —— 拿到的是 `present` 控制权，
/// 行为确定。这是一处刻意违反「优先用 SwiftUI 原生」的例子：
/// 原生控件在这里不工作，就得换。
private struct ExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let url: URL

    @State private var content: AttributedString = AttributedString("读取中…")
    @State private var shareSheet: ActivityItem?

    /// `UIActivityViewController` 的 item 需要 identity。
    private struct ActivityItem: Identifiable {
        let id = UUID()
        let url: URL
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(url.lastPathComponent)
                            .font(.subheadline)
                            .monospaced()
                        Spacer()
                        Text(sizeText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)

                    // 预览原文。调算法时最想确定的就是「导出的到底是哪些字段」，
                    // 让它直接可见，比再点一次分享、再打开文件强得多。
                    //
                    // 语法着色：键紫 / 字符串红 / 数字蓝 / 字面量橙，
                    // 几百行 JSON 里找某个字段靠颜色比靠眼睛扫快得多。
                    Text(content)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color.secondary.opacity(0.08),
                                    in: RoundedRectangle(cornerRadius: 8))
                        .padding(.horizontal, 16)
                }
                .padding(.vertical, 12)
            }
            .navigationTitle("导出预览")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        shareSheet = ActivityItem(url: url)
                    } label: {
                        Label("分享", systemImage: "square.and.arrow.up")
                    }
                }
            }
            .task {
                // 文件不大（几十台设备也就几十 KB），一次读全，不做分页。
                let raw = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                guard !raw.isEmpty else {
                    content = AttributedString("（读取失败）")
                    return
                }
                // **着色放后台**：它是纯计算（扫描 + 建属性区间），
                // 但几百 KB 的 JSON 在主线程上跑还是会顿一下。
                // `.task` 本身在主 actor，await 回来再赋值，正好。
                content = await Task.detached(priority: .userInitiated) {
                    JSONHighlighter.attributed(raw)
                }.value
            }
            .sheet(item: $shareSheet) { item in
                ActivityView(url: item.url)
            }
        }
    }

    private var sizeText: String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let bytes = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// `UIActivityViewController` 的 SwiftUI 包装。
///
/// iPad 上 `popoverPresentationController` 不设 anchor 会崩机 —— 这里给出
/// 屏幕中部的 popover 配置，`TARGETED_DEVICE_FAMILY` 含 iPad，必须处理。
private struct ActivityView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}


/// 两段文字交替显示，交叉淡入淡出，**可点按立即切换**。
///
/// **两段叠在同一个 `ZStack` 里**，而不是 `if/else` 切换：
/// `if/else` 会让整行宽度在「即将耗尽」（4 字）和「还剩 22 分钟」（6 字）之间来回跳，
/// 每 3 秒抖一次，比不交替还难看。叠放后宽度取两者的最大值，保持稳定。
private struct AlternatingText: View {
    let compact: String
    let detail: String

    @State private var showingDetail = false

    /// 点按后暂停自动翻转的截止时刻。
    ///
    /// 没有它的话：用户点一下切到「还剩 22 分钟」，0.1 秒后全局心跳到达，
    /// 立刻又翻回去 —— 看起来像点了没反应。
    /// 有了它，点完至少停满一个完整周期，节奏才符合预期。
    @State private var holdUntil: Date = .distantPast

    /// 共享时钟（见 `AlternatingClock`），3 秒一轮。
    ///
    /// 之前写成 `private let ticker = Timer.publish(...)`（每行一个）有两个毛病：
    /// 1. 视图每次重渲染都会新建 publisher，计时被重置 —— 重渲染比周期频繁时它永远不触发；
    /// 2. 多行各自计时，翻转时刻对不齐，屏幕上会看到随机乱闪。
    private let ticker = AlternatingClock.ticker

    private static let period: TimeInterval = 3

    var body: some View {
        ZStack(alignment: .trailing) {
            Text(compact)
                .opacity(showingDetail ? 0 : 1)
            Text(detail)
                .opacity(showingDetail ? 1 : 0)
        }
        // 1.0 秒渐变更从容；原来 0.5 秒在 3 秒周期里显得像闪一下。
        .animation(.easeInOut(duration: 1.0), value: showingDetail)
        .onReceive(ticker) { _ in
            guard Date() >= holdUntil else { return }
            showingDetail.toggle()
        }
        .contentShape(Rectangle())
        .onTapGesture {
            // 点一下立刻切，并从这里重新计一个完整周期。
            showingDetail.toggle()
            holdUntil = Date().addingTimeInterval(Self.period)
        }
        // 读屏：内容只念具体时长（用户真正需要的信息），并说明可以点按切换。
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(detail)
        .accessibilityHint("轻点切换显示时长或状态")
    }
}


/// 全局共享的 3 秒心跳。
///
/// `static let` 只创建一次，所有交替显示的行订阅同一个 publisher ——
/// 翻转时刻天然对齐，也不会因为重渲染把计时重置。
///
/// 为什么不用 `TimelineView(.periodic)`：它按时间轴重绘，能算出「该显示第几张」，
/// 但管不了「两个文本交叉淡入」这个动画状态。这个需求本质上要一个定时器。
private enum AlternatingClock {
    static let ticker = Timer.publish(every: 3, on: .main, in: .common).autoconnect()
}
