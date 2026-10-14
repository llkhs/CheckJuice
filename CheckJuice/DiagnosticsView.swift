import SwiftUI
import UIKit
import CheckJuiceCore
import CheckJuiceStore

/// 诊断页。
///
/// 存在理由就一个词：**静默失败**。App Group 对不上、容器拿不到、快照没写出去 ——
/// 这些**全都不报错**，只表现为「小组件空着」「重启后物品没了」。
/// 与其让人猜，不如把系统那边的原话摊开：哪条路径、在不在、里面几个东西。
struct DiagnosticsView: View {
    @Environment(AppModel.self) private var model
    @State private var copied = false

    var body: some View {
        List {
            containerSection
            storageSection
            snapshotSection
            profileSection
            copySection
        }
        .navigationTitle("诊断")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - 共享容器

    private var containerSection: some View {
        Section {
            LabeledContent("标识符", value: AppGroup.identifier)
            HStack {
                Text("状态")
                Spacer()
                if AppGroup.containerURL == nil {
                    Label("拿不到", systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                } else {
                    Label("可用", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                }
            }
            if let url = AppGroup.containerURL {
                Text(url.path)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        } header: {
            Text("共享容器")
        } footer: {
            if AppGroup.containerURL == nil {
                Text("拿不到共享容器 = App 和小组件不在同一块地方读写。"
                     + "后果有两个，都不报错：物品不会真正存下来（重启就没了），"
                     + "小组件永远显示「还没有物品」。\n"
                     + "多半是重签名用的描述文件里没有这个 App Group。")
                    .foregroundStyle(.red)
            } else {
                Text("App 和小组件共用这块目录。")
            }
        }
    }

    // MARK: - 落盘

    private var storageSection: some View {
        Section {
            LabeledContent("内存里", value: "\(model.devices.count) 台")
            LabeledContent("磁盘上", value: "\(storedDeviceCount) 台")
        } header: {
            Text("物品清单 devices.json")
        } footer: {
            if storedDeviceCount < model.devices.count {
                Text("磁盘上比内存里少 —— 内存里加的东西没写下去，重启就没了。")
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - 快照

    private var snapshotSection: some View {
        Section {
            LabeledContent("设备数", value: "\(snapshot.devices.count)")
            if snapshot.generatedAt == .distantPast {
                LabeledContent("生成时间", value: "从未生成")
            } else {
                LabeledContent("生成时间", value: snapshot.generatedAt.formatted())
            }
        } header: {
            Text("小组件读的快照")
        } footer: {
            Text("小组件不会自己算，只读这份文件。它是空的，小组件就是空的。")
        }
    }

    // MARK: - 描述文件

    private var profileSection: some View {
        Section {
            profileRows(title: "主 App", groups: appProfileGroups)
            profileRows(title: "小组件", groups: widgetProfileGroups)
        } header: {
            Text("描述文件里声明的 App Group")
        } footer: {
            Text("重签名后真正生效的是这里列出的东西，不是项目里写的。"
                 + "两边必须逐字符相同。")
        }
    }

    @ViewBuilder
    private func profileRows(title: String, groups: [String]?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline)
            switch groups {
            case .none:
                Text("读不出（没有这个文件，或不是 plist）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .some(let list) where list.isEmpty:
                Text("声明了，但一个都没有")
                    .font(.caption)
                    .foregroundStyle(.red)
            case .some(let list):
                ForEach(list, id: \.self) { group in
                    HStack(spacing: 4) {
                        Image(systemName: group == AppGroup.identifier
                              ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(group == AppGroup.identifier
                                             ? Color.green : Color.secondary)
                        Text(group).font(.caption).monospaced()
                    }
                }
            }
        }
    }

    // MARK: - 复制

    private var copySection: some View {
        Section {
            Button(copied ? "已复制" : "复制诊断信息") {
                UIPasteboard.general.string = report
                copied = true
            }
        }
    }

    // MARK: - 取值

    private var storedDeviceCount: Int { DeviceStore().load().count }
    private var snapshot: WidgetSnapshot { SnapshotStore().load() }
    private var appProfileGroups: [String]? { appProfileURL.flatMap(ProvisioningProfile.appGroups(at:)) }
    private var widgetProfileGroups: [String]? { widgetProfileURL.flatMap(ProvisioningProfile.appGroups(at:)) }

    private var appProfileURL: URL? {
        Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision")
    }

    private var widgetProfileURL: URL? {
        guard let plugins = Bundle.main.builtInPlugInsURL,
              let items = try? FileManager.default.contentsOfDirectory(at: plugins,
                                                                       includingPropertiesForKeys: nil)
        else { return nil }
        return items.first { $0.pathExtension == "appex" }?
            .appendingPathComponent("embedded.mobileprovision")
    }

    private func describe(_ groups: [String]?) -> String {
        switch groups {
        case .none: return "读不出"
        case .some(let list) where list.isEmpty: return "空"
        case .some(let list): return list.joined(separator: ", ")
        }
    }

    private var report: String {
        """
        Check Juice 诊断
        标识符: \(AppGroup.identifier)
        容器: \(AppGroup.containerURL?.path ?? "拿不到")
        内存/磁盘: \(model.devices.count) / \(storedDeviceCount)
        快照: \(snapshot.devices.count) 台 @ \(snapshot.generatedAt)
        主 App 描述文件: \(describe(appProfileGroups))
        小组件描述文件: \(describe(widgetProfileGroups))
        """
    }
}
