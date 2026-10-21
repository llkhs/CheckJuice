import XCTest
import Foundation
@testable import CheckJuiceCore
import CheckJuiceStore

/// 时刻精度测试。
///
/// **起因是一次真机数据反查**：5 台测试设备里，用时间选择器填的那台能和
/// Python 参考实现逐位对上，其余 4 台（默认「此刻」）差 1e-4 小时。
/// 根因是 UI 只显示到分钟，而存进去的值带小数秒 ——
/// **用户看到 14:21，库里是 14:21:48.373**，他根本没机会选那几十秒。
///
/// 所以：界面能表达的精度，就是数据该有的精度。
final class PrecisionTests: XCTestCase {

    // MARK: - 对齐本身

    func testFloorToMinuteDropsSeconds() {
        // 用整分钟做基准，避免时区/夏令时的干扰。
        let exact = Date(timeIntervalSince1970: 1_700_000_040)   // 整分钟
        XCTAssertEqual(LifetimeModel.floorToMinute(exact), exact)

        let withSeconds = exact.addingTimeInterval(48.373)
        XCTAssertEqual(LifetimeModel.floorToMinute(withSeconds), exact,
                       "14:xx:48.373 应对齐到 14:xx:00")
    }

    func testFloorToMinuteIsIdempotent() {
        let messy = Date(timeIntervalSince1970: 1_700_000_099.999)
        let once = LifetimeModel.floorToMinute(messy)
        let twice = LifetimeModel.floorToMinute(once)
        XCTAssertEqual(once, twice, "幂等 —— 读路径每次都跑也不会漂")
    }

    /// 向下取整而不是四舍五入：59 秒应回到本分钟的开头，不是下一秒。
    func testFloorToMinuteRoundsDownNotNearest() {
        let exact = Date(timeIntervalSince1970: 1_700_000_040)
        let almostNext = exact.addingTimeInterval(59)
        XCTAssertEqual(LifetimeModel.floorToMinute(almostNext), exact)
    }

    // MARK: - 迁移

    func testNormalizeAlignsEveryEvent() {
        let base = Date(timeIntervalSince1970: 1_700_000_040)
        var device = Device(
            name: "测试",
            nominalLifeHours: 4,
            events: [
                ReplacementEvent(at: base.addingTimeInterval(48.373), kind: .initial),
                ReplacementEvent(at: base.addingTimeInterval(3600 + 12.7), kind: .exhausted),
            ]
        )
        // deletedAt 是审计记录，不该被改。
        device.deletedAt = base.addingTimeInterval(7.5)

        let normalized = device.normalizedToMinute
        XCTAssertEqual(normalized.events[0].at, base)
        XCTAssertEqual(normalized.events[1].at, base.addingTimeInterval(3600))
        XCTAssertEqual(normalized.deletedAt, device.deletedAt,
                       "删除时刻不参与预测，保持原样")
        XCTAssertEqual(normalized.id, device.id)
        XCTAssertEqual(normalized.name, device.name)
    }

    func testNormalizePreservesKindAndNote() {
        let base = Date(timeIntervalSince1970: 1_700_000_040)
        let device = Device(name: "x", nominalLifeHours: 4, events: [
            ReplacementEvent(at: base.addingTimeInterval(3.5), kind: .initial, note: "备注"),
            ReplacementEvent(at: base.addingTimeInterval(4000.9), kind: .faulty, note: "漏液"),
        ])
        let n = device.normalizedToMinute
        XCTAssertEqual(n.events.map { $0.kind }, [.initial, .faulty])
        XCTAssertEqual(n.events.map { $0.note }, ["备注", "漏液"])
    }

    /// 已经在分钟上的数据跑一遍必须**完全不变** —— 否则读一次写一次，
    /// 数据会慢慢漂（那是最难查的一类 bug）。
    func testNormalizeDoesNotChangeAlignedData() {
        let base = Date(timeIntervalSince1970: 1_700_000_040)
        let device = Device(name: "x", nominalLifeHours: 4, events: [
            ReplacementEvent(at: base, kind: .initial),
            ReplacementEvent(at: base.addingTimeInterval(7200), kind: .exhausted),
        ])
        XCTAssertEqual(device.normalizedToMinute, device)
    }

    // MARK: - 秒级差异到底影响多大（回答「要不要量化成整数小时」）

    /// 秒级截断对预测的影响**远小于**任何真实不确定性 —— 所以不该为此把
    /// 模型改成整数小时（那会引入 12.5%~25% 的量化误差，见下一条）。
    func testSecondLevelTruncationBarelyAffectsPrediction() {
        let model = LifetimeModel()
        let base = Date(timeIntervalSince1970: 1_700_000_040)
        let now = base.addingTimeInterval(5 * 3600)

        func make(_ offset: Double) -> Device {
            Device(name: "x", nominalLifeHours: 4, events: [
                ReplacementEvent(at: base.addingTimeInterval(offset), kind: .initial),
                ReplacementEvent(at: base.addingTimeInterval(offset + 4 * 3600), kind: .exhausted),
            ])
        }

        let clean = try! XCTUnwrap(model.predict(make(0), now: now))
        let messy = try! XCTUnwrap(model.predict(make(59), now: now))

        // 中位寿命的相对差应小于 1%（实测约 0.3%）。
        let relDiff = abs(messy.medianHours - clean.medianHours) / clean.medianHours
        XCTAssertLessThan(relDiff, 0.01,
                          "59 秒的输入偏差对寿命估计影响应远小于 1%")
    }

    /// 反过来说：整数小时 / 0.5 小时步进的量化误差比「保留秒」大得多。
    /// 这条不测代码，测的是**设计判断**，防止以后有人真的把模型改成量化。
    func testHalfHourQuantizationWouldBeMuchWorseThanSeconds() {
        let nominalHours = 4.0
        let secondQuantization = (1.0 / 3600) / nominalHours     // 1 秒
        let halfHourQuantization = 0.5 / nominalHours            // 0.5 小时

        XCTAssertGreaterThan(halfHourQuantization, secondQuantization * 100,
                             "0.5 小时步进的误差是秒级的 100 倍以上 —— 量化不是简化，是变糟")
    }
}
