import CableKit
import AppKit
import SwiftUI

/// IOKit 属性检查器：按类名枚举 IORegistry 条目，展示/搜索/复制全量属性。
///
/// 数据来自 `RegistryService`（每次全量重查）；类名可从常用清单选择，也可
/// 手动输入任意 IOKit 类名。可见期间每 3 秒自动刷新，与 App 其余部分的
/// 实时监控体验一致。
struct RegistryInspectorView: View {
    /// 自动刷新间隔（秒）。
    static let refreshIntervalNanos: UInt64 = 3_000_000_000

    // MARK: 状态

    @State private var className = RegistryService.wellKnownClasses[0].className
    /// 输入框草稿：与 className 分离，避免每敲一个字符触发一次 IORegistry 枚举。
    @State private var classDraft = RegistryService.wellKnownClasses[0].className
    @State private var entries: [RegistryEntrySnapshot] = []
    @State private var selectedEntryID: UInt64?
    @State private var searchText = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    /// 拷贝成功反馈：按钮短暂显示"已拷贝"（HIG：操作应有可见确认）。
    @State private var showCopyConfirmation = false

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .frame(minWidth: 760, minHeight: 480)
        .navigationTitle("IOKit 属性检查器")
        // HIG：条目/属性较多的窗口应提供搜索（过滤侧栏条目与右侧属性键值）。
        .searchable(text: $searchText, placement: .sidebar, prompt: "搜索条目与属性键值")
        .task(id: className) {
            await refreshLoop()
        }
    }

    // MARK: - 侧栏：类选择 + 条目列表

    private var sidebar: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Picker("类名", selection: $className) {
                    ForEach(RegistryService.wellKnownClasses, id: \.className) { item in
                        Text("\(item.label) · \(item.className)").tag(item.className)
                    }
                }
                .labelsHidden()
                .onChange(of: className) {
                    classDraft = className
                }

                TextField("输入任意 IOKit 类名后回车，如 AppleHPM", text: $classDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout)
                    .onSubmit {
                        let trimmed = classDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        classDraft = trimmed
                        className = trimmed
                    }
            }
            .padding(10)

            Divider()

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .padding(10)
            }

            entryList
        }
        .navigationSplitViewColumnWidth(min: 240, ideal: 280)
    }

    @ViewBuilder
    private var entryList: some View {
        let filtered = filteredEntries
        List(selection: $selectedEntryID) {
            ForEach(filtered) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.displayTitle)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text(entry.disambiguatingSubtitle.map { "\(entry.className) · \($0)" }
                         ?? "\(entry.className) · #\(entry.registryID)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .tag(entry.id)
            }
        }
        .overlay {
            if filtered.isEmpty && !isLoading {
                EmptyHint(text: errorMessage ?? "该类名下没有 registry 条目")
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: - 详情：属性树

    @ViewBuilder
    private var detail: some View {
        let entry = selectedEntry
        if let entry {
            VStack(spacing: 0) {
                detailHeader(entry)

                Divider()

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(filteredProperties(of: entry)).sorted(by: { $0.key < $1.key }),
                                id: \.key) { key, value in
                            PropertyRow(key: key, value: value)
                            Divider()
                                .padding(.leading, 12)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        } else {
            EmptyHint(text: entries.isEmpty ? "等待枚举结果…" : "在左侧选择一个条目")
        }
    }

    private func detailHeader(_ entry: RegistryEntrySnapshot) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayTitle)
                    .font(.headline)
                Text("类 \(entry.className) · registryID \(entry.registryID) · \(entry.properties.count) 个属性")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            if isLoading {
                ProgressView()
                    .controlSize(.small)
            }
            Button {
                copyToPasteboard(entry: entry)
                showCopyConfirmation = true
                Task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    showCopyConfirmation = false
                }
            } label: {
                Label(showCopyConfirmation ? "已拷贝" : "拷贝全部",
                      systemImage: showCopyConfirmation ? "checkmark" : "doc.on.doc")
            }
            .disabled(isLoading)
        }
        .padding(12)
    }

    // MARK: - 搜索过滤

    private var filteredEntries: [RegistryEntrySnapshot] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return entries }
        return entries.filter { entry in
            if entry.displayTitle.lowercased().contains(query) { return true }
            if String(entry.registryID).contains(query) { return true }
            return !filteredProperties(of: entry).isEmpty
        }
    }

    /// 搜索命中：键名或渲染后的值文本包含查询词；无查询时返回全量。
    private func filteredProperties(of entry: RegistryEntrySnapshot) -> [String: IORegistryValue] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return entry.properties }
        return entry.properties.filter { key, value in
            key.lowercased().contains(query) || value.displayText.lowercased().contains(query)
        }
    }

    // MARK: - 采集

    private var selectedEntry: RegistryEntrySnapshot? {
        guard let selectedEntryID else { return nil }
        return entries.first { $0.registryID == selectedEntryID }
    }

    /// 可见期间轮询刷新；类名变化时 task(id:) 会重启循环。
    private func refreshLoop() async {
        let targetClass = className
        while !Task.isCancelled {
            await fetchOnce(class: targetClass)
            do {
                try await Task.sleep(nanoseconds: Self.refreshIntervalNanos)
            } catch {
                break // 取消：退出轮询
            }
        }
    }

    private func fetchOnce(class targetClass: String) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let fresh = try await RegistryService().listEntries(matchingClass: targetClass)
            entries = fresh
            errorMessage = nil
            // 选中项优先保留（仍存在时）；否则自动选第一条。
            if selectedEntryID == nil || !fresh.contains(where: { $0.registryID == selectedEntryID }) {
                selectedEntryID = fresh.first?.registryID
            }
        } catch {
            errorMessage = "枚举失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 拷贝

    private func copyToPasteboard(entry: RegistryEntrySnapshot) {
        var text = "# \(entry.displayTitle)  [\(entry.className) · registryID \(entry.registryID)]\n"
        text += RegistryText.render(entry.properties).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - 单个属性行（嵌套字典/数组可展开）

private struct PropertyRow: View {
    let key: String
    let value: IORegistryValue

    @State private var isExpanded = true

    var body: some View {
        switch value {
        case .dictionary(let dict) where !dict.isEmpty:
            disclosure {
                ForEach(IORegistryValue.sortedKeys(in: dict), id: \.self) { childKey in
                    PropertyRow(key: childKey, value: dict[childKey] ?? .other(""))
                }
            }
        case .array(let items) where !items.isEmpty:
            disclosure {
                ForEach(items.indices, id: \.self) { index in
                    PropertyRow(key: "[\(index)]", value: items[index])
                }
            }
        default:
            HStack(alignment: .top, spacing: 12) {
                Text(key)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 200, maxWidth: 320, alignment: .leading)
                    .textSelection(.enabled)
                Text(value.displayText)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
    }

    private func labelView() -> some View {
        HStack(spacing: 8) {
            Text(key)
                .font(.callout.weight(.medium))
                .foregroundStyle(.primary)
            Text("(\(value.displayText))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(minWidth: 200, maxWidth: 320, alignment: .leading)
    }

    private func disclosure(@ViewBuilder children: @escaping () -> some View) -> some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            children()
                .padding(.leading, 16)
        } label: {
            labelView()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}
