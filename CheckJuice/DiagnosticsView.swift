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
            containerScanSection
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
            LabeledContent("项目声明的", value: AppGroup.identifier)
            LabeledContent("实际生效的",
                           value: AppGroup.resolvedIdentifier ?? "无 —— 一个都没拿到容器")
            if let url = AppGroup.containerURL {
                Text(url.path)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            probeRows
        } header: {
            Text("共享容器")
        } footer: {
            Text("重签名工具会把它自己那套 App Group 写进二进制，项目里声明的那个多半被换掉。"
                 + "所以这里按「本进程 entitlements 里的组」逐个探测，取第一个真的能拿到容器的。"
                 + "App 和小组件各自探测，但顺序是确定的，所以两边会选中同一个。")
        }
    }

    /// 逐个候选报三件事：在 entitlements 里吗、能拿到容器吗、**真能写入吗**。
    /// 能拿到容器 ≠ 能写 —— 少写一个探针，下次又得靠猜。
    private var probeRows: some View {
        ForEach(AppGroup.candidates, id: \.self) { id in
            let probe = Probe(id: id)
            VStack(alignment: .leading, spacing: 4) {
                Text(id).font(.caption).monospaced()
                HStack(spacing: 6) {
                    badge(probe.inEntitlements ? "已授予" : "未授予",
                          ok: probe.inEntitlements)
                    badge(probe.container != nil ? "有容器" : "无容器",
                          ok: probe.container != nil)
                    badge(probe.writable ? "可写" : "不可写", ok: probe.writable)
                }
                if let error = probe.error {
                    Text(error).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func badge(_ text: String, ok: Bool) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background((ok ? Color.green : Color.secondary).opacity(0.18),
                        in: Capsule())
            .foregroundStyle(ok ? Color.green : Color.secondary)
    }

    /// 一次探测的结果。
    private struct Probe {
        let id: String
        let inEntitlements: Bool
        let container: URL?
        let writable: Bool
        let error: String?

        init(id: String) {
            self.id = id
            self.inEntitlements = AppGroup.entitledGroups.contains(id)
            let url = FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier: id)
            self.container = url
            guard let url else {
                self.writable = false
                self.error = nil
                return
            }
            // 真写一遍再删掉 —— 容器能创建不等于进程有权写。
            let probeFile = url.appendingPathComponent(".probe")
            do {
                try Data("probe".utf8).write(to: probeFile)
                try? FileManager.default.removeItem(at: probeFile)
                self.writable = true
                self.error = nil
            } catch {
                self.writable = false
                self.error = error.localizedDescription
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

    /// 挨个候选组的容器翻一遍，看谁在里面放了东西。
    ///
    /// 这是「小组件为什么空着」的**决定性证据**：如果纸条出现在别的组里，
    /// 那就说明两个进程解析到了不同的容器 —— 硬编码标识符这条路已经走不通了。
    private var containerScanSection: some View {
        Section {
            ForEach(AppGroup.candidates, id: \.self) { id in
                VStack(alignment: .leading, spacing: 4) {
                    Text(id).font(.caption).monospaced()
                    let files = filesInGroup(id)
                    if files.isEmpty {
                        Text("（空的）").font(.caption2).foregroundStyle(.secondary)
                    } else {
                        ForEach(files, id: \.self) { line in
                            Text(line).font(.caption2).monospaced()
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("各候选组容器里有什么")
        } footer: {
            Text("每个候选组挨个翻一遍。小组件每次刷新都会在自己解析到的容器里留下 "
                 + "\(WidgetEnv.fileName) —— 它在哪个组里出现，就是它实际在看哪个容器。")
        }
    }

    /// 某个组容器里的关键文件及大小，外加**谁在用它**的解读。
    /// 容器不存在就返回空。
    private func filesInGroup(_ id: String) -> [String] {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: id) else { return [] }
        var lines: [String] = []
        let names = ["devices.json", "widget_snapshot.json", WidgetEnv.fileName]
        for name in names {
            let path = container.appendingPathComponent(name).path
            guard let size = try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int
            else { continue }
            lines.append("\(name) · \(size) 字节")
        }
        if let env = WidgetEnv.read(from: container) {
            lines.append("↳ 最后写纸条的是「\(env.process)」，它认为自己在："
                         + (env.resolvedGroup ?? "（没拿到容器）"))
        }
        let snapshot = SnapshotStore(fileURL: container
            .appendingPathComponent("widget_snapshot.json")).load()
        if let writer = snapshot.groupId {
            lines.append("↳ 这份快照是写在「\(writer)」里的")
        }
        return lines
    }

    private var profileSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text("本进程 entitlements（系统真正校验的）").font(.subheadline)
                Text(AppGroup.entitledGroups.isEmpty
                     ? "空 —— 系统认为这个 App 没有任何 App Group"
                     : AppGroup.entitledGroups.joined(separator: ", "))
                    .font(.caption).monospaced()
                    .foregroundStyle(AppGroup.entitledGroups.isEmpty ? .red : .primary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("主 App 描述文件").font(.subheadline)
                Text(appProfileReport).font(.caption).monospaced()
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("小组件描述文件").font(.subheadline)
                Text(widgetProfileReport).font(.caption).monospaced()
            }
        } header: {
            Text("App Group 来源")
        } footer: {
            Text("上面第一行才是系统在 containerURL 里校验的东西 —— "
                 + "描述文件只是它的来源。重签名后项目里写的标识符会被换掉，属于正常。")
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

    /// 描述文件报告要**分阶段**说清楚卡在哪 —— 三种情况糊成一句「读不出」，
    /// 下次还是得靠猜。它们的原因完全不同：目录结构不同 / 文件被签名工具删了 / 解析失败。
    private var appProfileReport: String {
        guard let url = Bundle.main.url(forResource: "embedded",
                                        withExtension: "mobileprovision") else {
            return "没有 embedded.mobileprovision（有些签名工具会删掉）"
        }
        guard let groups = ProvisioningProfile.appGroups(at: url) else {
            return "文件在（\(fileSize(url)) 字节），但解析不出 plist"
        }
        return groups.isEmpty ? "声明了，但一个组都没给" : groups.joined(separator: ", ")
    }

    private var widgetProfileReport: String {
        guard let plugins = Bundle.main.builtInPlugInsURL else {
            return "主 App 没有 PlugIns 目录"
        }
        guard FileManager.default.fileExists(atPath: plugins.path) else {
            return "PlugIns 目录不存在：\(plugins.path)"
        }
        let items = (try? FileManager.default.contentsOfDirectory(
            at: plugins, includingPropertiesForKeys: nil
        )) ?? []
        let appexes = items.filter { $0.pathExtension == "appex" }
        guard !appexes.isEmpty else {
            return "PlugIns 里没有 .appex（装了 \(items.count) 个东西）"
        }
        return appexes.map { appex in
            let profile = appex.appendingPathComponent("embedded.mobileprovision")
            guard FileManager.default.fileExists(atPath: profile.path) else {
                return "\(appex.lastPathComponent): 没有 embedded.mobileprovision（签名工具常删，正常）"
            }
            guard let groups = ProvisioningProfile.appGroups(at: profile) else {
                return "\(appex.lastPathComponent): 文件在，但解析不出 plist"
            }
            return "\(appex.lastPathComponent): "
                + (groups.isEmpty ? "声明了但一个都没有" : groups.joined(separator: ", "))
        }.joined(separator: "\n")
    }

    private func fileSize(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) as? Int ?? 0
    }

    private var report: String {
        var lines = [
            "Check Juice 诊断",
            "项目声明: \(AppGroup.identifier)",
            "实际生效: \(AppGroup.resolvedIdentifier ?? "无 —— 一个都没拿到容器")",
            "本进程 entitlements: \(AppGroup.entitledGroups.isEmpty ? "空" : AppGroup.entitledGroups.joined(separator: ", "))",
            "容器: \(AppGroup.containerURL?.path ?? "拿不到")",
            "内存/磁盘: \(model.devices.count) / \(storedDeviceCount)",
            "快照: \(snapshot.devices.count) 台 @ \(snapshot.generatedAt)",
            "主 App 描述文件: \(appProfileReport)",
            "小组件描述文件: \(widgetProfileReport)",
        ]
        for id in AppGroup.candidates {
            let probe = Probe(id: id)
            lines.append("探测 \(id): "
                + (probe.inEntitlements ? "已授予" : "未授予")
                + " / " + (probe.container != nil ? "有容器" : "无容器")
                + " / " + (probe.writable ? "可写" : "不可写"))
        }
        return lines.joined(separator: "\n")
    }
}
