import XCTest
import Foundation
@testable import CheckJuiceCore

/// 回收站测试。
///
/// **为什么单独一个文件**：软删除引进了一个新概念 ——「躺在回收站里、还没被清掉」，
/// 它是一种**既非存在也非不存在**的状态。这种东西最容易在边界上出错：
/// 第 15 天算不算到期、剩 0.1 天该显示「1 天」还是「0 天」。
/// 而这些边界只有 `swift test` 能钉 —— 在界面上点一个月是点不出来的。
final class TrashTests: XCTestCase {

    private func device(deletedAt: Date?) -> Device {
        Device(
            name: "温湿度计",
            nominalLifeHours: 72,
            events: [ReplacementEvent(at: Date(timeIntervalSince1970: 1_700_000_000), kind: .initial)],
            deletedAt: deletedAt
        )
    }

    // MARK: - 软删除状态

    func testIsTrashedTracksDeletedAt() {
        XCTAssertFalse(device(deletedAt: nil).isTrashed)
        XCTAssertTrue(device(deletedAt: Date()).isTrashed)
    }

    // MARK: - 老数据兼容（我在注释里承诺过的事）

    /// ⚠️ 这条测试守着一个**口头承诺**：`deletedAt` 是可选字段，
    /// 所以合成 `Codable` 会走 `decodeIfPresent`，老的 JSON 少这个键也能解出来。
    ///
    /// 这个承诺一旦不成立，症状是**用户升级后全部物品消失**（解码整体失败 →
    /// `load()` 返回空 → 主页干干净净）。而 `load()` 是「损坏就返回空」的宽容设计，
    /// 连报错都不会有。所以必须在这儿钉死。
    func testOldJSONWithoutDeletedAtStillDecodes() throws {
        let legacy = """
        [
          {
            "id": "11111111-1111-1111-1111-111111111111",
            "name": "电子秤",
            "nominalLifeHours": 8760,
            "notifyLeadHours": 336,
            "events": [
              { "at": "2023-11-14T22:13:20Z", "kind": "initial", "note": "" }
            ]
          }
        ]
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let devices = try decoder.decode([Device].self, from: Data(legacy.utf8))

        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0].name, "电子秤")
        XCTAssertNil(devices[0].deletedAt, "老数据没有这个键，应当解成 nil 而不是抛错")
        XCTAssertFalse(devices[0].isTrashed)
    }

    func testDeletedAtSurvivesRoundTrip() throws {
        let deletedAt = Date(timeIntervalSince1970: 1_700_500_000)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let back = try decoder.decode(
            Device.self,
            from: encoder.encode(device(deletedAt: deletedAt))
        )
        XCTAssertEqual(back.deletedAt, deletedAt)
        XCTAssertTrue(back.isTrashed)
    }

    // MARK: - 到期边界

    func testTrashExpiryBoundary() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let day = 24.0 * 3600

        // 差 1 秒到期：还在回收站里。
        XCTAssertFalse(device(deletedAt: now.addingTimeInterval(-(15 * day) + 1)).isTrashExpired(now: now))
        // 正好满 15 天：到期（和 `purgeExpiredTrash` 用的 `>=` 保持一致）。
        XCTAssertTrue(device(deletedAt: now.addingTimeInterval(-15 * day)).isTrashExpired(now: now))
        // 躺了 20 天：早该清了。
        XCTAssertTrue(device(deletedAt: now.addingTimeInterval(-20 * day)).isTrashExpired(now: now))
        // 从没删过的东西永远不会过期 —— 这个判断要是反了，整个库会被清空。
        XCTAssertFalse(device(deletedAt: nil).isTrashExpired(now: now))
    }

    func testDaysLeftRoundsUp() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let day = 24.0 * 3600

        XCTAssertEqual(device(deletedAt: now).daysLeftInTrash(now: now), 15, "刚删 = 还剩 15 天")
        // 躺了 14 天 23 小时：向上取整 → 1 天。显示「0 天」会让人以为已经没了。
        XCTAssertEqual(device(deletedAt: now.addingTimeInterval(-14 * day - 23 * 3600)).daysLeftInTrash(now: now), 1)
        // 躺满 15 天：归零。
        XCTAssertEqual(device(deletedAt: now.addingTimeInterval(-15 * day)).daysLeftInTrash(now: now), 0)
        XCTAssertEqual(device(deletedAt: nil).daysLeftInTrash(now: now), 0)
    }
}
