import XCTest
@testable import CheckJuiceCore

/// 行为不变量测试。
///
/// 黄金数值测试保证「和参考实现算得一样」，这一组保证「算的是对的东西」——
/// 即那些容易被后续重构悄悄破坏的**语义约定**。
final class BehaviourTests: XCTestCase {

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private let model = LifetimeModel()
    private var today: Date { Self.dayFormatter.date(from: "2026-10-14")! }

    // MARK: - 构造工具

    /// 按「相邻更换间隔」构造设备，`since` = 最后一次事件距今天的天数。
    private func makeDevice(
        name: String = "测试设备",
        kind: BatteryKind = .cr2032,
        intervals: [Int],
        since: Int,
        kinds: [EventKind]? = nil,
        notifyLeadDays: Int = 14,
        nominalLifeDays: Double? = nil,
        referencePrior: ReferencePrior? = nil
    ) -> Device {
        let total = intervals.reduce(0, +) + since
        var cursor = model.date(byAddingDays: -total, to: today)
        var events = [ReplacementEvent(at: cursor, kind: .initial)]
        let resolvedKinds = kinds ?? Array(repeating: .exhausted, count: intervals.count)
        for index in intervals.indices {
            cursor = model.date(byAddingDays: intervals[index], to: cursor)
            events.append(ReplacementEvent(at: cursor, kind: resolvedKinds[index]))
        }
        return Device(
            name: name, kind: kind, events: events,
            notifyLeadDays: notifyLeadDays,
            nominalLifeDays: nominalLifeDays,
            referencePrior: referencePrior
        )
    }

    private func mustPredict(_ device: Device, on date: Date? = nil) throws -> Prediction {
        try XCTUnwrap(model.predict(device, today: date ?? today))
    }

    /// 浮点比较。容差用**相对**误差 —— 这些量的量级从 0.15 到 300 天都有，绝对值不管用。
    ///
    /// 为什么是 1e-6，而不是更紧：
    ///   * 期望值字面量本身只写到 8 位小数（如 0.39737401），其自身相对误差就在
    ///     ~1e-9 量级。原来这里是 1e-9，等于拿「已四舍五入的期望值」去卡
    ///     「全精度的实际值」，必然误报 —— 实测踩过，n=1/2/3 窗口宽度全红。
    ///   * 算法里有 exp/log/pow，几十步累积后相对误差到 1e-12 是正常水平。
    ///   * 真出算法错误时偏差在 1e-3 以上。1e-6 既抓得住错误，又比浮点噪声宽
    ///     6 个数量级。**精确数值比对交给 GoldenValueTests 负责**，
    ///     这组测试的职责是「语义不变量」。
    private func assertClose(
        _ actual: Double, _ expected: Double, _ label: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(actual, expected, accuracy: max(abs(expected) * 1e-6, 1e-12),
                       label, file: file, line: line)
    }

    // MARK: - 舍入口径

    /// 舍入必须与参考实现一致。Python 内建 round() 是银行家舍入（round(2.5)==2），
    /// Swift 的 .rounded() 是四舍五入。这是移植期最隐蔽的 1 天偏差来源。
    func testRoundHalfUpDiffersFromBankersRounding() {
        XCTAssertEqual(LifetimeModel.roundHalfUp(0.5), 1)
        XCTAssertEqual(LifetimeModel.roundHalfUp(1.5), 2)
        XCTAssertEqual(LifetimeModel.roundHalfUp(2.5), 3)   // ← Python round(2.5) 会是 2
        XCTAssertEqual(LifetimeModel.roundHalfUp(2.4), 2)
        XCTAssertEqual(LifetimeModel.roundHalfUp(310.51), 311)
        XCTAssertEqual(LifetimeModel.roundHalfUp(310.49), 310)
    }

    // MARK: - 空设备

    func testDeviceWithoutEventsHasNoPrediction() {
        let empty = Device(name: "空设备", kind: .cr2032, events: [])
        XCTAssertNil(model.predict(empty, today: today))
    }

    // MARK: - 截尾观测的语义（最容易做错的地方）

    /// 截尾观测**不进统计**，但**照样重置起算点**。这两件事必须分开。
    func testCensoredIntervalExcludedFromStatisticsButStillResetsAnchor() throws {
        // A: 300 天后自然耗尽 → 换新；120 天后又提前换了一次 → 当前这颗从 200 天前算起
        let censored = makeDevice(
            intervals: [300, 120],
            since: 200,
            kinds: [.exhausted, .preventive]
        )
        // B: 只有一次 300 天的自然耗尽，当前这颗从 320 天前算起
        let clean = makeDevice(intervals: [300], since: 320)

        let a = try mustPredict(censored)
        let b = try mustPredict(clean)

        // ── 统计侧：那段 120 天被剔除，两者算出的寿命分布完全一致 ──
        XCTAssertEqual(a.posterior.observedCount, 1)
        XCTAssertEqual(b.posterior.observedCount, 1)
        assertClose(a.posterior.logMean, 5.7556952367, "后验均值")
        assertClose(a.posterior.logMean, b.posterior.logMean, "两者后验应一致")
        assertClose(a.medianDays, 315.9851556602851, "预测中位寿命")

        // ── 锚点侧：当前这颗电池的年龄不同 ──
        XCTAssertEqual(a.ageDays, 200)
        XCTAssertEqual(b.ageDays, 320)
        XCTAssertGreaterThan(a.riskDate, b.riskDate, "A 的起算点更晚，风险日应更晚")
    }

    /// 一次提前失效的坏电池，不应该把整台设备的寿命估计拖下水。
    func testFaultyBatteryDoesNotPoisonEstimate() throws {
        let deviceKinds: [EventKind] = [
            .exhausted, .exhausted, .exhausted, .faulty, .exhausted, .exhausted,
        ]
        let withFaulty = makeDevice(
            intervals: [300, 290, 310, 60, 295, 285], since: 120, kinds: deviceKinds
        )
        let withoutFaulty = makeDevice(intervals: [300, 290, 310, 295, 285], since: 120)

        let a = try mustPredict(withFaulty)
        let b = try mustPredict(withoutFaulty)

        XCTAssertEqual(a.posterior.observedCount, 5, "6 段间隔里应有 1 段被剔除")
        assertClose(a.medianDays, 295.12023380047447, "含坏电池的中位寿命")
        // 与「根本没有这段坏数据」相比，结果应完全一致
        assertClose(a.medianDays, b.medianDays, "坏电池不得影响估计")
    }

    // MARK: - 逾期不自动修正

    /// 预测日过了没换，只标「逾期」，**绝不把预测往后推**。
    /// 逾期本身是信息（说明比模型预期耐用），只有点了「已更换」才闭环成新观测。
    func testOverdueDoesNotAutoCorrectPrediction() throws {
        let device = makeDevice(intervals: [300, 290], since: 330)

        let now = try mustPredict(device)
        let sixtyDaysLater = try mustPredict(
            device, on: model.date(byAddingDays: 60, to: today)
        )

        // 同样的数据，无论"今天"是哪天，预测结果必须一模一样
        assertClose(now.medianDays, 304.1934718919141, "预测中位寿命")
        assertClose(now.medianDays, sixtyDaysLater.medianDays, "逾期后预测不得漂移")
        XCTAssertEqual(now.medianDate, sixtyDaysLater.medianDate, "预计耗尽日不得漂移")

        // 变的只是「逾期多少天」
        XCTAssertEqual(now.remainingDays, -26)
        XCTAssertEqual(sixtyDaysLater.remainingDays, -86)
        XCTAssertEqual(now.urgency, .overdue)
        XCTAssertEqual(sixtyDaysLater.urgency, .overdue)
    }

    // MARK: - 冷启动要诚实

    /// 刚添加、零样本时，必须承认自己不知道，而不是给一个看起来很准的数字。
    func testColdStartIsHonestlyUncertain() throws {
        let device = Device.newlyAdded(name: "新设备", kind: .cr2032, on: today)
        let prediction = try mustPredict(device)

        XCTAssertEqual(prediction.posterior.observedCount, 0)
        XCTAssertEqual(prediction.confidence, .low)
        XCTAssertEqual(prediction.urgency, .normal)
        assertClose(prediction.medianDays, 365.0, "冷启动中位寿命 = 种类典型值")
        // σ_pred 被封顶在 0.70，窗口不会荒谬地宽，但依然很宽
        assertClose(prediction.sigmaPrediction, 0.70, "冷启动预测宽度封顶")
    }

    func testConfidenceProgression() throws {
        XCTAssertEqual(try mustPredict(makeDevice(intervals: [], since: 0)).confidence, .low)
        XCTAssertEqual(try mustPredict(makeDevice(intervals: [300], since: 10)).confidence, .low)
        XCTAssertEqual(try mustPredict(makeDevice(intervals: [300, 290], since: 10)).confidence, .medium)
        XCTAssertEqual(
            try mustPredict(makeDevice(intervals: [300, 290, 310], since: 10)).confidence, .medium
        )
        XCTAssertEqual(
            try mustPredict(makeDevice(intervals: [300, 290, 310, 295, 285], since: 10)).confidence,
            .high
        )
    }

    // MARK: - 不确定性下限

    /// 样本再多，窗口也不会收敛到 0。
    ///
    /// 物理依据：同一台设备连换两次同型号电池，寿命天然就有 15%~20% 的差异。
    /// 给出「±3 天」这种精度是骗人的。3 个样本和 200 个样本给出**完全相同**的宽度，
    /// 因为此时限制因素已经是 σ_min，而不是样本量。
    func testUncertaintyNeverCollapsesBelowFloor() throws {
        let sigmas: [Double] = try [3, 5, 15, 200].map { n in
            let device = makeDevice(intervals: Array(repeating: 300, count: n), since: 50)
            return try mustPredict(device).sigmaPrediction
        }

        let expected = (0.15 * 0.15 + 0.15 * 0.15).squareRoot()   // = 0.2121320343559643
        assertClose(expected, 0.2121320343559643, "地板值自检")
        for (index, sigma) in sigmas.enumerated() {
            assertClose(sigma, expected, "第 \(index) 组的 σ_pred 应等于地板值")
        }

        // 宽度递减但很快触底
        let widths: [Double] = try [1, 2, 3].map { n in
            let device = makeDevice(intervals: Array(repeating: 300, count: n), since: 50)
            let prediction = try mustPredict(device)
            return (prediction.medianDays - prediction.p10Days) / prediction.medianDays
        }
        assertClose(widths[0], 0.39737401, "n=1 窗口宽度")
        assertClose(widths[1], 0.36905351, "n=2 窗口宽度")
        assertClose(widths[2], 0.23803766, "n=3 窗口宽度")
        XCTAssertGreaterThan(widths[0], widths[1])
        XCTAssertGreaterThan(widths[1], widths[2])
    }

    // MARK: - 参照先验

    /// 借用同型号设备的历史，应当收窄不确定性。
    func testReferencePriorNarrowsUncertainty() throws {
        let withReference = makeDevice(
            intervals: [300, 290], since: 100,
            referencePrior: ReferencePrior(medianLifeDays: 300, tau: 0.25)
        )
        let withDefault = makeDevice(intervals: [300, 290], since: 100)

        let ref = try mustPredict(withReference)
        let def = try mustPredict(withDefault)

        assertClose(ref.posterior.logSigma, 0.16318821, "参照先验下的 σ_post")
        assertClose(def.posterior.logSigma, 0.19783146, "默认先验下的 σ_post")
        assertClose(ref.sigmaPrediction, 0.34151192, "参照先验下的 σ_pred")
        assertClose(def.sigmaPrediction, 0.35935677, "默认先验下的 σ_pred")
        XCTAssertLessThan(ref.sigmaPrediction, def.sigmaPrediction, "参照先验应更确定")

        // 中位寿命也被先验牵引（296.59 vs 304.19），这是预期行为
        assertClose(ref.medianDays, 296.58606192, "参照先验下的中位寿命")
    }

    // MARK: - 紧急度：从「风险窗口」量起，不是从「中位日」量起

    /// 这条是设计上的关键修正。
    ///
    /// 若按「距中位日」判定，该设备距中位日还有 134 天 → 会被判「正常」，
    /// 而它距**风险窗口开启**只剩 22 天 → 实际已经该备货了。
    /// 用中位日当判据，「该备货」几乎永远不会触发，中间的窗口期全被误标成「风险」。
    func testStockUpIsMeasuredFromRiskWindowNotMedian() throws {
        let device = makeDevice(intervals: [300, 290], since: 170, notifyLeadDays: 30)
        let prediction = try mustPredict(device)

        XCTAssertEqual(prediction.remainingDays, 134, "距中位日")
        XCTAssertEqual(prediction.riskRemainingDays, 22, "距风险窗口开启")
        XCTAssertEqual(prediction.urgency, .stockUp, "22 ≤ 30，应判「该备货」")

        // 同样的设备，把提前量收到 14 天，就还没到备货的时候
        let tighter = makeDevice(intervals: [300, 290], since: 170, notifyLeadDays: 14)
        XCTAssertEqual(try mustPredict(tighter).urgency, .normal)
    }

    func testUrgencyThresholds() throws {
        let base = [300, 290]

        // 已过中位日
        XCTAssertEqual(
            try mustPredict(makeDevice(intervals: base, since: 330)).urgency, .overdue
        )
        // 已进入风险窗口（P10 之后），但还没到中位日
        let risk = try mustPredict(makeDevice(intervals: base, since: 200))
        XCTAssertEqual(risk.urgency, .risk)
        XCTAssertEqual(risk.riskRemainingDays, -8)
        XCTAssertGreaterThan(risk.remainingDays, 0, "尚未逾期，只是进入了风险窗口")
        // 正常
        XCTAssertEqual(
            try mustPredict(makeDevice(intervals: base, since: 90)).urgency, .normal
        )
    }

    func testPredictionsSortedByUrgency() throws {
        let overdue = makeDevice(name: "逾期", intervals: [300, 290], since: 330)
        let stockUp = makeDevice(name: "备货", intervals: [300, 290], since: 170,
                                 notifyLeadDays: 30)
        let normal = makeDevice(name: "正常", intervals: [300, 290], since: 90)

        let sorted = model.predictions(for: [normal, overdue, stockUp], today: today)

        XCTAssertEqual(sorted.map { $0.device.name }, ["逾期", "备货", "正常"])
        XCTAssertEqual(sorted.map { $0.prediction.urgency }, [.overdue, .stockUp, .normal])
    }

    // MARK: - 展示文本

    func testShortDescription() throws {
        XCTAssertEqual(
            try mustPredict(makeDevice(intervals: [300, 290], since: 330)).shortDescription,
            "逾期 26 天"
        )
        // ⚠️ 这两条原先是 "≤ 8 天" / "209 天"，都是**陈旧期望值**：
        //    "≤ 8 天" 是把 riskRemainingDays（= 距 P10 还有几天，此处为 -8）
        //    取绝对值印出来的结果 —— 实际距中位日还有 104 天，差了十倍以上。
        //    已用 Python 参考实现复核：median 304.1935 / p10 191.9298，
        //    since=200 → remaining 104（进入风险窗口）；since=90 → remaining 214。
        XCTAssertEqual(
            try mustPredict(makeDevice(intervals: [300, 290], since: 200)).shortDescription,
            "≤ 104 天"
        )
        XCTAssertEqual(
            try mustPredict(makeDevice(intervals: [300, 290], since: 90)).shortDescription,
            "214 天"
        )
    }
}
