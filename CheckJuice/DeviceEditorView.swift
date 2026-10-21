import SwiftUI
import CheckJuiceCore

/// 寿命输入的两种量级。
///
/// 原来是「天 / 月」两档，但主打数字是**还剩多少小时**，最小档就该是小时 ——
/// 4 天的纽扣电池在「月」这一档里根本填不出来。
enum LifeUnit: String, CaseIterable, Identifiable {
    case hours = "小时"
    case days = "天"

    var id: String { rawValue }

    /// 一个单位等于多少小时（模型内部单位）。
    var hoursPerUnit: Double { self == .hours ? 1.0 : 24.0 }
}

/// 编辑页里的一行「更换记录」。
struct EventDraft: Identifiable, Hashable {
    var id: UUID
    var at: Date
    var kind: EventKind

    init(id: UUID = UUID(), at: Date, kind: EventKind) {
        self.id = id
        self.at = at
        self.kind = kind
    }
}

/// 新增 / 编辑物品 —— **同一个页面**。
///
/// 之所以不分成两个页面：新增时要填的那点信息（名字 / 大概寿命 / 一条起始时间），
/// 就是编辑时输入框里已有的东西；而编辑的核心内容是**一串更换记录**，
/// 新增时的那一条不过是这个列表的首行。分成两个页面就会有两条不同的代码路径
/// 去构造同一个 `Device`，早晚会不一致。
struct DeviceEditorView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    /// `nil` = 新增；非 `nil` = 编辑这台。用 id 而不是 `Device` 值：
    /// 值快照会过期（小组件里刚记的一次更换就看不见了）。
    let editingID: UUID?

    @State private var name = ""
    @State private var lifeAmount = 72.0
    /// 默认停在**小时**上：这个 App 存在的理由是「今天够不够用」，
    /// 而现实里被盯得最紧的正是 4 小时~几天的短命电池。
    /// 长寿命设备切一下「天」就好，反过来的默认值会让短命设备根本填不出来。
    @State private var lifeUnit: LifeUnit = .hours
    /// 默认走模型里的常数，不在这儿再抄一个 4。
    @State private var notifyLeadAmount = Device.defaultNotifyLeadHours
    @State private var notifyLeadUnit: LifeUnit = .hours
    @State private var rows: [EventDraft] = []
    @State private var referencePrior: ReferencePrior?
    @State private var loaded = false
    /// 底部「删除这个物品」的确认框开关。
    @State private var showingDeleteConfirm = false
    /// 编辑页里起点是否处于「已解锁、可改」状态。
    ///
    /// **不持久化** —— 纯粹是这一次编辑的临时状态，退出编辑页就回到锁定。
    /// 想动起点，每次都得显式解一次锁：它值得这点麻烦。
    /// 名称输入框焦点。仅新增时自动获得（见 `load()`）。
    @FocusState private var nameFocused: Bool
    @State private var isAnchorUnlocked = false
    @State private var showingUnlockConfirm = false

    private var isEditing: Bool { editingID != nil }

    /// 「此刻」按分钟对齐后的值。
    ///
    /// 界面上只显示到分钟（`DatePicker(displayedComponents:)` 没有秒这一位），
    /// 所以存进数据的也必须到分钟 —— 否则用户看到 14:21、库里是 14:21:48，
    /// 两者差了一截，而他根本没机会选那 48 秒。
    /// 「此刻」。
    ///
    /// ⚠️ **不要截断到分钟**。曾经这里返回 `floorToMinute(Date())`，理由是
    /// 「界面上只显示到分钟，数据也不该有秒」。那是错的：
    ///
    /// * 用户没动选择器时，真实时刻（如 10:46:37）才**准确** —— 它就是按下按钮的那一刻。
    ///   截成 10:46:00 等于把事件往回挪了 37 秒，数据反而变不准。
    /// * 同一分钟内创建多台会得到**完全相同**的时间戳，排序无从区分
    ///   （真机事故：四台都变成 10:46:00，列表顺序乱跳）。
    ///
    /// 「界面精度即数据精度」只适用于用户**手动挑选**的时刻；
    /// 默认「此刻」就该保留真实精度。
    private static var now: Date { Date() }

    /// 按时间升序。列表就按这个顺序显示 —— 用户把某条改到更早的日期，
    /// 它会当场挪上去，「起始」标记也跟着换行，所见即所得。
    private var orderedRows: [EventDraft] {
        rows.sorted { $0.at < $1.at }
    }

    /// 每一段间隔的判定结果。`audits[i - 1]` 描述 `orderedRows[i-1] → orderedRows[i]`。
    private var audits: [IntervalAudit] {
        LifetimeModel.auditIntervals(for: draftDevice(name: "草稿"))
    }

    var body: some View {
        Form {
            identitySection
            lifeSection
            eventSection
            notifySection
            if isEditing { deleteSection }
        }
        .navigationTitle(isEditing ? "编辑物品" : "添加物品")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { save() }.disabled(!isValid)
            }
        }
        .onAppear(perform: load)
        .confirmationDialog(
            "把「\(name)」移到回收站？",
            isPresented: $showingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("移到回收站", role: .destructive) {
                if let id = editingID { appModel.delete(id: id) }
                dismiss()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("\(Int(Device.trashRetentionDays)) 天内可以在「设置 → 回收站」里找回来，之后自动清除。")
        }
        // 解锁起点用 `alert` 而不是第二个 `confirmationDialog`：
        // **同一个视图上叠两个 `.confirmationDialog` 会抽风**（谁弹出来不确定），
        // 这坑在回收站页刚踩过一次。两种不同的 presentation 类型共存则没问题。
        .alert("修改时间线起点？", isPresented: $showingUnlockConfirm) {
            Button("解锁") { isAnchorUnlocked = true }
            Button("取消", role: .cancel) {}
        } message: {
            Text("起点是每一段间隔的起算点。改了它，所有记录的时长都会重新算，"
                 + "预测也跟着变。改完记得点锁图标锁回去。")
        }
    }

    // MARK: - 各段

    private var identitySection: some View {
        Section("这是什么") {
            TextField("例如：温湿度计", text: $name)
                // 新增时焦点直接落在这里：进页面就能打字，不用先点一下输入框。
                // 编辑已有物品不抢焦点 —— 那时候用户多半是来改别的字段的。
                .focused($nameFocused)
        }
    }

    private var lifeSection: some View {
        Section {
            HStack {
                TextField("大概能用多久", value: $lifeAmount, format: .number)
                    .keyboardType(.decimalPad)
                Picker("", selection: $lifeUnit) {
                    ForEach(LifeUnit.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 130)
            }
            Text("≈ \(otherUnitText)")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("电池能撑多久")
        } footer: {
            Text("填个大概就行 —— 之后每次更换都会让预测变准。")
        }
    }

    /// 列表里的一行：把「是不是起点」「这一段的审计结果」这些
    /// 渲染时要用的东西一次性算好。
    ///
    /// 不用 `ForEach(Array(rows.enumerated()), id: \.element.id)` 那种写法 ——
    /// **Swift 的 key path 不能进元组**（`\.element.id` 编译不过）。
    private struct Row: Identifiable {
        let id: UUID
        let at: Date
        let isAnchor: Bool
        let audit: IntervalAudit?
    }

    /// 时间线起点 —— 最早那条记录的时刻。
    ///
    /// **它是整条时间线的锚**：改一下，它到下一颗之间的那段间隔就整个变了样，
    /// 而那段间隔正是这个 App 唯一的证据来源（`.initial` 只能当起点不能当终点）。
    /// 所以编辑已有物品时它默认只读，要改得先点锁图标解锁。
    private var anchorDate: Date? { orderedRows.first?.at }

    /// 起点的**上限** = 第二条记录的时刻。
    ///
    /// 起点必须是最早的那条，否则排序之后它会被顶到后面去 ——
    /// 用户以为自己改了起点，其实改的是普通记录，而**真正的起点偷偷换成了下一条**。
    /// 那种「改了等于没改、还顺手动了别的东西」最坑，所以直接把范围卡死。
    private var anchorUpperBound: Date? {
        orderedRows.count > 1 ? orderedRows[1].at : nil
    }

    private var rowModels: [Row] {
        let sorted = orderedRows
        // 按**终点时刻**取自己那一段，不靠下标猜：`auditIntervals` 里有
        // `.initial` 当终点就跳过的分支，下标一旦对不上就会错位到别人家的间隔。
        let auditsByEnd = Dictionary(
            audits.map { ($0.end, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let anchorID = sorted.first?.id
        return sorted.map { draft in
            Row(
                id: draft.id,
                at: draft.at,
                isAnchor: draft.id == anchorID,
                audit: draft.id == anchorID ? nil : auditsByEnd[draft.at]
            )
        }
    }

    private var eventSection: some View {
        Section {
            ForEach(rowModels) { row in
                eventRow(row)
                    // 起点不能删：删了它，时间线起点就顺延到下一条 ——
                    // 等于绕个弯把基准值改了。
                    .deleteDisabled(row.isAnchor)
            }
            .onDelete(perform: deleteRows)

            Button {
                rows.append(EventDraft(at: Self.now, kind: .exhausted))
            } label: {
                Label("加一条记录", systemImage: "plus.circle")
            }
        } header: {
            Text("更换记录")
        } footer: {
            if isEditing && isAnchorUnlocked {
                Text("起点已解锁：改完请点锁图标锁回去。起点一动，后面每一段的时长都会重新算。")
                    .foregroundStyle(.orange)
            } else if isEditing {
                Text("最早那条是时间线的起点，每一段的时长都从它算起。点右边的锁可以解锁修改。")
            } else {
                Text("已经换过几次？把它们补进来，预测就不用从零学起。最早那条会成为时间线起点。")
            }
        }
    }

    @ViewBuilder
    private func eventRow(_ row: Row) -> some View {
        let draft = binding(for: row.id)
        let isAnchor = row.isAnchor
        let audit = row.audit

        VStack(alignment: .leading, spacing: 6) {
            if isAnchor {
                Text(isEditing
                     ? "上次换电池的时刻 · 时间线起点"
                     : "上次换电池的时刻 · 从这儿开始算")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if isEditing {
                    // 默认只读，右侧的锁图标是唯一的修改入口。
                    // 为什么非要加这道锁：它是整条时间线的锚，改一下它到下一颗之间的间隔
                    // 就整个变了样，而那段间隔正是这个 App 唯一的证据来源。
                    HStack(spacing: 8) {
                        if isAnchorUnlocked {
                            anchorDatePicker(draft: draft)
                        } else {
                            Text(row.at.formatted(date: .long, time: .shortened))
                                .monospacedDigit()
                        }
                        Spacer(minLength: 8)
                        lockToggle
                    }
                } else {
                    // 新增时它是**正在被定义**的那个值，所以可改。
                    eventDatePicker(draft: draft, lowerBound: nil)
                }
            } else {
                Picker("上一颗怎么结束的", selection: draft.kind) {
                    ForEach([EventKind.exhausted, .preventive, .faulty], id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)

                // 下限卡在起点上：不加这个，用户「加一条更早的记录」就能把起点
                // 顺延走 —— 那是绕过锁定，等于基准值照样被改。
                eventDatePicker(draft: draft, lowerBound: anchorDate)
            }

            if let audit {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Image(systemName: auditIcon(audit))
                    Text(auditNote(audit))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption)
                .foregroundStyle(auditTint(audit))
            }
        }
        .padding(.vertical, 2)
    }

    /// 起点行的锁按钮 —— 修改起点的**唯一入口**。
    ///
    /// 图标用 SF Symbols 系统自带的 `lock.fill` / `lock.open.fill`：
    /// 不用打包任何图片资源、不用第三方图标库，且自动跟随字号、字重、深色模式。
    private var lockToggle: some View {
        Button {
            if isAnchorUnlocked {
                // 锁回去**不需要**确认：锁上永远更安全，就算误点也无害。
                isAnchorUnlocked = false
            } else {
                // 解锁要确认 —— 这一步是「我确实要动它」的分界线。
                showingUnlockConfirm = true
            }
        } label: {
            // 只有图标时点击区等于图标本身（约 20pt），太难点中。
            // 撑到 34pt 但**不加背景**，所以看起来还只是一个小图标。
            Image(systemName: isAnchorUnlocked ? "lock.open.fill" : "lock.fill")
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .tint(isAnchorUnlocked ? .orange : .secondary)
        .accessibilityLabel(isAnchorUnlocked ? "重新锁定起点" : "解锁并修改起点")
    }

    /// 起点的时刻选择器（仅解锁后显示）。
    ///
    /// 上限卡在第二条记录**之前**（减 1 秒是为了强制严格早于）：
    /// 起点允许等于第二条的话，排序结果会变得不确定，`orderedRows.first`
    /// 可能在两条之间跳 —— 那正是「改了等于没改」的源头。
    @ViewBuilder
    private func anchorDatePicker(draft: Binding<EventDraft>) -> some View {
        if let upper = anchorUpperBound {
            // 先算出上限再传进去：`...upper.addingTimeInterval(-1)` 写在一行里
            // 要人脑解析前缀运算符和方法调用的优先级，不如摊开。
            let limit = upper.addingTimeInterval(-1)
            DatePicker("", selection: draft.at, in: ...limit,
                       displayedComponents: [.date, .hourAndMinute])
                .labelsHidden()
        } else {
            DatePicker("", selection: draft.at,
                       displayedComponents: [.date, .hourAndMinute])
                .labelsHidden()
        }
    }

    /// 记录行的时刻选择器。`lowerBound` 传时间线起点时，用户**选不到更早的时刻**。
    ///
    /// 两个分支分开写，而不是硬造一个「无限早」的区间去填 `in:` ——
    /// 那要引入一个语义上根本不存在的边界值，纯属给后人挖坑。
    @ViewBuilder
    private func eventDatePicker(draft: Binding<EventDraft>, lowerBound: Date?) -> some View {
        if let lowerBound {
            DatePicker("", selection: draft.at, in: lowerBound...,
                       displayedComponents: [.date, .hourAndMinute])
                .labelsHidden()
        } else {
            DatePicker("", selection: draft.at,
                       displayedComponents: [.date, .hourAndMinute])
                .labelsHidden()
        }
    }

    private var notifySection: some View {
        Section {
            HStack {
                // 用 `Stepper` 而不是「文本框 + 手搓两个按钮」：
                // Stepper 自带加/减、长按连发、无障碍标签。
                //
                // ⚠️ Picker **不放进 Stepper 的 label 里** —— 那会变成嵌套交互控件，
                // segmented 的点击可能被 Stepper 吞掉。两者平铺在一行。
                Stepper(value: $notifyLeadAmount, in: 0...999, step: 1) {
                    Text("提前 \(Int(notifyLeadAmount))")
                        .monospacedDigit()
                }
                Picker("", selection: $notifyLeadUnit) {
                    ForEach(LifeUnit.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 130)
            }
            // 只在「天」这一档才需要换算：单位已经是小时时，这行跟上面的输入框
            // 一个字都不差，属于纯噪音。
            if notifyLeadUnit == .days {
                Text("= \(Int(notifyLeadHours.rounded())) 小时")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // 提前量为 0 = 这一台的色彩预警被关掉了。
            // 必须明说：否则用户看到「0 小时」只会以为是「不重要」，
            // 而它的实际含义是「永远不会变黄」（P10 ≤ 0 才算黄，那时已经耗尽了）。
            if notifyLeadHours <= 0 {
                Label("提前量为 0 —— 这个物品不会有黄色提醒，只在已耗尽时变红。",
                      systemImage: "bell.slash")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if notifyLeadHours > 0, notifyLeadHours >= lifeHours {
                Label("提醒提前量已经不小于电池寿命了 —— 这个物品会一直显示为黄色。"
                      + "短命电池（几小时到几天）建议用小时作单位。",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("提前多久提醒")
        } footer: {
            Text("只影响颜色，不参与「还剩多久」的计算。距风险窗口（最坏情况）不足这个提前量时，"
                 + "主页和小组件会变黄。")
        }
    }

    /// 用户填的「大概寿命」换算成小时 —— 模型的唯一单位。
    private var lifeHours: Double {
        max(lifeAmount, 1) * lifeUnit.hoursPerUnit
    }

    /// 提前量换算成小时 —— 模型的唯一单位。
    private var notifyLeadHours: Double {
        max(notifyLeadAmount, 0) * notifyLeadUnit.hoursPerUnit
    }

    private var deleteSection: some View {
        Section {
            Button("删除这个物品", role: .destructive) {
                showingDeleteConfirm = true
            }
        } footer: {
            Text("会先进回收站，\(Int(Device.trashRetentionDays)) 天内能捞回来。")
        }
    }

    // MARK: - 文案

    /// 「另一个单位」下的数值，**故意不带 `≈`** —— 符号由调用方的 `Text` 加。
    ///
    /// ⚠️ 曾经两边各写了一个 `≈`，于是页面上真的显示成 `≈ ≈ 3.0 天`。
    /// 这种重复我的机械检查器一概查不出来（全是合法文本），只能靠眼睛看。
    /// 所以符号**只留一处**，这里只管数字和单位。
    private var otherUnitText: String {
        let total = max(lifeAmount, 1) * lifeUnit.hoursPerUnit
        // 要的是**另一个单位的原始数字**，所以不能用 `DurationText` ——
        // 它会按量级重新挑单位（填 30 天 → 提示又叫你「约 30 天」，等于没说）。
        switch lifeUnit {
        case .hours: return "\(number(total / 24)) 天"
        case .days: return "\(number(total)) 小时"
        }
    }

    /// 小于 10 时留一位小数 —— 填「4 小时」提示「≈ 0 天」等于没说，
    /// 提示「≈ 0.2 天」才有信息量。
    private func number(_ value: Double) -> String {
        String(format: value < 10 ? "%.1f" : "%.0f", value)
    }

    private func auditNote(_ audit: IntervalAudit) -> String {
        let span = DurationText.short(audit.hours)
        switch audit.reason {
        case .sample:
            return "这一颗用了 \(span)"
        case .tooShort:
            return "只有 \(span)，短于下限 \(DurationText.short(audit.floorHours))，不计入寿命统计"
        case .censored:
            return "\(span) · 不是自然耗尽，不计入寿命统计"
        }
    }

    private func auditIcon(_ audit: IntervalAudit) -> String {
        audit.counted ? "clock" : "exclamationmark.triangle"
    }

    private func auditTint(_ audit: IntervalAudit) -> Color {
        guard !audit.counted else { return .secondary }
        return audit.reason == .tooShort ? .orange : .secondary
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && lifeAmount > 0
    }

    // MARK: - 数据

    /// 按 id 取绑定：列表按排序后的顺序渲染，而底下的 `rows` 是插入顺序，
    /// 所以要靠 id 才对得上号。
    private func binding(for id: UUID) -> Binding<EventDraft> {
        Binding(
            get: { rows.first { $0.id == id } ?? EventDraft(at: Self.now, kind: .exhausted) },
            set: { newValue in
                guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
                rows[index] = newValue
            }
        )
    }

    private func deleteRows(at offsets: IndexSet) {
        guard orderedRows.count > 1 else { return }   // 至少要留一条，否则时间线没有起点
        let anchorID = orderedRows.first?.id
        let doomed = offsets
            .map { orderedRows[$0].id }
            // 双保险：`.deleteDisabled` 已经让起点行滑不出删除按钮，
            // 这里再挡一次 —— UI 实现换了，基准点也不该被删掉。
            .filter { $0 != anchorID }
        rows.removeAll { doomed.contains($0.id) }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let id = editingID, let device = appModel.device(withID: id) else {
            rows = [EventDraft(at: Self.now, kind: .initial)]
            // 新增：进页面就准备接收输入。
            // 稍等一下再置焦点 —— 刚 onAppear 时输入框还没进视图层级，直接设会失效。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { nameFocused = true }
            return
        }
        name = device.name
        referencePrior = device.referencePrior
        // 一律按**小时**回填，不做「能整除 24 就改成天」的自动换算。
        //
        // 试过自动换算，结论是设计过度：填 72 小时，下次打开变成 3 天 ——
        // 数字没变，但用户得重新脑补一遍「我当初填的到底是哪个」。
        // 单位是他自己选的，就别背着他动。想换量级自己切一下切换器，
        // 下面那行提示也会给出对应换算值。
        lifeUnit = .hours
        lifeAmount = device.nominalLifeHours
        notifyLeadUnit = .hours
        // 四舍五入到整数：`Stepper(step: 1)` 遇到 1.5 会加出 2.5、3.5，
        // 而显示用的是 `Int(...)`，会看到「2 → 3 → 3」这种鬼现象。
        //
        // ⚠️ 但 `rounded()` 会把 0 < lead < 0.5 压成 **0**，而 0 的含义是
        // 「关闭黄色预警」。打开一次编辑页再保存，预警就静默没了。
        // 这种精度在界面上本来就表达不出来（步进是整小时），
        // 宁可显示 1 也别显示 0 —— 显示 0 会顺手关掉一个功能。
        let rounded = device.notifyLeadHours.rounded()
        notifyLeadAmount = (device.notifyLeadHours > 0 && rounded == 0) ? 1 : rounded
        rows = device.sortedEvents.map { EventDraft(at: $0.at, kind: $0.kind) }
        if rows.isEmpty { rows = [EventDraft(at: Self.now, kind: .initial)] }
    }

    private func draftDevice(name draftName: String) -> Device {
        var ordered = orderedRows
        if ordered.isEmpty { ordered = [EventDraft(at: Self.now, kind: .initial)] }
        // 最旧那条只标记时间线的起点：在它之前这颗电池何时装上，我们不知道，
        // 所以强制 `.initial` —— 它后面那段间隔不能当寿命样本。
        ordered[0].kind = .initial

        return Device(
            id: editingID ?? UUID(),
            name: draftName,
            nominalLifeHours: lifeHours,
            events: ordered.map { ReplacementEvent(at: $0.at, kind: $0.kind) },
            notifyLeadHours: notifyLeadHours,
            referencePrior: referencePrior
        )
    }

    private func save() {
        let device = draftDevice(name: name.trimmingCharacters(in: .whitespaces))
        if isEditing {
            appModel.update(device)
        } else {
            appModel.add(device)
        }
        dismiss()
    }
}
