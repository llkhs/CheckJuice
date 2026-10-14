import SwiftUI
import CheckJuiceCore

/// 设置页。
///
/// 三项：
///
/// 1. **主数字怎么显示**。这不是装饰性选项 —— 它决定用户看到的数字是
///    「几点耗尽」还是「还剩多久」，对应两种不同的决策：
///    * **耗尽时刻**：适合对着日程看 ——「周六下午 3 点耗尽，那我周六上午出门前换掉」。
///    * **剩余时长**：适合回答「撑不撑得过今天」——「还剩 9 小时，今天肯定不够」。
/// 2. **中位小字显不显示**。主文案报最坏情况（P10），小字报中位 ——
///    并排显示的价值是让人看见「最坏」和「典型」差多远。
/// 3. **诊断**。App Group 那类故障是静默的（界面正常、数据没存），
///    所以得有个地方把系统那边的原话摊开给人看。
///
/// 两种样式报的都是 **P10（最坏情况）**，不是中位数 —— 用户问的是「能不能保证不掉电」，
/// 中位数只给 50% 的把握，不够。
/// 数字一律**朝零截断**（剩余往少了说、耗尽往少了说，两个方向都不吹牛）。
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    let style: ExhaustDisplayStyle
    let showMedianSubline: Bool
    let onStyleChange: (ExhaustDisplayStyle) -> Void
    let onShowMedianChange: (Bool) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("主显示", selection: Binding(
                        get: { style },
                        set: { onStyleChange($0) }
                    )) {
                        ForEach(ExhaustDisplayStyle.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()

                    Toggle("显示中位预测小字", isOn: Binding(
                        get: { showMedianSubline },
                        set: { onShowMedianChange($0) }
                    ))
                } header: {
                    Text("主数字")
                } footer: {
                    Text(
                        """
                        主行显示的是**最坏情况**：约 10% 的可能比它更早耗尽。\
                        小字是中位预测（有一半可能比它更早）。
                        两者差得越多，越该早点换。
                        """
                    )
                }

                Section {
                    Text("小组件只显示主行 —— 它位置太小，放不下两行。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    NavigationLink("诊断") { DiagnosticsView() }
                } header: {
                    Text("排查")
                } footer: {
                    Text("物品存不下来、小组件一直空着的时候，这里能看到系统那边的原话。")
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
