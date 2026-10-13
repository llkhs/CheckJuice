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

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.ranked) { item in
                    DeviceRow(item: item)
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
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAdd = true
                    } label: {
                        Label("添加", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAdd) {
                AddDeviceView { name, kind, date, lead in
                    model.add(name: name, kind: kind, installedAt: date, notifyLeadDays: lead)
                }
            }
        }
    }
}

struct DeviceRow: View {
    let item: RankedDevice

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
                Text(item.prediction.shortDescription)
                    .font(.title3)
                    .monospacedDigit()
                    .fontWeight(.semibold)
                Text(item.prediction.urgency.displayName)
                    .font(.caption)
                    .foregroundStyle(item.prediction.urgency.tint)
            }
        }
        .padding(.vertical, 2)
    }
}

struct AddDeviceView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var kind: BatteryKind = .cr2032
    @State private var installedAt = Date()
    @State private var notifyLeadDays = 14

    let onAdd: (String, BatteryKind, Date, Int) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("这是什么") {
                    TextField("名称，例如「大门门锁」", text: $name)
                    Picker("电池类型", selection: $kind) {
                        ForEach(BatteryKind.allCases, id: \.self) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                }
                Section("计时起点") {
                    DatePicker("本次装上电池的日期", selection: $installedAt, displayedComponents: .date)
                    Stepper("提前 \(notifyLeadDays) 天提醒", value: $notifyLeadDays, in: 1...180)
                }
                Section {
                    Text("第 1 颗电池没有历史数据，预测基于「\(kind.displayName)」的典型寿命，误差较大。等它耗尽、你记下一次更换之后，预测会明显变准。")
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
                        onAdd(name.isEmpty ? "未命名" : name, kind, installedAt, notifyLeadDays)
                        dismiss()
                    }
                }
            }
        }
    }
}
