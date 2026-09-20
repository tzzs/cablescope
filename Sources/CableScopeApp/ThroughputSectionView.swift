import CableKit
import SwiftUI

/// 卷吞吐实测（Docs/03「实测吞吐」）：App UI 对 CableKit `ThroughputTester` 的封装，
/// 与 CLI `throughput` 子命令共用同一套系统访问逻辑（分层规则：本文件不做任何 IOKit/文件系统直读）。
///
/// 不与线缆会话绑定：macOS 不暴露"USB 存储设备 → 挂载卷"的直接映射（同 `PortGrouping` 对
/// Displays 的处理方式一致——没有可靠归属时不强行归属），因此改为独立区域，列出全部候选卷由用户手动选择。
struct ThroughputSectionView: View {
    @StateObject private var model = ThroughputSectionModel()
    @Environment(\.locale) private var locale

    var body: some View {
        SectionCard(title: "吞吐实测", systemImage: "speedometer",
                    caption: "协商速率 ≠ 实际吞吐；测的是所选外接卷的真实读写速度") {
            VStack(alignment: .leading, spacing: 10) {
                if model.candidates.isEmpty {
                    EmptyHint(text: "未检测到外接/可移动卷")
                } else {
                    Picker("测速卷", selection: $model.selectedVolumeID) {
                        ForEach(model.candidates) { candidate in
                            Text("\(candidate.name) · \(candidate.url.path)")
                                .tag(candidate.id as String?)
                        }
                    }
                    .labelsHidden()
                }

                HStack(spacing: 10) {
                    Button {
                        model.run()
                    } label: {
                        if model.isRunning {
                            Label("测速中（写入 + 读取，各约 5 秒）…", systemImage: "play.fill")
                        } else {
                            Label("开始测速", systemImage: "play.fill")
                        }
                    }
                    .disabled(model.isRunning || model.selectedVolumeID == nil)

                    Button {
                        model.reloadCandidates()
                    } label: {
                        Label("刷新卷列表", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.isRunning)
                }
                .controlSize(.small)

                if let result = model.lastResult {
                    FlowLayout(spacing: 5) {
                        InfoChip(text: "写入 \(Self.speedText(result.writeMBps, locale: locale))",
                                 systemImage: "square.and.arrow.up", color: .blue)
                        InfoChip(text: "读取 \(Self.speedText(result.readMBps, locale: locale))",
                                 systemImage: "square.and.arrow.down", color: .green)
                    }
                    // 固定文案片段和数值分开：elapsedSeconds 走 FormatStyle 插值，
                    // 不经过字符串目录查表（原因同 OverviewSectionView 的系统输入行）。
                    (Text(result.volumeName) + Text(" · 写出 ") + Text(Self.mbText(result.bytesWritten))
                        + Text(" · 读出 ") + Text(Self.mbText(result.bytesRead)) + Text(" · 共 ")
                        + Text(result.elapsedSeconds, format: .number.precision(.fractionLength(1)))
                        + Text(" 秒"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if let error = model.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .task { model.reloadCandidates() }
    }

    /// 速率展示文案（internal 便于单测）。
    ///
    /// 无读数时的回退文案必须显式走 `AppLocalization`：它是作为 `%@` 值插进
    /// `"写入 %@"` 这个 LocalizedStringKey 的，插进去的字符串本身不会再被 SwiftUI 查表
    /// ——早先直接返回中文字面量，导致英文界面显示成 "Write 无有效数据"（译文表里其实
    /// 有 "No valid data"，只是永远走不到）。数字部分有意不随 locale 变进制/分隔符。
    static func speedText(_ mbps: Double?, locale: Locale) -> String {
        guard let mbps else { return AppLocalization.string("无有效数据", locale: locale) }
        return String(format: "%.1f MB/s", mbps)
    }

    /// 容量展示文案（internal 便于单测）。纯数字 + 单位，不涉及翻译。
    static func mbText(_ bytes: Int64) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_000_000)
    }
}

/// 测速区状态：候选卷列表 + 单次测速的运行状态，独立于 `MonitorViewModel`
/// （吞吐测试是用户主动触发的一次性动作，不属于快照流驱动的跨场景状态）。
@MainActor
private final class ThroughputSectionModel: ObservableObject {
    struct Candidate: Identifiable {
        let url: URL
        let name: String
        var id: String { url.path }
    }

    @Published var candidates: [Candidate] = []
    @Published var selectedVolumeID: String?
    @Published private(set) var isRunning = false
    @Published private(set) var lastResult: ThroughputResult?
    @Published private(set) var lastError: String?

    /// 重新枚举候选卷；已选中的卷若不再挂载（拔出）则清空选择并回退到列表第一项。
    func reloadCandidates() {
        candidates = ThroughputTester.listCandidateVolumes().map { Candidate(url: $0.url, name: $0.name) }
        if let selectedVolumeID, !candidates.contains(where: { $0.id == selectedVolumeID }) {
            self.selectedVolumeID = nil
        }
        if selectedVolumeID == nil {
            selectedVolumeID = candidates.first?.id
        }
    }

    func run() {
        guard !isRunning, let id = selectedVolumeID,
              let candidate = candidates.first(where: { $0.id == id }) else { return }
        isRunning = true
        lastError = nil
        Task {
            do {
                // locale 必须显式传：`measure` 默认 `.current`（系统语言），而这里要的是
                // 用户在设置里选的语言，否则英文界面会收到中文的测速失败提示。
                lastResult = try await ThroughputTester.measure(at: candidate.url,
                                                               locale: AppPreferences.effectiveLocale())
            } catch let error as ThroughputError {
                lastError = error.description
            } catch {
                let template = AppLocalization.string("测速失败：%@", locale: AppPreferences.effectiveLocale())
                lastError = String(format: template, error.localizedDescription)
            }
            isRunning = false
        }
    }
}
