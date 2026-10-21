import XCTest
import Foundation
@testable import CheckJuiceCore
import CheckJuiceStore

/// 存储层测试。
///
/// **存在的理由是一次真机事故（2026-10-14）**：CI 出的未签名 IPA 自签装上后，
/// App 里加物品一切正常，小组件却一直显示「还没有物品」。根因是自签用的描述文件里
/// 没有 App Group → 容器拿不到 → 而当时的实现是 `guard let fileURL else { return }`，
/// **静默地假装存成功**。界面不报错、数据重启就没、小组件永远空着 —— 全程零线索。
///
/// 所以这里钉三件事：
///
/// 1. 拿不到容器**必须抛错**，不许当无事发生。
/// 2. 设备清单的编解码往返一致（字段名拼错 = 用户以为数据丢了）。
/// 3. **App 与小组件之间的契约**：主 App 写进共享域的那份 JSON，
///    Widget 必须能原样读出来。这份格式没人守着的话，改一个字段名
///    就会让小组件静默变成「还没有物品」，而 App 那边毫无异常。
final class StoreTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CheckJuiceStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// 测试数据的时刻必须**落在整分钟**上。
    ///
    /// 读路径会把时刻对齐到分钟（见 `Device.normalizedToMinute`），
    /// 所以拿带秒的数据做往返测试必然不等 —— 那不是 bug，是数据不合契约。
    /// `1_700_000_000` 是 22:13:20，用它曾把 `testDeviceRoundTrip` 测红过一次。
    private func sampleDevice() -> Device {
        let installed = LifetimeModel.floorToMinute(Date(timeIntervalSince1970: 1_700_000_000))
        return Device(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            name: "电子秤",
            nominalLifeHours: 8760,
            events: [
                ReplacementEvent(at: installed, kind: .initial),
                ReplacementEvent(
                    at: installed.addingTimeInterval(3600 * 100),
                    kind: .exhausted
                ),
            ],
            notifyLeadHours: 336
        )
    }

    // MARK: - 静默失败（这次事故的正主）

    func testSaveThrowsWhenContainerIsUnavailable() {
        let device = sampleDevice()
        XCTAssertThrowsError(try DeviceStore(fileURL: nil).save([device])) { error in
            XCTAssertEqual(error as? StoreError, .appGroupUnavailable)
        }
        XCTAssertThrowsError(try SnapshotStore(fileURL: nil).save(.empty)) { error in
            XCTAssertEqual(error as? StoreError, .appGroupUnavailable)
        }
    }

    func testLoadReturnsEmptyInsteadOfCrashing() {
        // 文件不存在：返回空，不崩也不抛 —— 读路径要宽容。
        XCTAssertTrue(DeviceStore(fileURL: dir.appendingPathComponent("nope.json")).load().isEmpty)
        XCTAssertTrue(
            SnapshotStore(fileURL: dir.appendingPathComponent("nope.json")).load().devices.isEmpty
        )
        // 容器拿不到：同理，空着总比崩了强（但要靠上面的 save 抛错来报警）。
        XCTAssertTrue(DeviceStore(fileURL: nil).load().isEmpty)
    }

    // MARK: - 编解码往返

    func testDeviceRoundTrip() throws {
        let url = dir.appendingPathComponent("devices.json")
        let device = sampleDevice()
        try DeviceStore(fileURL: url).save([device])
        XCTAssertEqual(DeviceStore(fileURL: url).load(), [device])
    }

    /// 迁移契约：带秒的旧数据读出来必须是对齐到分钟的。
    ///
    /// 这条测试表达的是**新版的行为** —— 读路径不是透明的，
    /// 它会顺手把时刻收拾干净。写在这里是为了别让人以为 round-trip 丢了精度。
    func testLoadNormalizesLegacySecondsToMinute() throws {
        let url = dir.appendingPathComponent("legacy.json")
        // 1_700_000_000 = 22:13:20，带 20 秒的「旧数据」。
        let messy = Date(timeIntervalSince1970: 1_700_000_000)
        let device = Device(
            name: "电子秤",
            nominalLifeHours: 8760,
            events: [ReplacementEvent(at: messy, kind: .initial)],
            notifyLeadHours: 336
        )
        try DeviceStore(fileURL: url).save([device])

        let loaded = try XCTUnwrap(DeviceStore(fileURL: url).load().first)
        XCTAssertEqual(loaded.events[0].at,
                       LifetimeModel.floorToMinute(messy),
                       "旧数据的秒必须被抹掉")
        XCTAssertEqual(loaded.events[0].at.timeIntervalSince1970
                        .truncatingRemainder(dividingBy: 60), 0,
                       "结果必须落在整分钟上")
    }

    /// App → 小组件的契约。改了 `DeviceSnapshot` 的字段名却忘了改小组件，
    /// 表现就是小组件静默变空 —— 这个测试是唯一会喊出声的地方。
    func testSnapshotRoundTripMatchesWidgetContract() throws {
        let url = dir.appendingPathComponent("widget_snapshot.json")
        let generatedAt = Date(timeIntervalSince1970: 1_700_400_000)
        let snapshot = WidgetSnapshot(
            generatedAt: generatedAt,
            devices: [
                DeviceSnapshot(
                    id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                    name: "电子秤",
                    urgency: .stockUp,
                    level: .soon,
                    remainingHours: 41.6,
                    p10RemainingHours: 30.5,
                    p50ExhaustAt: Date(timeIntervalSince1970: 1_700_600_000),
                    confidence: .medium,
                    headline: "将在 11月1日 周六 08:00 耗尽"
                )
            ]
        )

        try SnapshotStore(fileURL: url).save(snapshot)
        let back = SnapshotStore(fileURL: url).load()

        XCTAssertEqual(back.devices.count, 1)
        let device = try XCTUnwrap(back.devices.first)
        XCTAssertEqual(device.name, "电子秤")
        XCTAssertEqual(device.urgency, .stockUp)
        XCTAssertEqual(device.level, .soon, "分级是 App 与 Widget 的配色契约")
        XCTAssertEqual(device.confidence, .medium)
        XCTAssertEqual(device.headline, "将在 11月1日 周六 08:00 耗尽")
        XCTAssertEqual(device.remainingHours, 41.6, accuracy: 1e-9)
        XCTAssertEqual(device.p10RemainingHours, 30.5, accuracy: 1e-9)
        XCTAssertEqual(device.p50ExhaustAt, snapshot.devices[0].p50ExhaustAt)
        // 整秒时间戳，ISO8601 不该有精度损失。
        XCTAssertEqual(back.generatedAt, generatedAt)
    }
}
