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

    private var isEditing: Bool { editingID != nil }

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
    }

    // MARK: - 各段

    private var identitySection: some View {
        Section("这是什么") {
            TextField("例如：温湿度计", text: $name)
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
        let isAnchor: Bool
        let audit: IntervalAudit?
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
                isAnchor: draft.id == anchorID,
                audit: draft.id == anchorID ? nil : auditsByEnd[draft.at]
            )
        }
    }

    private var eventSection: some View {
        Section {
            ForEach(rowModels) { eventRow($0) }
                .onDelete(perform: deleteRows)

            Button {
                rows.append(EventDraft(at: Date(), kind: .exhausted))
            } label: {
                Label("加一条记录", systemImage: "plus.circle")
            }
        } header: {
            Text("更换记录")
        } footer: {
            Text(isEditing
                 ? "记不清确切日期也没关系，先填个大概。最早那条只是时间线的起点。"
                 : "已经换过几次？把它们补进来，预测就不用从零学起。")
        }
    }

    @ViewBuilder
    private func eventRow(_ row: Row) -> some View {
        let draft = binding(for: row.id)
        let isAnchor = row.isAnchor
        let audit = row.audit

        VStack(alignment: .leading, spacing: 6) {
            if isAnchor {
                Text("上次换电池的时刻 · 从这儿开始算")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Picker("上一颗怎么结束的", selection: draft.kind) {
                    ForEach([EventKind.exhausted, .preventive, .faulty], id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            DatePicker("", selection: draft.at,
                       displayedComponents: [.date, .hourAndMinute])
                .labelsHidden()

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

    private var notifySection: some View {
        Section {
            HStack {
                TextField("提前", value: $notifyLeadAmount, format: .number)
                    .keyboardType(.decimalPad)
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
            if notifyLeadHours >= lifeHours {
                Label("提醒提前量已经不小于电池寿命了 —— 这个物品会一直处于「该备货」状态。"
                      + "短命电池（几小时到几天）建议用小时作单位。",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("提前多久提醒")
        } footer: {
            Text("留出下单 / 出门采购的时间。距风险窗口（最坏情况）不足这个提前量时，"
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
            get: { rows.first { $0.id == id } ?? EventDraft(at: Date(), kind: .exhausted) },
            set: { newValue in
                guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
                rows[index] = newValue
            }
        )
    }

    private func deleteRows(at offsets: IndexSet) {
        guard orderedRows.count > 1 else { return }   // 至少要留一条，否则时间线没有起点
        let doomed = offsets.map { orderedRows[$0].id }
        rows.removeAll { doomed.contains($0.id) }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let id = editingID, let device = appModel.device(withID: id) else {
            rows = [EventDraft(at: Date(), kind: .initial)]
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
        notifyLeadAmount = device.notifyLeadHours
        rows = device.sortedEvents.map { EventDraft(at: $0.at, kind: $0.kind) }
        if rows.isEmpty { rows = [EventDraft(at: Date(), kind: .initial)] }
    }

    private func draftDevice(name draftName: String) -> Device {
        var ordered = orderedRows
        if ordered.isEmpty { ordered = [EventDraft(at: Date(), kind: .initial)] }
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
