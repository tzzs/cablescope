import CableKit
import AppKit
import SwiftUI

/// 全局 IORegistry 浏览器：轻量索引跨 plane 合并，选中时按需读取完整属性。
struct RegistryInspectorView: View {
    @Environment(\.locale) private var locale
    @FocusState private var isSearchFocused: Bool
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
    @State private var detailGeneration = 0
    @State private var detailFailed = false
    @State private var showCopyConfirmation = false
    @State private var isIntegrityPopoverPresented = false
    @State private var expandedClassNames: Set<String> = []

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .frame(minWidth: 800, minHeight: 520)
        .navigationTitle(AppLocalization.string("IOKit 属性检查器", locale: locale))
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
                isPropertySearchLoading = false
                return
            }
            isPropertySearchLoading = true
            let generation = propertySearchGeneration
            propertySearchTask = Task { await searchAllProperties(value, generation: generation) }
        }
    }

    private var sidebar: some View {
        List(selection: $selectedEntryID) {
            ForEach(groupedEntries, id: \.className) { group in
                DisclosureGroup(isExpanded: classExpansionBinding(for: group.className)) {
                    ForEach(group.items) { item in
                        entryRow(item)
                            .tag(item.id)
                    }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "square.stack.3d.up")
                            .foregroundStyle(.secondary)
                        Text(group.className)
                            .font(.caption.weight(.semibold).monospaced())
                            .textSelection(.enabled)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text("\(group.items.count)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.sidebar)
        // 搜索框与提醒钉在 List 的 safe area 顶部——它们是 List 的固定头，
        // 不随列表内容滚动被顶走，也不占用 List 之外的额外列高。
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                searchBar
                if hasIntegrityIssues || propertySearchFailedCount > 0 {
                    integritySummary
                        .padding(.horizontal, 10)
                        .padding(.top, 4)
                        .padding(.bottom, 3)
                }
                if isPropertySearchLoading {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("正在检查索引条目的属性…")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
                }
                HStack(spacing: 8) {
                    Label("IORegistry 条目", systemImage: "list.bullet.rectangle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(entries.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                Divider()
            }
            .background(.regularMaterial)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isLoading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("正在建立全局索引…")
                }
                .font(.caption)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(.regularMaterial)
            }
        }
        .overlay {
            if groupedEntries.isEmpty && !isLoading {
                EmptyHint(text: entries.isEmpty ? "索引中没有可显示的 IORegistry 条目" : "没有匹配的条目")
            }
        }
        .navigationSplitViewColumnWidth(min: 260, ideal: 330)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索条目、类名、registryID、属性键值", text: $searchText)
                .textFieldStyle(.plain)
                .focused($isSearchFocused)
                .accessibilityLabel("搜索所有 IORegistry 内容")
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    isSearchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private func classExpansionBinding(for className: String) -> Binding<Bool> {
        Binding(
            get: { expandedClassNames.contains(className) },
            set: { isExpanded in
                if isExpanded {
                    expandedClassNames.insert(className)
                } else {
                    expandedClassNames.remove(className)
                }
            }
        )
    }

    private func entryRow(_ item: RegistryEntryIndexItem) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(item.displayTitle)
                .font(.callout.weight(.medium))
                .lineLimit(1)
            Text("registryID \(item.registryID)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
    }

    private var detail: some View {
        Group {
            if let selectedEntry {
                VStack(spacing: 0) {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(selectedEntry.displayTitle).font(.headline)
                            Text("类 \(selectedEntry.className) · registryID \(selectedEntry.registryID) · \(selectedEntry.properties.count) 个属性")
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                        .frame(minWidth: propertyKeyColumnWidth, alignment: .leading)
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
                        .padding(.vertical, 4)
                    }
                    .scrollIndicators(.visible)
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

    private var hasIntegrityIssues: Bool {
        isTruncated || failedCount > 0 || !failedPlanes.isEmpty
    }

    private var integritySummary: some View {
        Button {
            isIntegrityPopoverPresented = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(hasIntegrityIssues ? "索引可能不完整" : "属性搜索结果可能不完整")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.orange.opacity(0.1), in: Capsule())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isIntegrityPopoverPresented, arrowEdge: .leading) {
            VStack(alignment: .leading, spacing: 8) {
                if hasIntegrityIssues {
                    Text("IORegistry 索引没有覆盖所有条目；当前结果仍可浏览，但可能遗漏部分节点。")
                        .fixedSize(horizontal: false, vertical: true)
                    if isTruncated {
                        Label("索引达到安全上限，后续条目未纳入结果。", systemImage: "list.number")
                    }
                    if failedCount > 0 {
                        Label("有 \(failedCount) 个条目无法读取身份信息，因此未显示。", systemImage: "questionmark.folder")
                    }
                    if !failedPlanes.isEmpty {
                        Text("无法遍历的 plane：")
                            .fontWeight(.medium)
                        Text(failedPlanes.joined(separator: ", "))
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
                if propertySearchFailedCount > 0 {
                    Text("属性搜索结果可能不完整；条目列表索引本身不受此状态影响。")
                        .fixedSize(horizontal: false, vertical: true)
                    Label("有 \(propertySearchFailedCount) 个条目的属性读取失败。", systemImage: "questionmark.folder")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(14)
            .frame(width: 320, alignment: .leading)
        }
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
            Self.propertyContains(key, value, query: query)
        }
        return matches.isEmpty ? entry.properties : matches
    }

    private func searchAllProperties(_ rawQuery: String, generation: Int) async {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return }
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled, propertySearchGeneration == generation else { return }

        isPropertySearchLoading = true
        propertySearchMatches = []
        propertySearchFailedCount = 0
        let candidates = entries
        let batchSize = 12
        var matches = Set<UInt64>()
        var failed = 0

        for start in stride(from: 0, to: candidates.count, by: batchSize) {
            guard !Task.isCancelled, propertySearchGeneration == generation else { return }
            let batch = Array(candidates[start..<min(start + batchSize, candidates.count)])
            let results = await withTaskGroup(of: (UInt64, Bool, Bool).self, returning: [(UInt64, Bool, Bool)].self) { group in
                for item in batch {
                    group.addTask {
                        let result = await RegistryService().readEntry(item)
                        guard let entry = result.entry else { return (item.registryID, false, true) }
                        let found = Self.properties(entry.properties, contain: query)
                        return (item.registryID, found, false)
                    }
                }
                var collected: [(UInt64, Bool, Bool)] = []
                for await result in group { collected.append(result) }
                return collected
            }
            for (id, found, didFail) in results {
                if found { matches.insert(id) }
                if didFail { failed += 1 }
            }
        }
        guard !Task.isCancelled, propertySearchGeneration == generation else { return }
        propertySearchMatches = matches
        propertySearchFailedCount = failed
        isPropertySearchLoading = false
    }

    nonisolated private static func properties(_ properties: [String: IORegistryValue], contain query: String) -> Bool {
        properties.contains { key, value in
            propertyContains(key, value, query: query)
        }
    }

    /// 单个顶层键值对是否命中：键名或值的完整子树（嵌套字典/数组）任一命中即可。
    nonisolated private static func propertyContains(_ key: String, _ value: IORegistryValue, query: String) -> Bool {
        key.localizedStandardContains(query) || valueContains(value, query: query)
    }

    nonisolated private static func valueContains(_ value: IORegistryValue, query: String) -> Bool {
        switch value {
        case .dictionary(let dictionary):
            return properties(dictionary, contain: query)
        case .array(let values):
            return values.contains { valueContains($0, query: query) }
        default:
            return value.displayText.localizedStandardContains(query)
        }
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

/// 属性行的键名列宽度——detail header 与 PropertyRow 共用，保证标题与每行键名左对齐。
private let propertyKeyColumnWidth: CGFloat = 220

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
                Text(key).font(.callout).foregroundStyle(.secondary).frame(minWidth: propertyKeyColumnWidth, alignment: .leading).textSelection(.enabled)
                Text(value.displayText).font(.callout.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12).padding(.vertical, 2)
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
            .frame(minWidth: propertyKeyColumnWidth, alignment: .leading)
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
    }
}
