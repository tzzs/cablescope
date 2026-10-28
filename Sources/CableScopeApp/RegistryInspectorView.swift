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

    @Environment(\.locale) private var locale

    @State private var className = RegistryService.wellKnownClasses[0].className
    /// 输入框草稿：与 className 分离，避免每敲一个字符触发一次 IORegistry 枚举。
    @State private var classDraft = RegistryService.wellKnownClasses[0].className
    @State private var entries: [RegistryEntrySnapshot] = []
    @State private var selectedEntryID: UInt64?
    @State private var searchText = ""
    @State private var isLoading = false
    /// 本次枚举是否因触及条目数上限而被截断（结果不完整，必须提示用户）。
    @State private var isTruncated = false
    /// 本次枚举有多少条目的属性读取失败（条目在，但属性读不出来）。
    @State private var failedCount = 0
    /// 拷贝成功反馈：按钮短暂显示"已拷贝"（HIG：操作应有可见确认）。
    @State private var showCopyConfirmation = false

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .frame(minWidth: 760, minHeight: 480)
        // 标题栏文字自己按 \.locale 查好再传 String：标题栏对 LocalizedStringKey 按系统语言
        // 查表、不看 environment（实测中文系统 + App 英文时这里仍显示中文），见 AGENTS.md。
        .navigationTitle(AppLocalization.string("IOKit 属性检查器", locale: locale))
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
                        Text("\(item.label(locale: locale)) · \(item.className)").tag(item.className)
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

            // 完整性提示：诊断工具里"没显示全"必须说出口，否则用户会把残缺结果
            // 当成该类的全部条目，排查结论就建立在错误前提上。
            //
            // 两种不完整要分开说：截断（有条目被丢弃）与属性读取失败（条目在，
            // 但属性读不出来）——成因不同，用户的下一步排查方向也不同。
            if isTruncated {
                Label {
                    Text("条目数超过上限，仅显示前 \(RegistryService.maxEntries) 条")
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .font(.caption)
                .foregroundStyle(.orange)
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            }
            if failedCount > 0 {
                Label {
                    Text("另有 \(failedCount) 个条目的属性无法读取")
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .font(.caption)
                .foregroundStyle(.orange)
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
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
                // 枚举失败与"该类无条目"都表现为空列表（服务层契约：失败即降级为空），
                // 所以这里只有一种空态文案，不做"出错了"的伪区分。
                EmptyHint(text: "该类名下没有 registry 条目")
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
        } else if entries.isEmpty {
            EmptyHint(text: "等待枚举结果…")
        } else {
            EmptyHint(text: "在左侧选择一个条目")
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
                if showCopyConfirmation {
                    Label("已拷贝", systemImage: "checkmark")
                } else {
                    Label("拷贝全部", systemImage: "doc.on.doc")
                }
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
        let result = await RegistryService().enumerate(matchingClass: targetClass)
        // 返回后必须重新确认"这次结果还是当前请求的"：
        // 切换类名会取消旧的 SwiftUI task，但底下的 detached 枚举不可取消、照样会返回。
        // 不设这道闸，旧类名的结果会在新类名的枚举之后落到界面状态里——侧栏标题写着
        // 新类名，列表却是旧类的条目，排查结论直接建立在错位的数据上。
        guard !Self.isStaleResult(requestedClass: targetClass,
                                  currentClass: className,
                                  isCancelled: Task.isCancelled) else { return }
        entries = result.entries
        isTruncated = result.truncated
        failedCount = result.failedCount
        // 选中项优先保留（仍存在时）；否则自动选第一条。
        if selectedEntryID == nil || !result.entries.contains(where: { $0.registryID == selectedEntryID }) {
            selectedEntryID = result.entries.first?.registryID
        }
        isLoading = false
    }

    /// 异步枚举返回后，结果是否已经过期（任务被取消，或用户已切到别的类名）。
    ///
    /// 抽成纯函数是为了能单测——这是"旧结果覆盖新类名列表"这个 bug 的唯一判据，
    /// 埋在一个 `async` 视图方法里就再也测不到了。
    static func isStaleResult(requestedClass: String, currentClass: String, isCancelled: Bool) -> Bool {
        isCancelled || requestedClass != currentClass
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
