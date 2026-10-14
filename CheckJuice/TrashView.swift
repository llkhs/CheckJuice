import SwiftUI
import CheckJuiceCore

/// 回收站。
///
/// **存在的理由不是「删错了能救」这么泛**：这个 App 的价值全在历史寿命样本上，
/// 而样本要几个月才攒得出来。误删一台记录了很久的设备，损失和误删照片不是一个量级 ——
/// 所以删除先过这里，15 天后才真清。
///
/// 这里**故意不给「编辑」入口**。排在回收站里的东西，用户此刻只有两个意图：
/// 要么捞回来接着用，要么确认不要了彻底删掉。让人在这里改名字、加更换记录
/// 只会把「我到底删没删」搅浑。
struct TrashView: View {
    @Environment(AppModel.self) private var model

    /// 待确认的动作。
    ///
    /// **两个动作合成一个状态，不用两个 `@State` + 两个 `.confirmationDialog`**：
    /// 在同一个视图上叠两个 `.confirmationDialog` 是有名的抽风点（谁弹出来不确定），
    /// 而这里两个确认框长得像、又都删除，真弹错了用户根本分不出来。
    private enum PendingConfirm: Identifiable {
        case purge(Device)
        case empty(count: Int)

        var id: String {
            switch self {
            case .purge(let device): return "purge-\(device.id)"
            case .empty: return "empty"
            }
        }
    }

    @State private var pendingConfirm: PendingConfirm?

    private var trashed: [Device] { model.trashedDevices }

    var body: some View {
        List {
            if trashed.isEmpty {
                Section {
                    ContentUnavailableView(
                        "回收站是空的",
                        systemImage: "trash",
                        description: Text("删掉的物品会先来这里躺 \(Int(Device.trashRetentionDays)) 天")
                    )
                }
            } else {
                Section {
                    ForEach(trashed) { device in
                        row(device)
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                Button {
                                    model.restore(id: device.id)
                                } label: {
                                    Label("恢复", systemImage: "arrow.uturn.backward")
                                }
                                .tint(.green)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    pendingConfirm = .purge(device)
                                } label: {
                                    Label("彻底删除", systemImage: "trash.slash")
                                }
                            }
                    }
                } footer: {
                    Text("左滑恢复，右滑彻底删除。也可以直接点物品名字右边的「恢复」。")
                }
            }
        }
        .navigationTitle("回收站")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !trashed.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("清空", role: .destructive) { pendingConfirm = .empty(count: trashed.count) }
                }
            }
        }
        // 用 `presenting:` 这个重载：actions/message 拿到的是**非可选**的 `item`，
        // 于是「收起动画那一帧 item 变 nil」这种边界根本不存在，也不用写空分支。
        .confirmationDialog(
            "确定要删除吗？",
            isPresented: Binding(
                get: { pendingConfirm != nil },
                set: { if !$0 { pendingConfirm = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingConfirm
        ) { item in
            switch item {
            case .purge(let device):
                Button("彻底删除", role: .destructive) { model.purge(id: device.id) }
            case .empty:
                Button("全部彻底删除", role: .destructive) { model.emptyTrash() }
            }
        } message: { item in
            switch item {
            // 具体是哪一台放进消息里说，标题保持短 —— 标题太长在窄屏会被截断。
            case .purge(let device):
                Text("「\(device.name)」连同它全部的历史更换记录一起消失，这个救不回来。")
            case .empty(let count):
                Text("\(count) 个物品会被永久删除，包括各自的历史更换记录。")
            }
        }
    }

    private func row(_ device: Device) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "trash")
                .foregroundStyle(.secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.headline)
                if let deletedAt = device.deletedAt {
                    Text("删除于 " + deletedAt.formatted(.relative(presentation: .named)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                // 天数归零说明「下次开 App 就清了」，得说清楚，别让人以为还有整天可用。
                let left = model.daysLeftInTrash(device)
                Text(left > 0 ? "还剩 \(left) 天自动清除" : "下次打开 App 时清除")
                    .font(.caption2)
                    // 两个分支必须是同一个具体类型：`.secondary` 是 HierarchicalShapeStyle，
                    // `.orange` 是 Color，三元式里混用类型推断会直接失败。
                    .foregroundStyle(left > 0 ? Color.secondary : Color.orange)
            }

            Spacer(minLength: 8)

            Button("恢复") { model.restore(id: device.id) }
                .buttonStyle(.bordered)
                .font(.caption)
        }
        .padding(.vertical, 2)
    }
}
