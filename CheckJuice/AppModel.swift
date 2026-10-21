import Foundation
import Observation
import WidgetKit
import CheckJuiceCore
import CheckJuiceStore

/// 列表里的一项：设备 + 它当前的预测结论。
///
/// 用一个具名 struct 而不是 `(device:prediction:)` 元组 ——
/// **元组不支持 key path**，`ForEach(..., id: \.device.id)` 是编译不过的。
struct RankedDevice: Identifiable {
    var device: Device
    var prediction: Prediction
    var id: UUID { device.id }

    /// 上屏颜色分级。跟小组件用的是同一套判据（`DisplayLevel`），
    /// 不会出现「App 里黄、桌面上绿」这种两处走样。
    var level: DisplayLevel {
        DisplayLevel.make(prediction: prediction,
                          notifyLeadHours: device.notifyLeadHours)
    }
}

/// 主 App 的状态中枢。
///
/// 职责只有三件：读设备 → 算预测 → 把快照推进 App Group。
/// 算法本身在 `CheckJuiceCore` 里，这里一行数学都不写。
@Observable
final class AppModel {
    private let deviceStore = DeviceStore()
    private let snapshotStore = SnapshotStore()
    private let engine = LifetimeModel()

    /// **全部**设备，含回收站里的（磁盘上就是这么存的）。
    ///
    /// 别的地方一律用 `activeDevices` —— 让「回收站里的东西算不算数」
    /// 只在这一处回答，比在每个调用点各写一遍 `!$0.isTrashed` 可靠。
    var devices: [Device] = []

    /// 落盘出问题时的人话原因。非 nil 就在主页顶上挂一条红横幅。
    ///
    /// 存在的理由：`DeviceStore.save` 以前在容器为空时静默返回成功，
    /// 结果「添加物品 → 界面一切正常 → 重启全没了 → 小组件一直空着」，
    /// 全程一个字都不报。这种失败方式不可接受，必须响。
    var storageError: String?

    /// 用户在设置页选的主文案样式（「耗尽时刻」/「剩余时长」）。
    ///
    /// 持久化交给 `DisplaySettings`（App Group 共享域）—— 见那边的注释：
    /// M2b 的交互式小组件要在扩展进程里按同样样式渲染，所以设置必须共享。
    var displayStyle: ExhaustDisplayStyle = DisplaySettings.style

    /// 列表主文案下面那行「中位」小字是否显示。
    var showMedianSubline: Bool = DisplaySettings.showMedian

    /// 首页排序方式。
    var sortMode: SortMode = DisplaySettings.sortMode

    /// 开发者模式：打开后主页多一个导出按钮。
    var developerMode: Bool = DisplaySettings.developerMode

    init() {
        devices = deviceStore.load()
        // 启动时也要判一次，不然只有「下一次 commit」才会发现容器是空的。
        if !AppGroup.isAvailable { storageError = AppGroup.unavailableMessage }
        purgeExpiredTrash()
        reloadWidget()
    }

    /// 还在用的设备（主页、预测、小组件都只看这些）。
    var activeDevices: [Device] { devices.filter { !$0.isTrashed } }

    /// 回收站里的设备，最近丢的排最前。
    var trashedDevices: [Device] {
        devices.filter(\.isTrashed)
            .sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
    }

    /// 回收站里每条还剩几天被自动清掉。判定在 Core（`Device.daysLeftInTrash`），
    /// 这里只是把「现在」递进去 —— View 层不该自己算时间边界。
    func daysLeftInTrash(_ device: Device) -> Int {
        device.daysLeftInTrash(now: Date())
    }

    /// 清掉躺够 15 天的。
    ///
    /// 只在启动时跑，不做后台定时 —— App 本来就随时会被系统杀掉，
    /// 靠「下次打开时顺手清」最省事，而且用户打开时看到的状态和磁盘始终一致。
    private func purgeExpiredTrash() {
        let now = Date()
        let survivors = devices.filter { !$0.isTrashExpired(now: now) }
        guard survivors.count != devices.count else { return }
        devices = survivors
        persist()
    }

    /// 切换显示样式：落盘 + 立刻重算快照刷新小组件。
    func setDisplayStyle(_ style: ExhaustDisplayStyle) {
        guard style != displayStyle else { return }
        displayStyle = style
        DisplaySettings.style = style
        reloadWidget()
    }

    /// 中位小字的开关。只影响 App 自己的列表，小组件不显示小字，故不刷新时间线。
    func setShowMedianSubline(_ show: Bool) {
        guard show != showMedianSubline else { return }
        showMedianSubline = show
        DisplaySettings.showMedian = show
    }

    /// 切换排序方式。只影响 App 列表 —— 小组件只有三行，永远按紧急度取最急的。
    func setSortMode(_ mode: SortMode) {
        guard mode != sortMode else { return }
        sortMode = mode
        DisplaySettings.sortMode = mode
    }

    func setDeveloperMode(_ enabled: Bool) {
        guard enabled != developerMode else { return }
        developerMode = enabled
        DisplaySettings.developerMode = enabled
    }

    /// 全部设备按当前排序方式排列。
    ///
    /// 只看 `activeDevices`：回收站里的东西不该再占着主页、更不该进风险排序。
    var ranked: [RankedDevice] {
        let items = engine.predictions(for: activeDevices, now: Date())
            .map { RankedDevice(device: $0.device, prediction: $0.prediction) }

        switch sortMode {
        case .urgency:
            return items.sorted { lhs, rhs in
                let a = Self.rank(lhs.prediction.urgency)
                let b = Self.rank(rhs.prediction.urgency)
                if a != b { return a < b }
                return lhs.prediction.remainingHours < rhs.prediction.remainingHours
            }
        case .remaining:
            // 按**屏幕上那个数**排（P10 剩余）。用户看到「还剩 30 小时」排在
            // 「还剩 90 小时」前面才符合直觉；拿中位排会出现肉眼看起来乱序。
            return items.sorted { $0.prediction.p10RemainingHours < $1.prediction.p10RemainingHours }
        case .name:
            return items.sorted {
                $0.device.name.localizedStandardCompare($1.device.name) == .orderedAscending
            }
        case .recent:
            return items.sorted { Self.createdAt($0.device) > Self.createdAt($1.device) }
        }
    }

    /// 「添加时间」= 最早那条记录的时刻（也就是创建时填的基准点）。
    ///
    /// 不用 `id` 或文件顺序：那两者都对用户不可见，也没法解释「为什么这台排前面」。
    private static func createdAt(_ device: Device) -> Date {
        device.sortedEvents.first?.at ?? .distantPast
    }

    private static func rank(_ urgency: Urgency) -> Int {
        switch urgency {
        case .overdue: return 0
        case .risk: return 1
        case .stockUp: return 2
        case .normal: return 3
        }
    }

    // MARK: - 变更

    /// 新建一台设备。设备由表单自己构造好（含事件链），这里只负责落库 + 刷新快照。
    func add(_ device: Device) {
        devices.append(device)
        commit()
    }

    /// 记一次更换。`at` 是**新电池装上来的时刻**（默认此刻）；
    /// `kind` 描述的是**上一颗**是怎么结束的 —— 自然耗尽才算有效寿命样本，
    /// 提前更换 / 故障请显式传 `kind`，否则会污染统计。
    func markReplaced(_ device: Device, at: Date = Date(), kind: EventKind = .exhausted) {
        guard let index = devices.firstIndex(where: { $0.id == device.id }) else { return }
        devices[index].events.append(ReplacementEvent(at: at, kind: kind))
        commit()
    }

    /// 覆盖一台已有设备（编辑页保存）。按 id 定位，不在库里就什么都不做。
    func update(_ device: Device) {
        guard let index = devices.firstIndex(where: { $0.id == device.id }) else { return }
        devices[index] = device
        commit()
    }

    /// 按 id 取当前设备。
    ///
    /// 导航目标是 **id 不是 `Device` 值**：值快照会过期 —— 比如编辑页开着的时候，
    /// 小组件里刚记了一次更换，拿着旧快照保存就会把它抹掉。
    func device(withID id: UUID) -> Device? {
        devices.first { $0.id == id }
    }

    /// **软删除**：移进回收站，不是真删。
    ///
    /// 名字没改成 `moveToTrash`，是为了让主页那个 `.swipeActions` 的调用点保持原样 ——
    /// 交互上它就是「删除」，只是底下多了一层可撤销的缓冲。
    func delete(id: UUID) {
        guard let index = devices.firstIndex(where: { $0.id == id }) else { return }
        devices[index].deletedAt = Date()
        commit()
    }

    /// 从回收站捞回来。
    func restore(id: UUID) {
        guard let index = devices.firstIndex(where: { $0.id == id }) else { return }
        devices[index].deletedAt = nil
        commit()
    }

    /// 真删一条。只从回收站调用 —— 正常列表里没有「彻底删除」这个动作。
    func purge(id: UUID) {
        devices.removeAll { $0.id == id }
        commit()
    }

    /// 清空回收站。
    func emptyTrash() {
        devices.removeAll(where: \.isTrashed)
        commit()
    }

    // MARK: - 导出（开发者模式）

    /// 导出包。字段刻意用 `Codable` 结构体而不是手搓字典 ——
    /// 手搓的话改个字段名编译器不管，导出的 JSON 会静默少一列。
    private struct ExportBundle: Encodable {
        var exportedAt: Date
        /// 当时生效的模型参数。**必须带上**：光有数据没有参数，
        /// 复现问题时还得回忆「那时候跑的是哪套 beta / z10」。
        var modelConfig: ModelConfig
        /// 显示层设置，用来区分「算法结果」和「只是显示规则不同」。
        var displayStyle: ExhaustDisplayStyle
        var sortMode: SortMode
        var devices: [ExportDevice]
    }

    private struct ExportDevice: Encodable {
        /// 原始设备，含 `events` 的**精确时刻** —— 这是复现算法的唯一依据。
        /// 只导算好的结论没法复现任何东西。
        var device: Device
        var prediction: ExportPrediction
        /// 首页上那个「剩余小时数」的颜色标签 —— 也就是这台设备的提醒状态。
        ///
        /// 只放枚举值（`soon`）不够用：调算法时最想知道的恰恰是**为什么**它黄了
        /// （P10 掉到 3 小时？还是提前提醒量被设成 800 小时？）。
        /// 所以把判定依据和阈值一起带上。
        var status: ExportStatus
        var daysLeftInTrash: Int?
    }

    /// 颜色标签的完整描述。**这是给人看的，不是给机器看的。**
    private struct ExportStatus: Encodable {
        /// 颜色标签本身：`exhausted` / `soon` / `normal`。
        var level: DisplayLevel
        /// 中文名，跟界面上一致。
        var displayName: String
        /// 颜色，跟界面用的同一个（`red` / `yellow` / `default`）。
        var color: String
        /// 判定依据的一句话说明，带上算这一判需要的具体数字。
        var reason: String
        /// 判定时用到的两个数：P10 剩余（判据吃的是它）与提前提醒量。
        ///
        /// 单独列出来，是因为「还剩多少」和「提醒阈值」在 JSON 里隔着好几层，
        /// 想核对一次判定得来回翻 —— 摆在一起，一眼能看出 space 还有多少。
        var p10RemainingHours: Double
        var notifyLeadHours: Double
    }

    private struct ExportPrediction: Encodable {
        var medianHours: Double
        var p10Hours: Double
        var p50ExhaustAt: Date
        var p10ExhaustAt: Date
        var remainingHours: Double
        var p10RemainingHours: Double
        var ageHours: Double
        var ratio: Double
        var sigmaPrediction: Double
        var urgency: Urgency
        var confidence: Confidence
        var posterior: Posterior
    }

    /// 生成导出文件，返回可分享的临时文件 URL。
    ///
    /// 每次调用都重新写一份：数据量只有几十台，没必要做缓存失效逻辑。
    func makeExportFile() throws -> URL {
        let now = Date()
        let pairs = engine.predictions(for: activeDevices, now: now)
        let reference = engine.predictions(for: devices, now: now)
        let trashedDays = Dictionary(
            uniqueKeysWithValues: reference
                .filter { $0.device.isTrashed }
                .map { ($0.device.id, $0.device.daysLeftInTrash(now: now)) }
        )

        let bundle = ExportBundle(
            exportedAt: now,
            modelConfig: engine.config,
            displayStyle: displayStyle,
            sortMode: sortMode,
            devices: pairs.map { pair in
                ExportDevice(
                    device: pair.device,
                    prediction: ExportPrediction(
                        medianHours: pair.prediction.medianHours,
                        p10Hours: pair.prediction.p10Hours,
                        p50ExhaustAt: pair.prediction.p50ExhaustAt,
                        p10ExhaustAt: pair.prediction.p10ExhaustAt,
                        remainingHours: pair.prediction.remainingHours,
                        p10RemainingHours: pair.prediction.p10RemainingHours,
                        ageHours: pair.prediction.ageHours,
                        ratio: pair.prediction.ratio,
                        sigmaPrediction: pair.prediction.sigmaPrediction,
                        urgency: pair.prediction.urgency,
                        confidence: pair.prediction.confidence,
                        posterior: pair.prediction.posterior
                    ),
                    status: Self.exportStatus(for: pair.prediction,
                                              device: pair.device),
                    daysLeftInTrash: trashedDays[pair.device.id]
                )
            }
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(bundle)

        let stamp = Self.fileStamp.string(from: now)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CheckJuice-\(stamp).json")
        try data.write(to: url, options: .atomic)
        return url
    }

    /// 把颜色标签展开成「能读懂为什么」的形式。
    private static func exportStatus(for prediction: Prediction,
                                     device: Device) -> ExportStatus {
        let level = DisplayLevel.make(prediction: prediction,
                                      notifyLeadHours: device.notifyLeadHours)
        let p10 = prediction.p10RemainingHours
        let lead = device.notifyLeadHours
        let median = prediction.remainingHours

        let color: String
        let reason: String
        switch level {
        case .exhausted:
            color = "red"
            reason = "已过中位耗尽时刻（中位剩余 \(Self.fmt(median)) 小时 < 0）"
        case .soon:
            color = "yellow"
            if p10 <= 0 {
                reason = "已进入风险窗口（P10 剩余 \(Self.fmt(p10)) 小时 ≤ 0，"
                    + "此时不看提前提醒量，一律算该处理）"
            } else {
                reason = "P10 剩余 \(Self.fmt(p10)) 小时 ≤ 提前提醒量 \(Self.fmt(lead)) 小时"
            }
        case .normal:
            color = "default"
            reason = "P10 剩余 \(Self.fmt(p10)) 小时 > 提前提醒量 \(Self.fmt(lead)) 小时"
        }

        return ExportStatus(
            level: level,
            displayName: level.displayName,
            color: color,
            reason: reason,
            p10RemainingHours: p10,
            notifyLeadHours: lead
        )
    }

    /// 保留 1 位小数就够读数了 —— 导出文件是给人看的，不是给机器算的。
    private static func fmt(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    /// 文件名里不能有冒号（iOS 文件系统会把它显示成别的东西）。
    private static let fileStamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmm"
        return f
    }()

    // MARK: - 落盘

    private func commit() {
        persist()
        reloadWidget()
    }

    /// 只落盘，不碰小组件。
    ///
    /// 拆出来是给**启动时清回收站**用的：那一步发生在 `init` 里，
    /// 紧接着 `reloadWidget()` 就会被调一次 —— 再调一遍纯属白算。
    private func persist() {
        if !AppGroup.isAvailable {
            // 不吞掉：这是「界面一切正常、重启全没了」的唯一线索。
            storageError = AppGroup.unavailableMessage + "（设置页 → 诊断 看详情）"
        } else {
            do {
                try deviceStore.save(devices)
                storageError = nil
            } catch {
                storageError = "写入失败：" + error.localizedDescription
            }
        }
    }

    /// 重算并刷新小组件。不调这个，小组件会一直显示上次的快照。
    ///
    /// 时间基准只取一次 `Date()` 并全程复用：同一屏里所有设备的 `remainingHours`
    /// 必须基于同一个「现在」，否则彼此的基准时刻能差几毫秒。
    /// 现在无关紧要，但排序、聚合、跨设备对比一旦上线就会露馅。
    func reloadWidget() {
        let now = Date()
        let style = displayStyle
        // 快照也只看未删除的：否则回收站里的东西还会在桌面上晃，
        // 用户刚「删掉」的物品出现在小组件里，是纯纯的 bug 观感。
        let snapshots = engine.predictions(for: activeDevices, now: now)
            .map { DeviceSnapshot(device: $0.device, prediction: $0.prediction, style: style) }
        try? snapshotStore.save(WidgetSnapshot(generatedAt: now,
                                               devices: snapshots,
                                               groupId: AppGroup.resolvedIdentifier))
        // 主 App 也留一张纸条，诊断页才能拿两边的解析结果直接对比。
        WidgetEnv.writeHere(process: "app")
        WidgetCenter.shared.reloadAllTimelines()
    }
}
