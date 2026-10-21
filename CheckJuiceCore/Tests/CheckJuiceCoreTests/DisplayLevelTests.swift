import XCTest
import Foundation
@testable import CheckJuiceCore

/// 显示分级（颜色）测试。
///
/// 这一层是**纯上屏规则**，不参与任何预测计算 —— 但它有一个必须钉死的前提：
/// `notifyLeadHours` 只决定颜色，**不能影响显示出来的那个时间**。
/// 用户明确要求过这一点，所以除了测分级本身，还要测「改提前量，预测数字一个字都不变」。
final class DisplayLevelTests: XCTestCase {
    private let model = LifetimeModel()

    // MARK: - 分级规则（纯函数）

    func testExhaustedWhenPastMedian() {
        // 中位已过（负数）→ 红。哪怕 P10 也很负，仍然是红而不是黄。
        let level = DisplayLevel.make(
            remainingHours: -5, p10RemainingHours: -40, notifyLeadHours: 4
        )
        XCTAssertEqual(level, .exhausted)
    }

    func testSoonInsideRiskWindowEvenWithZeroLead() {
        // 用户把提前量设成 0（不要提前提醒）。此时 P10 已为负 = 已经进风险窗口，
        // 仍然必须是「该处理」—— 否则一台随时可能没电的设备会显示成正常色。
        let level = DisplayLevel.make(
            remainingHours: 100, p10RemainingHours: -3, notifyLeadHours: 0
        )
        XCTAssertEqual(level, .soon)
    }

    func testSoonWhenWithinLead() {
        // P10 剩余正好等于提前量 → 黄（"等于或小于"）。
        XCTAssertEqual(
            DisplayLevel.make(remainingHours: 100, p10RemainingHours: 4, notifyLeadHours: 4),
            .soon
        )
        XCTAssertEqual(
            DisplayLevel.make(remainingHours: 100, p10RemainingHours: 3.9, notifyLeadHours: 4),
            .soon
        )
    }

    func testNormalBeyondLead() {
        XCTAssertEqual(
            DisplayLevel.make(remainingHours: 100, p10RemainingHours: 4.1, notifyLeadHours: 4),
            .normal
        )
        // 没有提前量、也还没进风险窗口 → 正常。
        XCTAssertEqual(
            DisplayLevel.make(remainingHours: 100, p10RemainingHours: 50, notifyLeadHours: 0),
            .normal
        )
    }

    /// 判据必须吃 **P10 剩余**，不能吃中位剩余。
    ///
    /// 拿中位比会把黄色压到几乎永不触发：风险窗口（P10）远早于中位日，
    /// 中位剩余还很长时 P10 早就为负了。这条守的是 DESIGN 3.6 里推翻过的那个错。
    func testUsesP10NotMedian() {
        let level = DisplayLevel.make(
            remainingHours: 500, p10RemainingHours: 2, notifyLeadHours: 4
        )
        XCTAssertEqual(level, .soon, "中位还剩 500 小时，但 P10 只剩 2 小时 → 该处理")
    }

    // MARK: - 提前量不得影响显示的时间

    /// 用户明确要求：`notifyLeadHours` 只用于颜色，不参与「还剩多久」的计算。
    ///
    /// 这个测试是那句话的可执行版本 —— 以后谁把 `notifyLeadHours` 塞进
    /// `remainingHours` / `p10RemainingHours` / 中位或 P10 寿命的算式里，这里立刻红。
    func testNotifyLeadDoesNotChangePrediction() throws {
        let installed = Date(timeIntervalSince1970: 1_700_000_000)
        let now = installed.addingTimeInterval(100 * 3600)

        func make(lead: Double) -> Device {
            Device(
                name: "测试",
                nominalLifeHours: 720,
                events: [
                    ReplacementEvent(at: installed, kind: .initial),
                    ReplacementEvent(at: installed.addingTimeInterval(200 * 3600), kind: .exhausted),
                ],
                notifyLeadHours: lead
            )
        }

        let tight = try XCTUnwrap(model.predictions(for: [make(lead: 4)], now: now).first?.prediction)
        let loose = try XCTUnwrap(model.predictions(for: [make(lead: 720)], now: now).first?.prediction)

        XCTAssertEqual(tight.medianHours, loose.medianHours, accuracy: 1e-9)
        XCTAssertEqual(tight.p10Hours, loose.p10Hours, accuracy: 1e-9)
        XCTAssertEqual(tight.remainingHours, loose.remainingHours, accuracy: 1e-9)
        XCTAssertEqual(tight.p10RemainingHours, loose.p10RemainingHours, accuracy: 1e-9)
        XCTAssertEqual(tight.p50ExhaustAt, loose.p50ExhaustAt)
        XCTAssertEqual(tight.p10ExhaustAt, loose.p10ExhaustAt)

        // 显示的数字一致，但颜色分级可以不同 —— 这正是它的用途。
        XCTAssertNotEqual(
            DisplayLevel.make(prediction: tight, notifyLeadHours: 4),
            DisplayLevel.make(prediction: loose, notifyLeadHours: 720),
            "同样的预测，提前量不同，颜色分级应当不同"
        )
    }
}
