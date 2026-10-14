import SwiftUI
import CheckJuiceCore

/// 主页滑动「已换电池」后弹的小表单。
///
/// 与旧版的关键差别是**让用户填时刻**：外面换完电池，往往是回屋坐下才想起来记。
/// 旧版是个只有一个「自然耗尽」按钮的确认框，一律按「此刻」记账 ——
/// 于是「添加物品后两分钟点一下」就能把 100 天的寿命估计打成 39 分钟。
struct RecordReplacementView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    let deviceID: UUID

    @State private var at = Date()
    @State private var kind: EventKind = .exhausted

    private var device: Device? { appModel.device(withID: deviceID) }

    /// 用**真实的审计函数**预演一次：编辑页、模型、这里用的是同一套判据，
    /// 不另抄一份阈值（抄一份就等着哪天两边不一致）。
    private var preview: IntervalAudit? {
        guard let device else { return nil }
        var draft = device
        draft.events.append(ReplacementEvent(at: at, kind: kind))
        return LifetimeModel.auditIntervals(for: draft).last
    }

    private var tooShortWarning: String? {
        guard let preview, preview.reason == .tooShort else { return nil }
        return "距上次更换只有 \(DurationText.short(preview.hours))，"
             + "短于下限 \(DurationText.short(preview.floorHours))，不会计入寿命统计。"
             + "时刻是不是填错了？"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("新电池装上的时刻", selection: $at,
                               displayedComponents: [.date, .hourAndMinute])
                } header: {
                    Text("什么时候换的")
                } footer: {
                    Text(device.map { "「\($0.name)」从这一刻重新计时。" } ?? "")
                }

                Section {
                    Picker("", selection: $kind) {
                        ForEach([EventKind.exhausted, .preventive, .faulty], id: \.self) {
                            Text($0.displayName).tag($0)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("上一颗是怎么结束的")
                } footer: {
                    Text("只有「自然耗尽」才算一次真实寿命样本。"
                         + "提前更换（怕漏电先换了）和故障都不该拿来当寿命证据，"
                         + "否则模型会以为电池越来越不经用。")
                }

                if let text = tooShortWarning {
                    Section {
                        Label(text, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("记一次更换")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("记录") {
                        if let device { appModel.markReplaced(device, at: at, kind: kind) }
                        dismiss()
                    }
                }
            }
        }
    }
}
