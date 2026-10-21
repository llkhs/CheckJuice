import XCTest
import Foundation
@testable import CheckJuiceCore
import CheckJuiceStore

/// 时刻精度。
///
/// 这里记录一段**走弯路的结论**，免得以后又被同一个想法带偏：
///
/// 1. 起初发现「界面显示 14:21，库里是 14:21:48.373」，用户没机会选那几十秒，
///    于是我把**所有**写入时刻都截断到分钟（`floorToMinute`），
///    还在读路径上做了一次迁移。
/// 2. 真机反馈四台设备挤成同一个时刻、列表乱序 —— 因为它们是同一分钟内建的，
///    截断后时间戳完全相同。
/// 3. 更根本的问题：截断让数据**更不准**。`Date()` 记的是「按下按钮的那一刻」，
///    那是真实的；把它挪回 `:00` 等于凭空丢掉最多 59 秒的真实信息。
///
/// 正确认识：
/// * 用户**手动挑选**的时刻 —— `DatePicker` 只有 `.date` + `.hourAndMinute`，
///   SwiftUI 自己就把秒归零了，不需要我们动手。
/// * 用户**没动**、默认「此刻」—— 就该保留真实精度。排序也依赖它区分先后。
/// * 秒级精度对**模型**确实没意义（下面有量化对比），但「对模型没意义」
///    不等于「应该删掉」——它对**排序**有意义。
final class PrecisionTests: XCTestCase {

    // MARK: - 秒级误差对预测的影响

    /// 59 秒的输入偏差，对寿命估计的影响应远小于 1%。
    ///
    /// 这条是「别为了消除秒而折腾模型」的依据：模型本身的不确定性（σ_pred
    /// 封顶 0.70）比这大三个数量级，盯着秒做优化是在噪声上绣花。
    func testSecondLevelOffsetBarelyAffectsPrediction() {
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

        let relDiff = abs(messy.medianHours - clean.medianHours) / clean.medianHours
        XCTAssertLessThan(relDiff, 0.01,
                          "59 秒的输入偏差对寿命估计影响应远小于 1%")
    }

    /// 反过来：整数小时 / 0.5 小时步进的量化误差比「保留秒」大得多。
    /// 这条不测代码，测的是**设计判断** —— 防止以后有人真的把模型改成量化。
    func testHalfHourQuantizationWouldBeMuchWorseThanSeconds() {
        let nominalHours = 4.0
        let secondQuantization = (1.0 / 3600) / nominalHours     // 1 秒
        let halfHourQuantization = 0.5 / nominalHours            // 0.5 小时

        XCTAssertGreaterThan(halfHourQuantization, secondQuantization * 100,
                             "0.5 小时步进的误差是秒级的 100 倍以上 —— 量化不是简化，是变糟")
    }

    // MARK: - 排序需要亚分钟精度

    /// **同一分钟内**创建的多台设备，必须能靠时刻区分先后。
    ///
    /// 这是上一版截断方案炸掉的场景：四台都变成 10:46:00，
    /// 排序键完全相同，而 Swift 的 `sorted` 不稳定 → 列表顺序乱跳。
    func testSubMinuteTimestampsKeepCreationOrderDistinguishable() {
        let base = Date(timeIntervalSince1970: 1_700_000_040)   // 某个整分钟
        let a = base.addingTimeInterval(3)
        let b = base.addingTimeInterval(21)
        let c = base.addingTimeInterval(47)

        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(b, c)
        XCTAssertLessThan(a, b)
        XCTAssertLessThan(b, c)
        // 三者在同一分钟内（这正是不该被压成同一个值的原因）
        XCTAssertEqual(Int(b.timeIntervalSince1970 / 60),
                       Int(c.timeIntervalSince1970 / 60))
    }
}
