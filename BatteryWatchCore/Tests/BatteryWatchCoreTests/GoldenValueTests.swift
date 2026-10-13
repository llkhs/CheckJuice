import XCTest
@testable import BatteryWatchCore

/// 与 Python 参考实现的**数值一致性**测试。
///
/// 这些期望值由 `reference/emit_golden.py` 从 `reference/lifetime_model.py` 导出，
/// 不是手写的。任何改动只要让 Swift 与参考实现产生分歧，这里就会挂——
/// 这正是它的用途：**在无法本机编译的环境下，用另一门语言守住数学正确性**。
final class GoldenValueTests: XCTestCase {

    // MARK: - 黄金数值文件结构

    private struct GoldenFile: Decodable {
        var today: String
        var cases: [String: GoldenCase]
    }

    private struct GoldenCase: Decodable {
        var name: String
        var kind: String
        var installedAt: String
        var notifyLeadDays: Int
        var nominalLifeDays: Double?
        var referencePrior: ReferencePrior?
        var events: [GoldenEvent]

        var nObserved: Int
        var nEff: Double
        var m: Double
        var sigmaPost: Double
        var sigmaWithin: Double
        var sigmaPred: Double
        var medianDays: Double
        var p10Days: Double
        var medianDate: String
        var riskDate: String
        var remainingDays: Int
        var riskRemainingDays: Int
        var ageDays: Int
        var ratio: Double
        var urgency: String
        var confidence: String
    }

    private struct GoldenEvent: Decodable {
        var at: String
        var type: String
    }

    // MARK: - 日期口径

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private func date(_ string: String) throws -> Date {
        try XCTUnwrap(Self.dayFormatter.date(from: string), "无法解析日期 \(string)")
    }

    private func loadGolden() throws -> GoldenFile {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "golden_values", withExtension: "json"),
            "找不到 golden_values.json —— 检查 Package.swift 的 resources 声明"
        )
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(GoldenFile.self, from: data)
    }

    // MARK: - 断言

    /// 相对容差比较。浮点运算顺序在两门语言间可能有末位差异，1e-9 足够严格。
    private func assertClose(
        _ actual: Double,
        _ expected: Double,
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let tolerance = max(abs(expected) * 1e-9, 1e-12)
        XCTAssertEqual(actual, expected, accuracy: tolerance, label, file: file, line: line)
    }

    // MARK: - 主测试

    func testGoldenValuesMatchReferenceImplementation() throws {
        let golden = try loadGolden()
        let today = try date(golden.today)
        let model = LifetimeModel()

        XCTAssertEqual(golden.cases.count, 15, "黄金用例数量变了，确认是无意的还是漏改了")

        for key in golden.cases.keys.sorted() {
            let gold = golden.cases[key]!

            // --- 用黄金文件里的配置重建 Device（完全数据驱动） ---
            let kind = try XCTUnwrap(BatteryKind(rawValue: gold.kind), "未知电池种类 \(gold.kind)")
            let events: [ReplacementEvent] = try gold.events.map { event in
                let eventKind = try XCTUnwrap(
                    EventKind(rawValue: event.type), "未知事件类型 \(event.type)"
                )
                return ReplacementEvent(at: try date(event.at), kind: eventKind)
            }
            let device = Device(
                name: gold.name,
                kind: kind,
                events: events,
                notifyLeadDays: gold.notifyLeadDays,
                nominalLifeDays: gold.nominalLifeDays,
                referencePrior: gold.referencePrior
            )

            let prediction = try XCTUnwrap(model.predict(device, today: today), "用例 \(key) 无预测")

            // --- 后验 ---
            XCTAssertEqual(prediction.posterior.observedCount, gold.nObserved, "[\(key)] nObserved")
            assertClose(prediction.posterior.effectiveSampleSize, gold.nEff, "[\(key)] nEff")
            assertClose(prediction.posterior.logMean, gold.m, "[\(key)] m")
            assertClose(prediction.posterior.logSigma, gold.sigmaPost, "[\(key)] sigmaPost")
            assertClose(prediction.posterior.withinDeviceSigma, gold.sigmaWithin, "[\(key)] sigmaWithin")
            assertClose(prediction.sigmaPrediction, gold.sigmaPred, "[\(key)] sigmaPred")

            // --- 预测 ---
            assertClose(prediction.medianDays, gold.medianDays, "[\(key)] medianDays")
            assertClose(prediction.p10Days, gold.p10Days, "[\(key)] p10Days")
            assertClose(prediction.ratio, gold.ratio, "[\(key)] ratio")

            // --- 日期 ---
            XCTAssertEqual(Self.dayFormatter.string(from: prediction.medianDate), gold.medianDate,
                           "[\(key)] medianDate")
            XCTAssertEqual(Self.dayFormatter.string(from: prediction.riskDate), gold.riskDate,
                           "[\(key)] riskDate")

            // --- 整数天 ---
            XCTAssertEqual(prediction.remainingDays, gold.remainingDays, "[\(key)] remainingDays")
            XCTAssertEqual(prediction.riskRemainingDays, gold.riskRemainingDays,
                           "[\(key)] riskRemainingDays")
            XCTAssertEqual(prediction.ageDays, gold.ageDays, "[\(key)] ageDays")

            // --- 分级 ---
            XCTAssertEqual(prediction.urgency.rawValue, gold.urgency, "[\(key)] urgency")
            XCTAssertEqual(prediction.confidence.rawValue, gold.confidence, "[\(key)] confidence")
        }
    }

    /// `installedAt` 必须等于最后一次事件，与语言无关的结构性事实。
    func testInstalledAtIsLastEvent() throws {
        let golden = try loadGolden()

        for key in golden.cases.keys.sorted() {
            let gold = golden.cases[key]!
            let kind = try XCTUnwrap(BatteryKind(rawValue: gold.kind))
            let events = try gold.events.map {
                ReplacementEvent(at: try date($0.at),
                                 kind: try XCTUnwrap(EventKind(rawValue: $0.type)))
            }
            let device = Device(name: gold.name, kind: kind, events: events)
            XCTAssertEqual(
                Self.dayFormatter.string(from: try XCTUnwrap(device.installedAt)),
                gold.installedAt,
                "[\(key)] installedAt"
            )
        }
    }
}
