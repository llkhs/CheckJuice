import XCTest
@testable import CheckJuiceCore

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
        var installedAt: String
        var notifyLeadHours: Double
        var nominalLifeHours: Double
        var referencePrior: ReferencePrior?
        var events: [GoldenEvent]

        var nObserved: Int
        var nEff: Double
        var m: Double
        var sigmaPost: Double
        var sigmaWithin: Double
        var sigmaPred: Double
        var medianHours: Double
        var p10Hours: Double
        var p50ExhaustAt: String
        var p10ExhaustAt: String
        var remainingHours: Double
        var p10RemainingHours: Double
        var ageHours: Double
        var ratio: Double
        var urgency: String
        var confidence: String
        /// 显示层产物：主文案（P10）与副行（中位）。
        /// 放进黄金文件是为了让取整口径、单位阈值的跨语言漂移也能被 CI 抓住。
        var headlineRemaining: String
        var medianLineRemaining: String
    }

    private struct GoldenEvent: Decodable {
        var at: String
        var type: String
    }

    // MARK: - 日期口径

    /// 黄金文件里的时间戳是 ISO 形式（`2026-10-14T12:00:00`），秒精度。
    private static let isoFormatter =
        GoldenValueTests.makeFormatter("yyyy-MM-dd'T'HH:mm:ss")

    /// **分钟**精度，用来比对导出时刻。
    ///
    /// 为什么不比到微秒：Swift 的 `Date` 是 Double 秒，Python 的 `datetime` 是微秒，
    /// 两者往返必然在末位有差异 —— 拿微秒比就是自找误报。而本 App 的最小刻度是
    /// **1 小时**，分钟精度已经比有效分辨率细 60 倍。
    private static let minuteFormatter =
        GoldenValueTests.makeFormatter("yyyy-MM-dd'T'HH:mm")

    private static func makeFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        return formatter
    }

    private func date(_ string: String) throws -> Date {
        try XCTUnwrap(Self.isoFormatter.date(from: string), "无法解析时间戳 \(string)")
    }

    private func moment(_ date: Date) -> String {
        Self.minuteFormatter.string(from: date)
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

    /// 相对容差比较。
    ///
    /// 原为 1e-9，实测过紧：期望值字面量只有 15~17 位有效数字，其自身相对误差
    /// 就在 1e-16 量级，而跨语言（Python float ↔ Swift Double）的运算顺序差异会让
    /// 末位再偏几 ulp。真出错时偏差在 1e-3 以上，1e-6 既抓得住错误，又比噪声
    /// 宽 6 个数量级。
    private func assertClose(
        _ actual: Double,
        _ expected: Double,
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let tolerance = max(abs(expected) * 1e-6, 1e-12)
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
            let events: [ReplacementEvent] = try gold.events.map { event in
                let eventKind = try XCTUnwrap(
                    EventKind(rawValue: event.type), "未知事件类型 \(event.type)"
                )
                return ReplacementEvent(at: try date(event.at), kind: eventKind)
            }
            let device = Device(
                name: gold.name,
                nominalLifeHours: gold.nominalLifeHours,
                events: events,
                notifyLeadHours: gold.notifyLeadHours,
                referencePrior: gold.referencePrior
            )

            let prediction = try XCTUnwrap(model.predict(device, now: today), "用例 \(key) 无预测")

            // --- 后验 ---
            XCTAssertEqual(prediction.posterior.observedCount, gold.nObserved, "[\(key)] nObserved")
            assertClose(prediction.posterior.effectiveSampleSize, gold.nEff, "[\(key)] nEff")
            assertClose(prediction.posterior.logMean, gold.m, "[\(key)] m")
            assertClose(prediction.posterior.logSigma, gold.sigmaPost, "[\(key)] sigmaPost")
            assertClose(prediction.posterior.withinDeviceSigma, gold.sigmaWithin, "[\(key)] sigmaWithin")
            assertClose(prediction.sigmaPrediction, gold.sigmaPred, "[\(key)] sigmaPred")

            // --- 预测 ---
            assertClose(prediction.medianHours, gold.medianHours, "[\(key)] medianHours")
            assertClose(prediction.p10Hours, gold.p10Hours, "[\(key)] p10Hours")
            assertClose(prediction.ratio, gold.ratio, "[\(key)] ratio")

            // --- 时刻（分钟精度，理由见 minuteFormatter）---
            XCTAssertEqual(moment(prediction.p50ExhaustAt), String(gold.p50ExhaustAt.prefix(16)),
                           "[\(key)] p50ExhaustAt")
            XCTAssertEqual(moment(prediction.p10ExhaustAt), String(gold.p10ExhaustAt.prefix(16)),
                           "[\(key)] p10ExhaustAt")

            // --- 整数小时。是 Double，必须用相对容差比，不能 == ---
            assertClose(prediction.remainingHours, gold.remainingHours, "[\(key)] remainingHours")
            assertClose(prediction.p10RemainingHours, gold.p10RemainingHours,
                        "[\(key)] p10RemainingHours")
            assertClose(prediction.ageHours, gold.ageHours, "[\(key)] ageHours")

            // --- 分级 ---
            XCTAssertEqual(prediction.urgency.rawValue, gold.urgency, "[\(key)] urgency")
            XCTAssertEqual(prediction.confidence.rawValue, gold.confidence, "[\(key)] confidence")

            // --- 显示文案。走的是 P10，不是中位 ---
            XCTAssertEqual(prediction.remainingText(style: .remaining), gold.headlineRemaining,
                           "[\(key)] headlineRemaining")
            XCTAssertEqual(prediction.medianText(style: .remaining), gold.medianLineRemaining,
                           "[\(key)] medianLineRemaining")
        }
    }

    /// `installedAt` 必须等于最后一次事件，与语言无关的结构性事实。
    func testInstalledAtIsLastEvent() throws {
        let golden = try loadGolden()

        for key in golden.cases.keys.sorted() {
            let gold = golden.cases[key]!
            let events = try gold.events.map {
                ReplacementEvent(at: try date($0.at),
                                 kind: try XCTUnwrap(EventKind(rawValue: $0.type)))
            }
            let device = Device(name: gold.name, nominalLifeHours: gold.nominalLifeHours, events: events)
            XCTAssertEqual(
                moment(try XCTUnwrap(device.installedAt)),
                String(gold.installedAt.prefix(16)),
                "[\(key)] installedAt"
            )
        }
    }
}
