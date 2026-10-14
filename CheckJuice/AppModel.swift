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

    var devices: [Device] = []

    /// 用户在设置页选的主文案样式（「耗尽时刻」/「剩余时长」）。
    ///
    /// 持久化交给 `DisplaySettings`（App Group 共享域）—— 见那边的注释：
    /// M2b 的交互式小组件要在扩展进程里按同样样式渲染，所以设置必须共享。
    var displayStyle: ExhaustDisplayStyle = DisplaySettings.style

    /// 列表主文案下面那行「中位」小字是否显示。
    var showMedianSubline: Bool = DisplaySettings.showMedian

    init() {
        devices = deviceStore.load()
        reloadWidget()
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

    /// 全部设备按紧急度排序 —— 最该处理的排最前。
    var ranked: [RankedDevice] {
        engine.predictions(for: devices, now: Date())
            .map { RankedDevice(device: $0.device, prediction: $0.prediction) }
            .sorted { lhs, rhs in
                let a = Self.rank(lhs.prediction.urgency)
                let b = Self.rank(rhs.prediction.urgency)
                if a != b { return a < b }
                return lhs.prediction.remainingHours < rhs.prediction.remainingHours
            }
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

    /// 记一次更换。默认是「自然耗尽」（有效寿命样本）；
    /// 提前更换 / 故障请显式传 `kind`，否则会污染寿命统计。
    func markReplaced(_ device: Device, kind: EventKind = .exhausted) {
        guard let index = devices.firstIndex(where: { $0.id == device.id }) else { return }
        devices[index].events.append(ReplacementEvent(at: Date(), kind: kind))
        commit()
    }

    func delete(_ device: Device) {
        devices.removeAll { $0.id == device.id }
        commit()
    }

    // MARK: - 落盘

    private func commit() {
        try? deviceStore.save(devices)
        reloadWidget()
    }

    /// 重算并刷新小组件。不调这个，小组件会一直显示上次的快照。
    ///
    /// 时间基准只取一次 `Date()` 并全程复用：同一屏里所有设备的 `remainingHours`
    /// 必须基于同一个「现在」，否则彼此的基准时刻能差几毫秒。
    /// 现在无关紧要，但排序、聚合、跨设备对比一旦上线就会露馅。
    func reloadWidget() {
        let now = Date()
        let style = displayStyle
        let snapshots = engine.predictions(for: devices, now: now)
            .map { DeviceSnapshot(device: $0.device, prediction: $0.prediction, style: style) }
        try? snapshotStore.save(WidgetSnapshot(generatedAt: now, devices: snapshots))
        WidgetCenter.shared.reloadAllTimelines()
    }
}
