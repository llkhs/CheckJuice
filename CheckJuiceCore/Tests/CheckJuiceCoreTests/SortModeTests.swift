import XCTest
import Foundation
@testable import CheckJuiceCore

/// 排序测试。
///
/// **存在的理由是一次真实的字段撒谎**：导出文件里写着 `sortMode: "name"`，
/// 而 `devices` 数组实际按紧急度排 —— 因为导出直接用了
/// `LifetimeModel.predictions(for:)`（那个写死按紧急度排序），
/// 而真正的排序逻辑住在 App 层，`swift test` 够不着，没人发现两套不一致。
///
/// 所以排序搬到 Core，并且在这里把四种方式的**顺序**钉死。
final class SortModeTests: XCTestCase {
    private let installed = Date(timeIntervalSince1970: 1_700_000_000)

    private func device(_ name: String,
                        createdOffsetHours: Double,
                        nominal: Double = 720) -> Device {
        Device(
            name: name,
            nominalLifeHours: nominal,
            events: [ReplacementEvent(
                at: installed.addingTimeInterval(createdOffsetHours * 3600),
                kind: .initial
            )]
        )
    }

    /// 造一台「还剩多少」可控的设备：用标称寿命差拉开 P10 剩余。
    private func pair(_ name: String, nominal: Double, createdAt: Double) -> DevicePrediction {
        let d = device(name, createdOffsetHours: createdAt, nominal: nominal)
        let now = installed.addingTimeInterval(1000 * 3600)
        // 用真实预测，别手搓数字 —— 手搓的话测的就不是真实排序输入了。
        let prediction = LifetimeModel().predict(d, now: now)!
        return (device: d, prediction: prediction)
    }

    func testNameSort() {
        let items = [
            pair("温湿度计", nominal: 720, createdAt: 0),
            pair("门锁", nominal: 720, createdAt: 0),
            pair("电子秤", nominal: 720, createdAt: 0),
        ]
        let names = SortMode.name.sorted(items).map { $0.device.name }
        // 只断言「结果稳定且三种都出现」——中文的具体排序依 Foundation 版本而定，
        // 写死顺序会让测试在别的平台上无缘无故红。
        XCTAssertEqual(Set(names), ["温湿度计", "门锁", "电子秤"])
        XCTAssertEqual(names.count, 3)
    }

    func testNameSortUsesNumericAwareness() {
        // `localizedStandardCompare` 会把 "2" 排在 "10" 前面（人读的顺序）。
        // 用普通 `<` 的字典序则会得到 "10" < "2"。这条钉住用的是前者。
        let items = [
            pair("10", nominal: 720, createdAt: 0),
            pair("2", nominal: 720, createdAt: 0),
        ]
        XCTAssertEqual(SortMode.name.sorted(items).map { $0.device.name }, ["2", "10"])
    }

    func testRemainingSortIsAscendingByP10() {
        let items = [
            pair("长", nominal: 8760, createdAt: 0),
            pair("短", nominal: 2, createdAt: 0),
            pair("中", nominal: 100, createdAt: 0),
        ]
        let sorted = SortMode.remaining.sorted(items)
        XCTAssertEqual(sorted.map { $0.device.name }, ["短", "中", "长"])
        // 单调性：按 P10 剩余严格不减。
        for (a, b) in zip(sorted, sorted.dropFirst()) {
            XCTAssertLessThanOrEqual(a.prediction.p10RemainingHours,
                                     b.prediction.p10RemainingHours)
        }
    }

    func testRecentSortIsDescendingByCreation() {
        let items = [
            pair("老", nominal: 720, createdAt: 0),
            pair("新", nominal: 720, createdAt: 500),
            pair("中", nominal: 720, createdAt: 200),
        ]
        XCTAssertEqual(SortMode.recent.sorted(items).map { $0.device.name }, ["新", "中", "老"])
    }

    /// 紧急度排序：已耗尽的排最前。
    func testUrgencySortPutsExhaustedFirst() {
        let fresh = pair("新电池", nominal: 8760, createdAt: 0)
        // 一台已经远超中位寿命的：给它一个很短的标称寿命，且创建很早。
        let dead = pair("该换了", nominal: 1, createdAt: 0)
        let sorted = SortMode.urgency.sorted([fresh, dead])
        XCTAssertEqual(sorted.first?.device.name, "该换了")
        XCTAssertEqual(sorted.last?.device.name, "新电池")
    }

    /// 四种模式都必须**不丢设备、不重复**。
    /// 排序写错最容易犯的就是这个（`sorted` 写好了没事，一旦手写索引就会漏）。
    func testAllModesPreserveEveryDevice() {
        let items = [
            pair("a", nominal: 2, createdAt: 0),
            pair("b", nominal: 100, createdAt: 100),
            pair("c", nominal: 8760, createdAt: 50),
        ]
        for mode in SortMode.allCases {
            let sorted = mode.sorted(items)
            XCTAssertEqual(sorted.count, items.count, "\(mode) 丢了设备")
            XCTAssertEqual(Set(sorted.map { $0.device.id }), Set(items.map { $0.device.id }),
                           "\(mode) 改变了设备集合")
        }
    }
}
