import XCTest
import Foundation
@testable import CheckJuiceCore

/// 剩余时长文案的档位测试。
///
/// **起因是一次真机反馈**：1 小时的电池还剩 22 分钟，首页显示「还剩 0 小时」。
/// 用户分不出「马上没电」和「真的没了」，而这两件事该做的事完全不同。
///
/// 顺带查出同一个 bug 的另一面：`wholeHours(-0.892)` 朝零截断等于 0，
/// 于是「已耗尽 53 分钟」也显示成「还剩 0 小时」—— 已经没电了却说还剩着。
///
/// 根因是**先截断再判符号**。符号必须用原始值判断。
final class RemainingTextTests: XCTestCase {

    private func text(_ hours: Double) -> String {
        Prediction.adaptiveHours(hours)
    }

    // MARK: - 亚小时（这次新加的档）

    func testSubHourShowsMinutesNotZero() {
        // 真机反馈的那个具体值：22 分钟。
        XCTAssertEqual(text(0.3757), "还剩 22 分钟")
        XCTAssertEqual(text(0.5), "还剩 30 分钟")
        XCTAssertEqual(text(0.99), "还剩 59 分钟")
    }

    /// 关键回归：**不能再出现「还剩 0 小时」**。
    func testNeverSaysZeroHoursForPositiveRemaining() {
        for hours in stride(from: 0.02, to: 1.0, by: 0.02) {
            let s = text(hours)
            XCTAssertNotEqual(s, "还剩 0 小时", "剩余 \(hours) 小时不该说 0 小时")
        }
    }

    // MARK: - 已耗尽（旧 bug 的另一面）

    func testExhaustedUnderOneHourIsNotShownAsRemaining() {
        // 旧实现：wholeHours(-0.892) == 0 → 走正数分支 → 「还剩 0 小时」。荒谬。
        XCTAssertEqual(text(-0.892), "耗尽中 53 分钟")
        XCTAssertEqual(text(-0.5), "耗尽中 30 分钟")
        XCTAssertFalse(text(-0.892).contains("还剩"),
                       "已耗尽不能说「还剩」")
    }

    func testJustExhausted() {
        XCTAssertEqual(text(-0.008), "刚刚耗尽")
        XCTAssertEqual(text(0.008), "不足 1 分钟")
    }

    // MARK: - 既有档位不许变（黄金数值依赖这些）

    func testExistingTiersUnchanged() {
        XCTAssertEqual(text(3571.94), "约 4 个月")
        XCTAssertEqual(text(863.28), "约 35 天")
        XCTAssertEqual(text(76.92), "约 3 天")
        XCTAssertEqual(text(1.4509), "还剩 1 小时")
        XCTAssertEqual(text(48.0), "约 2 天")
        XCTAssertEqual(text(1440.0), "约 2 个月")
        XCTAssertEqual(text(-3313.68), "耗尽中 4 个月")
        XCTAssertEqual(text(-193.68), "耗尽中 8 天")
    }

    /// 档位边界不许重叠、不许掉档。
    func testTierBoundariesContinuous() {
        XCTAssertEqual(text(1.0), "还剩 1 小时")
        XCTAssertEqual(text(0.999), "还剩 59 分钟")
        XCTAssertEqual(text(48.0), "约 2 天")
        XCTAssertEqual(text(47.99), "还剩 47 小时")
        XCTAssertEqual(text(1440.0), "约 2 个月")
        XCTAssertEqual(text(1439.0), "约 59 天")
    }

    // MARK: - 非有限值

    func testNonFiniteInput() {
        XCTAssertEqual(text(.infinity), "—")
        XCTAssertEqual(text(-.infinity), "—")
        XCTAssertEqual(text(.nan), "—")
    }
}

/// `DurationText.short` 的档位测试。
///
/// 它和 `Prediction.adaptiveHours` 踩过同一个坑：先截断再判符号，
/// 于是不足 1 小时显示成「0 小时」、已超出显示成「0 小时」。
final class DurationTextTests: XCTestCase {

    private func t(_ hours: Double) -> String { DurationText.short(hours) }

    func testSubHourShowsMinutes() {
        XCTAssertEqual(t(0.3757), "22 分钟")
        XCTAssertEqual(t(0.5), "30 分钟")
    }

    func testNeverSaysZeroHoursForNonZeroInput() {
        for hours in stride(from: 0.02, to: 1.0, by: 0.02) {
            XCTAssertNotEqual(t(hours), "0 小时", "\(hours) 小时不该说成 0 小时")
        }
    }

    func testExceededUnderOneHour() {
        XCTAssertEqual(t(-0.9), "超出 54 分钟")
        XCTAssertTrue(t(-0.9).hasPrefix("超出"))
    }

    func testExistingTiersUnchanged() {
        XCTAssertEqual(t(2.0), "2 小时")
        XCTAssertEqual(t(47.99), "47 小时")
        XCTAssertEqual(t(48.0), "2 天")
        XCTAssertEqual(t(76.92), "3 天")
        XCTAssertEqual(t(1440.0), "2 个月")
        XCTAssertEqual(t(3576.0), "4 个月")
    }

    func testNonFinite() {
        XCTAssertEqual(t(.infinity), "—")
        XCTAssertEqual(t(.nan), "—")
    }
}
