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

    /// 天 → 小时。测试场景用「天」描述更贴近直觉（「一块 300 天的电池」），
    /// 但喂给模型的一律是小时 —— 这正是本次改动的核心，不该在测试里被抹掉。
    private func h(_ days: Double) -> Double { days * 24 }

    /// 按「相邻更换间隔」构造设备，`intervals`/`since` 单位是**小时**。
    private func makeDevice(
        name: String = "测试设备",
        nominalLifeHours: Double = 8760,
        intervals: [Double],
        since: Double,
        kinds: [EventKind]? = nil,
        notifyLeadHours: Double = 336,
        referencePrior: ReferencePrior? = nil
    ) -> Device {
        let total = intervals.reduce(0, +) + since
        var cursor = LifetimeModel.date(byAddingHours: -total, to: today)
        var events = [ReplacementEvent(at: cursor, kind: .initial)]
        let resolvedKinds = kinds ?? Array(repeating: .exhausted, count: intervals.count)
        for index in intervals.indices {
            cursor = LifetimeModel.date(byAddingHours: intervals[index], to: cursor)
            events.append(ReplacementEvent(at: cursor, kind: resolvedKinds[index]))
        }
        return Device(
            name: name, nominalLifeHours: nominalLifeHours, events: events,
            notifyLeadHours: notifyLeadHours,
            referencePrior: referencePrior
        )
    }

    private func mustPredict(_ device: Device, at moment: Date? = nil) throws -> Prediction {
        try XCTUnwrap(model.predict(device, now: moment ?? today))
    }

    /// 浮点比较。容差用**相对**误差 —— 这些量的量级从 0.15 到 7200 小时都有，绝对值不管用。
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

    // MARK: - 取整口径

    /// 整数小时必须**朝零截断**：两个方向都不许吹牛。
    ///
    /// 旧版这里是 `roundHalfUp`，它存在的唯一理由是把「浮点天」对齐到「整数天」——
    /// 而「天」那个粒度本身就是 bug：4 天的纽扣电池只剩 3.5 天时，模型读到的是
    /// 「3 天」，系统性低估 23%。换成小时后，需要的是「不夸大」，不是「四舍五入」。
    func testWholeHoursTruncatesTowardZero() {
        XCTAssertEqual(LifetimeModel.wholeHours(619.9), 619, "剩余不向上吹")
        XCTAssertEqual(LifetimeModel.wholeHours(620.0), 620)
        XCTAssertEqual(LifetimeModel.wholeHours(-619.9), -619, "逾期不夸大")
        XCTAssertEqual(LifetimeModel.wholeHours(-0.5), 0, "差一点耗尽不算逾期")
        XCTAssertEqual(LifetimeModel.wholeHours(0), 0)
        XCTAssertEqual(LifetimeModel.wholeHours(.infinity), 0, "非有限值退化为 0")
        XCTAssertEqual(LifetimeModel.wholeHours(-.infinity), 0)
    }

    // MARK: - 空设备

    func testDeviceWithoutEventsHasNoPrediction() {
        let empty = Device(name: "空设备", nominalLifeHours: 8760, events: [])
        XCTAssertNil(model.predict(empty, now: today))
    }

    // MARK: - 截尾观测的语义（最容易做错的地方）

    /// 截尾观测**不进统计**，但**照样重置起算点**。这两件事必须分开。
    func testCensoredIntervalExcludedFromStatisticsButStillResetsAnchor() throws {
        // A: 300 天后自然耗尽 → 换新；120 天后又提前换了一次 → 当前这颗从 200 天前算起
        let censored = makeDevice(
            intervals: [h(300), h(120)],
            since: h(200),
            kinds: [.exhausted, .preventive]
        )
        // B: 只有一次 300 天的自然耗尽，当前这颗从 320 天前算起
        let clean = makeDevice(intervals: [h(300)], since: h(320))

        let a = try mustPredict(censored)
        let b = try mustPredict(clean)

        // ── 统计侧：那段 120 天被剔除，两者算出的寿命分布完全一致 ──
        XCTAssertEqual(a.posterior.observedCount, 1)
        XCTAssertEqual(b.posterior.observedCount, 1)
        assertClose(a.posterior.logMean, 8.93374906707287, "后验均值")
        assertClose(a.posterior.logMean, b.posterior.logMean, "两者后验应一致")
        assertClose(a.medianHours, 7583.64373584684, "预测中位寿命")

        // ── 锚点侧：当前这颗电池的年龄不同 ──
        assertClose(a.ageHours, 4800, "A 当前电池的年龄")
        assertClose(b.ageHours, 7680, "B 当前电池的年龄")
        XCTAssertGreaterThan(a.p10ExhaustAt, b.p10ExhaustAt, "A 的起算点更晚，风险日应更晚")
    }

    /// 一次提前失效的坏电池，不应该把整台设备的寿命估计拖下水。
    func testFaultyBatteryDoesNotPoisonEstimate() throws {
        let deviceKinds: [EventKind] = [
            .exhausted, .exhausted, .exhausted, .faulty, .exhausted, .exhausted,
        ]
        let withFaulty = makeDevice(
            intervals: [h(300), h(290), h(310), h(60), h(295), h(285)], since: h(120), kinds: deviceKinds
        )
        let withoutFaulty = makeDevice(intervals: [h(300), h(290), h(310), h(295), h(285)], since: h(120))

        let a = try mustPredict(withFaulty)
        let b = try mustPredict(withoutFaulty)

        XCTAssertEqual(a.posterior.observedCount, 5, "6 段间隔里应有 1 段被剔除")
        assertClose(a.medianHours, 7082.885611211391, "含坏电池的中位寿命")
        // 与「根本没有这段坏数据」相比，结果应完全一致
        assertClose(a.medianHours, b.medianHours, "坏电池不得影响估计")
    }

    // MARK: - 逾期不自动修正

    /// 预测日过了没换，只标「逾期」，**绝不把预测往后推**。
    /// 逾期本身是信息（说明比模型预期耐用），只有点了「已更换」才闭环成新观测。
    func testOverdueDoesNotAutoCorrectPrediction() throws {
        let device = makeDevice(intervals: [h(300), h(290)], since: h(330))

        let now = try mustPredict(device)
        let sixtyDaysLater = try mustPredict(
            device, at: LifetimeModel.date(byAddingHours: h(60), to: today)
        )

        // 同样的数据，无论"今天"是哪天，预测结果必须一模一样
        assertClose(now.medianHours, 7300.643325405929, "预测中位寿命")
        assertClose(now.medianHours, sixtyDaysLater.medianHours, "逾期后预测不得漂移")
        XCTAssertEqual(now.p50ExhaustAt, sixtyDaysLater.p50ExhaustAt, "预计耗尽日不得漂移")

        // 变的只是「逾期多少天」
        assertClose(now.remainingHours, -619.3566745941666, "距中位日")
        assertClose(sixtyDaysLater.remainingHours, -2059.3566745941666, "60 天后距中位日")
        XCTAssertEqual(now.urgency, .overdue)
        XCTAssertEqual(sixtyDaysLater.urgency, .overdue)
    }

    // MARK: - 冷启动要诚实

    /// 刚添加、零样本时，必须承认自己不知道，而不是给一个看起来很准的数字。
    func testColdStartIsHonestlyUncertain() throws {
        let device = Device.newlyAdded(name: "新设备", nominalLifeHours: 8760, at: today)
        let prediction = try mustPredict(device)

        XCTAssertEqual(prediction.posterior.observedCount, 0)
        XCTAssertEqual(prediction.confidence, .low)
        XCTAssertEqual(prediction.urgency, .normal)
        assertClose(prediction.medianHours, 8760.0, "冷启动中位寿命 = 种类典型值（365 天）")
        // σ_pred 被封顶在 0.70，窗口不会荒谬地宽，但依然很宽
        assertClose(prediction.sigmaPrediction, 0.70, "冷启动预测宽度封顶")
    }

    func testConfidenceProgression() throws {
        XCTAssertEqual(try mustPredict(makeDevice(intervals: [], since: h(0))).confidence, .low)
        XCTAssertEqual(try mustPredict(makeDevice(intervals: [h(300)], since: h(10))).confidence, .low)
        XCTAssertEqual(try mustPredict(makeDevice(intervals: [h(300), h(290)], since: h(10))).confidence, .medium)
        XCTAssertEqual(
            try mustPredict(makeDevice(intervals: [h(300), h(290), h(310)], since: h(10))).confidence, .medium
        )
        XCTAssertEqual(
            try mustPredict(makeDevice(intervals: [h(300), h(290), h(310), h(295), h(285)], since: h(10))).confidence,
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
            let device = makeDevice(intervals: Array(repeating: h(300), count: n), since: h(50))
            return try mustPredict(device).sigmaPrediction
        }

        let expected = (0.15 * 0.15 + 0.15 * 0.15).squareRoot()   // = 0.2121320343559643
        assertClose(expected, 0.2121320343559643, "地板值自检")
        for (index, sigma) in sigmas.enumerated() {
            assertClose(sigma, expected, "第 \(index) 组的 σ_pred 应等于地板值")
        }

        // 宽度递减但很快触底
        let widths: [Double] = try [1, 2, 3].map { n in
            let device = makeDevice(intervals: Array(repeating: h(300), count: n), since: h(50))
            let prediction = try mustPredict(device)
            return (prediction.medianHours - prediction.p10Hours) / prediction.medianHours
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
            intervals: [h(300), h(290)], since: h(100),
            referencePrior: ReferencePrior(medianLifeHours: 7200, tau: 0.25)
        )
        let withDefault = makeDevice(intervals: [h(300), h(290)], since: h(100))

        let ref = try mustPredict(withReference)
        let def = try mustPredict(withDefault)

        assertClose(ref.posterior.logSigma, 0.16318821, "参照先验下的 σ_post")
        assertClose(def.posterior.logSigma, 0.19783146, "默认先验下的 σ_post")
        assertClose(ref.sigmaPrediction, 0.34151192, "参照先验下的 σ_pred")
        assertClose(def.sigmaPrediction, 0.35935677, "默认先验下的 σ_pred")
        XCTAssertLessThan(ref.sigmaPrediction, def.sigmaPrediction, "参照先验应更确定")

        // 中位寿命也被先验牵引（296.59 vs 304.19），这是预期行为
        assertClose(ref.medianHours, 7118.065486194442, "参照先验下的中位寿命")
    }

    // MARK: - 紧急度：从「风险窗口」量起，不是从「中位日」量起

    /// 这条是设计上的关键修正。
    ///
    /// 若按「距中位日」判定，该设备距中位日还有 3221 小时（134 天）→ 会被判「正常」，
    /// 而它距**风险窗口开启**只剩 526 小时（22 天）→ 实际已经该备货了。
    /// 用中位日当判据，「该备货」几乎永远不会触发，中间的窗口期全被误标成「风险」。
    func testStockUpIsMeasuredFromRiskWindowNotMedian() throws {
        let device = makeDevice(intervals: [h(300), h(290)], since: h(170), notifyLeadHours: 720)
        let prediction = try mustPredict(device)

        assertClose(prediction.remainingHours, 3220.6433254058334, "距中位日")
        assertClose(prediction.p10RemainingHours, 526.3152481530556, "距风险窗口开启")
        XCTAssertEqual(prediction.urgency, .stockUp, "526 ≤ 720，应判「该备货」")

        // 同样的设备，把提前量收到 14 天，就还没到备货的时候
        let tighter = makeDevice(intervals: [h(300), h(290)], since: h(170), notifyLeadHours: 336)
        XCTAssertEqual(try mustPredict(tighter).urgency, .normal)
    }

    func testUrgencyThresholds() throws {
        let base = [h(300), h(290)]

        // 已过中位日
        XCTAssertEqual(
            try mustPredict(makeDevice(intervals: base, since: h(330))).urgency, .overdue
        )
        // 已进入风险窗口（P10 之后），但还没到中位日
        let risk = try mustPredict(makeDevice(intervals: base, since: h(200)))
        XCTAssertEqual(risk.urgency, .risk)
        assertClose(risk.p10RemainingHours, -193.68475184694444, "已越过风险窗口起点")
        XCTAssertGreaterThan(risk.remainingHours, 0, "尚未逾期，只是进入了风险窗口")
        // 正常
        XCTAssertEqual(
            try mustPredict(makeDevice(intervals: base, since: h(90))).urgency, .normal
        )
    }

    func testPredictionsSortedByUrgency() throws {
        let overdue = makeDevice(name: "逾期", intervals: [h(300), h(290)], since: h(330))
        let stockUp = makeDevice(name: "备货", intervals: [h(300), h(290)], since: h(170),
                                 notifyLeadHours: 720)
        let normal = makeDevice(name: "正常", intervals: [h(300), h(290)], since: h(90))

        let sorted = model.predictions(for: [normal, overdue, stockUp], now: today)

        XCTAssertEqual(sorted.map { $0.device.name }, ["逾期", "备货", "正常"])
        XCTAssertEqual(sorted.map { $0.prediction.urgency }, [.overdue, .stockUp, .normal])
    }

    // MARK: - 展示文本

    /// 单位自适应的边界。纯函数，直接喂数最清楚。
    func testAdaptiveHoursUnits() {
        // 阈值：< 2 天报小时，2~60 天报天，≥ 60 天报月。
        XCTAssertEqual(Prediction.adaptiveHours(0), "还剩 0 小时")
        XCTAssertEqual(Prediction.adaptiveHours(47.9), "还剩 47 小时")
        XCTAssertEqual(Prediction.adaptiveHours(48), "约 2 天")
        XCTAssertEqual(Prediction.adaptiveHours(1439), "约 59 天")
        XCTAssertEqual(Prediction.adaptiveHours(1440), "约 2 个月")

        // **朝零截断**：正数不吹牛说自己撑得久，负数不夸大严重程度。
        // （若用 floor，-619.9 会变「耗尽中 620 天／小时」—— 那是在夸大。）
        XCTAssertEqual(Prediction.adaptiveHours(619.9), "约 25 天")
        XCTAssertEqual(Prediction.adaptiveHours(-619.9), "耗尽中 25 天")
        XCTAssertEqual(Prediction.adaptiveHours(2.7), "还剩 2 小时")
        XCTAssertEqual(Prediction.adaptiveHours(-2.7), "耗尽中 2 小时")
    }

    /// 主文案必须是 **P10（最坏情况）**，不是中位数。
    ///
    /// 这组数就是「为什么不能看中位数」的教科书例子：
    /// 用了 200 天的那台，中位数说「还有约 3 个月」，而 P10 说「**耗尽中 8 天**」——
    /// 它早就进了风险窗口。盯着中位数换电池的人，会在这 3 个月里的某天突然断供。
    func testHeadlineShowsWorstCaseNotMedian() throws {
        func lines(since: Double) throws -> (String, String) {
            let p = try mustPredict(makeDevice(intervals: [h(300), h(290)], since: since))
            return (p.remainingText(style: .remaining), p.medianText(style: .remaining))
        }

        // 已耗尽：P10 已过 4 个月，中位也过了 25 天。
        XCTAssertEqual(try lines(since: h(330)).0, "耗尽中 4 个月")
        XCTAssertEqual(try lines(since: h(330)).1, "中位 · 耗尽中 25 天")

        // 风险窗口内：中位「约 3 个月」漂亮得很，P10 已经过期 8 天。
        XCTAssertEqual(try lines(since: h(200)).0, "耗尽中 8 天")
        XCTAssertEqual(try lines(since: h(200)).1, "中位 · 约 3 个月")
        XCTAssertEqual(
            try mustPredict(makeDevice(intervals: [h(300), h(290)], since: h(200))).urgency,
            .risk,
            "P10 已耗尽 → 必须判「风险窗口」，而不是看中位日判「正常」"
        )
    }

    /// 间隔护栏：一次误触不该毁掉整个寿命估计。
    ///
    /// 真实事故（2026-10-14 真机测试）：填「100 天」，添加完立刻点「已换电池 → 自然耗尽」。
    /// 修之前那条 2 分钟的记录被当成一次真实寿命观测吃掉，中位寿命从 100 天塌到 39 分钟。
    func testMisTapIntervalDoesNotPoisonEstimate() throws {
        let misTap = makeDevice(
            nominalLifeHours: h(100),
            intervals: [2.0 / 60.0],
            since: 0.5
        )
        assertClose(try mustPredict(misTap).medianHours, h(100), "误触不得污染寿命估计")

        let audits = LifetimeModel.auditIntervals(for: misTap)
        XCTAssertEqual(audits.count, 1)
        XCTAssertEqual(audits[0].reason, .tooShort)
        XCTAssertFalse(audits[0].counted)
    }

    /// 但自适应下限**不能**误杀极小电池的真实短周期。
    ///
    /// 4 小时电池的下限是 `min(1h, 4h×10%)` = 24 分钟：18 分钟不算，3 小时照算。
    func testAdaptiveFloorKeepsRealShortCycleForTinyBattery() throws {
        let tiny = makeDevice(nominalLifeHours: 4, intervals: [0.3, 3.0], since: 0.5)
        let audits = LifetimeModel.auditIntervals(for: tiny)

        XCTAssertEqual(audits[0].reason, .tooShort, "18 分钟 < 24 分钟下限")
        XCTAssertEqual(audits[1].reason, .sample, "3 小时 > 24 分钟下限，必须计入")
        XCTAssertEqual(audits[1].floorHours, 0.4, accuracy: 1e-12, "下限应为标称寿命的 10%")
    }

    /// 截尾观测（提前更换 / 故障）不进统计，但**照样重置起算点** ——
    /// 这是最容易做错的地方，所以钉住。
    func testCensoredReplacementResetsClockWithoutCounting() throws {
        // 同一串时间戳，只有「上一次是怎么结束的」不同：自然耗尽 vs 提前更换。
        let censored = makeDevice(intervals: [h(300), h(120)], since: h(10),
                                  kinds: [.exhausted, .preventive])
        let clean = makeDevice(intervals: [h(300), h(120)], since: h(10),
                               kinds: [.exhausted, .exhausted])

        // 起算点：两者都落在最后一次更换上，与那次是提前换还是自然耗尽无关。
        assertClose(try mustPredict(censored).ageHours, h(10), "起算点 = 最后一次更换")
        assertClose(try mustPredict(clean).ageHours, h(10), "起算点与结束类型无关")

        // 统计：提前更换那段被剔除，所以只有 1 条样本；自然耗尽则有 2 条。
        let audits = LifetimeModel.auditIntervals(for: censored)
        XCTAssertEqual(audits[1].reason, .censored)
        XCTAssertFalse(audits[1].counted)
        XCTAssertEqual(try mustPredict(censored).posterior.observedCount, 1)
        XCTAssertEqual(try mustPredict(clean).posterior.observedCount, 2)
    }
}
