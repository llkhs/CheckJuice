import SwiftUI
import CheckJuiceCore

/// 紧急度 → 颜色。放在 App 层，因为 `Color` 是 SwiftUI 的东西，
/// Core 包要保持零 UI 依赖。
extension Urgency {
    var tint: Color {
        switch self {
        case .overdue: return .red
        case .risk: return .orange
        case .stockUp: return .yellow
        case .normal: return .green
        }
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var showingAdd = false
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.ranked) { item in
                    DeviceRow(
                        item: item,
                        style: model.displayStyle,
                        showMedian: model.showMedianSubline
                    )
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                model.delete(item.device)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            Button {
                                model.markReplaced(item.device)
                            } label: {
                                Label("已换电池", systemImage: "arrow.triangle.2.circlepath")
                            }
                            .tint(.blue)
                        }
                }
            }
            .overlay {
                if model.ranked.isEmpty {
                    ContentUnavailableView(
                        "还没有物品",
                        systemImage: "battery.100",
                        description: Text("点右上角 + 添加第一个要盯电池的东西")
                    )
                }
            }
            .navigationTitle("Check Juice")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingSettings = true
                    } label: {
                        Label("设置", systemImage: "gearshape")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAdd = true
                    } label: {
                        Label("添加", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAdd) {
                AddDeviceView { device in model.add(device) }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView(
                    style: model.displayStyle,
                    showMedianSubline: model.showMedianSubline,
                    onStyleChange: { model.setDisplayStyle($0) },
                    onShowMedianChange: { model.setShowMedianSubline($0) }
                )
            }
        }
    }
}

struct DeviceRow: View {
    let item: RankedDevice
    let style: ExhaustDisplayStyle
    /// 是否显示中位小字。主文案报最坏情况（P10），这行报中位。
    let showMedian: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.prediction.urgency.symbolName)
                .font(.title2)
                .foregroundStyle(item.prediction.urgency.tint)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.device.name)
                    .font(.headline)
                Text(item.device.kind.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text(item.prediction.remainingText(style: style))
                    .font(.title3)
                    .monospacedDigit()
                    .fontWeight(.semibold)
                if showMedian {
                    Text(item.prediction.medianText(style: style))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// 「大概能用多久」的输入单位。
///
/// 让人填「1095 小时」是耍流氓，填「1095 天」也够呛。给天和月两个量级就够——
/// 一个月按 30 天算，跟显示层（`Prediction.adaptiveHours`）用同一个常数。
enum LifeUnit: String, CaseIterable, Identifiable {
    case days = "天"
    case months = "个月"
    var id: String { rawValue }
    var hours: Double { self == .days ? 24 : 720 }
}

struct AddDeviceView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""

    /// 用户填的「大概能用多久」—— 模型唯一的冷启动先验。
    @State private var lifeAmount = 30.0
    @State private var lifeUnit: LifeUnit = .days

    /// 装上这颗电池的**时刻**，不是日期。默认「现在」—— 用户通常是刚换完才来记一笔。
    /// 精确到分钟是有意义的：一块撑 4 天的纽扣电池，早上 8 点装和晚上 8 点装上，
    /// 差出来的 12 小时是它总寿命的八分之一。
    @State private var installedAt = Date()

    /// 可留空：这一颗**也已经换掉了**的时刻。
    /// 填上它，模型立刻拿到一个真实寿命区间，而不是只靠你拍脑袋的估计值。
    @State private var hasNextReplacement = false
    @State private var nextReplacementAt = Date()

    /// 提前多久提醒备货。UI 用「天」（人脑里想的是「提前两周」），提交时换算成小时。
    @State private var notifyLeadDays = 14

    let onAdd: (Device) -> Void

    private var nominalLifeHours: Double { lifeAmount * lifeUnit.hours }

    private var canSubmit: Bool { lifeAmount > 0 }

    var body: some View {
        NavigationStack {
            Form {
                Section("这是什么") {
                    TextField("名称，例如「大门门锁」", text: $name)
                }

                Section("电池能撑多久") {
                    HStack {
                        TextField("大概", value: $lifeAmount, format: .number)
                            .keyboardType(.decimalPad)
                        Picker("单位", selection: $lifeUnit) {
                            ForEach(LifeUnit.allCases) { unit in
                                Text(unit.rawValue).tag(unit)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 140)
                    }
                    if nominalLifeHours > 0 {
                        Text("≈ \(Int(nominalLifeHours.rounded())) 小时")
                            .font(.footnote)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }

                Section("计时起点") {
                    DatePicker(
                        "本次装上电池的时刻",
                        selection: $installedAt,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                }

                Section("下一次更换（可留空）") {
                    Toggle("这一颗也已经换掉了", isOn: $hasNextReplacement)
                    if hasNextReplacement {
                        DatePicker(
                            "换上的时刻",
                            selection: $nextReplacementAt,
                            in: installedAt...,
                            displayedComponents: [.date, .hourAndMinute]
                        )
                    }
                }

                Section("提醒") {
                    Stepper("提前 \(notifyLeadDays) 天提醒", value: $notifyLeadDays, in: 1...180)
                }

                Section {
                    Text("第 1 颗电池没有实测数据，预测只能靠你填的「大概寿命」撑场面，"
                         + "最坏情况可能只有你估值的四成。等它耗尽、你记下一次更换之后，预测会明显变准。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("添加物品")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加") {
                        onAdd(buildDevice())
                        dismiss()
                    }
                    .disabled(!canSubmit)
                }
            }
        }
    }

    private func buildDevice() -> Device {
        var events = [ReplacementEvent(at: installedAt, kind: .initial)]
        // 留空 = 这一颗还在用。填了才算一个已结束的周期。
        if hasNextReplacement, nextReplacementAt > installedAt {
            events.append(ReplacementEvent(at: nextReplacementAt, kind: .exhausted))
        }
        return Device(
            name: name.isEmpty ? "未命名" : name,
            nominalLifeHours: nominalLifeHours,
            events: events,
            notifyLeadHours: Double(notifyLeadDays) * 24.0
        )
    }
}
