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

    init() {
        devices = deviceStore.load()
        reloadWidget()
    }

    /// 全部设备按紧急度排序 —— 最该处理的排最前。
    var ranked: [RankedDevice] {
        engine.predictions(for: devices, today: Date())
            .map { RankedDevice(device: $0.device, prediction: $0.prediction) }
            .sorted { lhs, rhs in
                let a = Self.rank(lhs.prediction.urgency)
                let b = Self.rank(rhs.prediction.urgency)
                if a != b { return a < b }
                return lhs.prediction.remainingDays < rhs.prediction.remainingDays
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

    func add(name: String, kind: BatteryKind, installedAt: Date, notifyLeadDays: Int) {
        devices.append(
            .newlyAdded(name: name, kind: kind, on: installedAt, notifyLeadDays: notifyLeadDays)
        )
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
    func reloadWidget() {
        let snapshots = engine.predictions(for: devices, today: Date())
            .map { DeviceSnapshot(device: $0.device, prediction: $0.prediction) }
        try? snapshotStore.save(WidgetSnapshot(generatedAt: Date(), devices: snapshots))
        WidgetCenter.shared.reloadAllTimelines()
    }
}
