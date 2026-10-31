import CableKit
import AppKit
import SwiftUI

/// 全局 IORegistry 浏览器：轻量索引跨 plane 合并，选中时按需读取完整属性。
struct RegistryInspectorView: View {
    @Environment(\.locale) private var locale
    @State private var entries: [RegistryEntryIndexItem] = []
    @State private var selectedEntryID: UInt64?
    @State private var selectedEntry: RegistryEntrySnapshot?
    @State private var searchText = ""
    @State private var isLoading = false
    @State private var isDetailLoading = false
    @State private var isTruncated = false
    @State private var failedCount = 0
    @State private var failedPlanes: [String] = []
    @State private var propertySearchMatches: Set<UInt64> = []
    @State private var propertySearchFailedCount = 0
    @State private var isPropertySearchLoading = false
    @State private var propertySearchTask: Task<Void, Never>?
    @State private var propertySearchGeneration = 0
    @State private var propertySearchTruncated = false
    @State private var detailGeneration = 0
    @State private var detailFailed = false
    @State private var showCopyConfirmation = false

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .frame(minWidth: 800, minHeight: 520)
        .navigationTitle(AppLocalization.string("IOKit 属性检查器", locale: locale))
        .searchable(text: $searchText, placement: .sidebar,
                    prompt: Text(LocalizedStringKey("搜索条目、类名、registryID、属性键值")))
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await refreshIndex() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .disabled(isLoading)
                .keyboardShortcut("r", modifiers: .command)
            }
        }
        .task { await refreshIndex() }
        .onChange(of: selectedEntryID) { _, id in
            detailGeneration += 1
            isDetailLoading = false
            selectedEntry = nil
            detailFailed = false
            guard let id, let item = entries.first(where: { $0.registryID == id }) else { return }
            let generation = detailGeneration
            Task { await loadDetails(item, generation: generation) }
        }
        .onChange(of: searchText) { _, value in
            propertySearchTask?.cancel()
            propertySearchGeneration += 1
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                propertySearchMatches = []
                propertySearchFailedCount = 0
                propertySearchTruncated = false
                isPropertySearchLoading = false
                return
            }
            isPropertySearchLoading = true
            let generation = propertySearchGeneration
            propertySearchTask = Task { await searchAllProperties(value, generation: generation) }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            if isTruncated || failedCount > 0 || !failedPlanes.isEmpty ||
                propertySearchTruncated || propertySearchFailedCount > 0 || isPropertySearchLoading {
                VStack(alignment: .leading, spacing: 5) {
                    if isTruncated {
                        integrityNotice("全局索引超过安全上限，结果已截断")
                    }
                    if failedCount > 0 {
                        integrityNotice("有 \(failedCount) 个索引条目无法读取身份信息")
                    }
                    if !failedPlanes.isEmpty {
                        integrityNotice("无法索引的 plane：\(failedPlanes.joined(separator: "、"))")
                    }
                    if propertySearchTruncated {
                        integrityNotice("全局属性搜索达到读取上限；匹配结果可能不完整")
                    }
                    if propertySearchFailedCount > 0 {
                        integrityNotice("全局属性搜索有 \(propertySearchFailedCount) 个条目读取失败")
                    }
                    if isPropertySearchLoading {
                        Label("正在检查索引条目的属性…", systemImage: "magnifyingglass")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("属性搜索会读取最多 \(RegistryService.maxGlobalSearchEntries) 个索引条目的完整属性。")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(10)
            }
            List(selection: $selectedEntryID) {
                ForEach(groupedEntries, id: \.className) { group in
                    Section {
                        ForEach(group.items) { item in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.displayTitle)
                                    .font(.callout.weight(.medium))
                                    .lineLimit(1)
                                    Text("\(item.className) · #\(item.registryID)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Text(item.sourceSummary(locale: locale))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                            .tag(item.id)
                        }
                    } header: {
                        Text("\(group.className) · \(group.items.count)")
                            .textSelection(.enabled)
                    }
                }
            }
            .listStyle(.sidebar)
            .overlay {
                if groupedEntries.isEmpty && !isLoading {
                    EmptyHint(text: entries.isEmpty ? "索引中没有可显示的 IORegistry 条目" : "没有匹配的条目")
                }
            }
            if isLoading {
                ProgressView("正在建立全局索引…")
                    .controlSize(.small)
                    .padding(8)
            }
        }
        .navigationSplitViewColumnWidth(min: 260, ideal: 330)
    }

    private var detail: some View {
        Group {
            if let selectedEntry {
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(selectedEntry.displayTitle).font(.headline)
                            Text("类 \(selectedEntry.className) · registryID \(selectedEntry.registryID) · \(selectedEntry.properties.count) 个属性")
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                        Spacer()
                        if isDetailLoading { ProgressView().controlSize(.small) }
                        Button {
                            copyToPasteboard(selectedEntry)
                            showCopyConfirmation = true
                        } label: {
                            Label(showCopyConfirmation ? "已拷贝" : "拷贝全部",
                                  systemImage: showCopyConfirmation ? "checkmark" : "doc.on.doc")
                        }
                        .disabled(isDetailLoading)
                        .keyboardShortcut("c", modifiers: [.command, .shift])
                    }
                    .padding(12)
                    Divider()
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(filteredProperties(of: selectedEntry)).sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                                PropertyRow(key: key, value: value)
                                Divider().padding(.leading, 12)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                }
            } else if isDetailLoading {
                ProgressView("正在读取完整属性…")
            } else if detailFailed {
                EmptyHint(text: "无法读取所选条目的完整属性；请刷新索引后重试")
            } else {
                EmptyHint(text: "从左侧按类浏览并选择一个条目")
            }
        }
    }

    private func integrityNotice(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var groupedEntries: [RegistryEntryGroup] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = entries.filter { item in
            guard !query.isEmpty else { return true }
            if item.displayTitle.lowercased().contains(query) || item.className.lowercased().contains(query) ||
                String(item.registryID).contains(query) || item.planePaths.keys.contains(where: { $0.lowercased().contains(query) }) {
                return true
            }
            return propertySearchMatches.contains(item.registryID)
        }
        return Dictionary(grouping: filtered, by: \.className).keys.sorted().map { name in
            RegistryEntryGroup(className: name, items: Dictionary(grouping: filtered, by: \.className)[name] ?? [])
        }
    }

    private func filteredProperties(of entry: RegistryEntrySnapshot) -> [String: IORegistryValue] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return entry.properties }
        let matches = entry.properties.filter { key, value in
            key.lowercased().contains(query) || value.displayText.lowercased().contains(query)
        }
        return matches.isEmpty ? entry.properties : matches
    }

    private func searchAllProperties(_ rawQuery: String, generation: Int) async {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return }
        isPropertySearchLoading = true
        propertySearchMatches = []
        propertySearchFailedCount = 0
        propertySearchTruncated = false
        let candidates = entries
        let searchCandidates = Array(candidates.prefix(RegistryService.maxGlobalSearchEntries))
        propertySearchTruncated = candidates.count > searchCandidates.count
        var matches = Set<UInt64>()
        var failed = 0
        for item in searchCandidates {
            guard !Task.isCancelled, propertySearchGeneration == generation else { return }
            let result = await RegistryService().readEntry(item)
            guard !Task.isCancelled, propertySearchGeneration == generation else { return }
            guard let entry = result.entry else {
                failed += 1
                continue
            }
            if entry.properties.contains(where: { key, value in
                key.lowercased().contains(query) || value.displayText.lowercased().contains(query)
            }) {
                matches.insert(item.registryID)
            }
        }
        guard propertySearchGeneration == generation else { return }
        propertySearchMatches = matches
        propertySearchFailedCount = failed
        isPropertySearchLoading = false
    }

    private func refreshIndex() async {
        detailGeneration += 1
        isDetailLoading = false
        propertySearchTask?.cancel()
        propertySearchGeneration += 1
        isPropertySearchLoading = false
        propertySearchMatches = []
        isLoading = true
        let result = await RegistryService().buildGlobalIndex()
        entries = result.entries
        isTruncated = result.truncated
        failedCount = result.failedCount
        failedPlanes = result.failedPlanes
        isLoading = false
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let generation = propertySearchGeneration
            propertySearchTask = Task { await searchAllProperties(searchText, generation: generation) }
        }
        if let selectedEntryID, !entries.contains(where: { $0.registryID == selectedEntryID }) {
            self.selectedEntryID = nil
            selectedEntry = nil
        }
        if let selectedEntryID, let selected = entries.first(where: { $0.registryID == selectedEntryID }) {
            detailGeneration += 1
            let generation = detailGeneration
            Task { await loadDetails(selected, generation: generation) }
        } else {
            self.selectedEntryID = entries.first?.registryID
        }
    }

    private func loadDetails(_ item: RegistryEntryIndexItem, generation: Int) async {
        isDetailLoading = true
        let result = await RegistryService().readEntry(item)
        guard detailGeneration == generation,
              selectedEntryID == item.registryID,
              entries.contains(where: { $0.registryID == item.registryID }) else { return }
        selectedEntry = result.entry
        detailFailed = result.failed
        isDetailLoading = false
    }

    /// 保留旧检查器异步结果判定 helper，避免已有 App 测试目标失去其编译契约。
    static func isStaleResult(requestedClass: String, currentClass: String, isCancelled: Bool) -> Bool {
        isCancelled || requestedClass != currentClass
    }

    private func copyToPasteboard(_ entry: RegistryEntrySnapshot) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(RegistryText.render(entry: entry), forType: .string)
    }
}

private struct RegistryEntryGroup {
    let className: String
    let items: [RegistryEntryIndexItem]
}

private struct PropertyRow: View {
    let key: String
    let value: IORegistryValue
    @State private var isExpanded = true

    var body: some View {
        switch value {
        case .dictionary(let dict) where !dict.isEmpty:
            disclosure { ForEach(IORegistryValue.sortedKeys(in: dict), id: \.self) { child in PropertyRow(key: child, value: dict[child] ?? .other("")) } }
        case .array(let items) where !items.isEmpty:
            disclosure { ForEach(items.indices, id: \.self) { index in PropertyRow(key: "[\(index)]", value: items[index]) } }
        default:
            HStack(alignment: .top, spacing: 12) {
                Text(key).font(.callout).foregroundStyle(.secondary).frame(minWidth: 200, maxWidth: 320, alignment: .leading).textSelection(.enabled)
                Text(value.displayText).font(.callout.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12).padding(.vertical, 4)
        }
    }

    private func disclosure(@ViewBuilder children: @escaping () -> some View) -> some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            children().padding(.leading, 16)
        } label: {
            HStack(spacing: 8) {
                Text(key).font(.callout.weight(.medium)).foregroundStyle(.primary)
                Text("(\(value.displayText))").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(minWidth: 200, maxWidth: 320, alignment: .leading)
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
    }
}
