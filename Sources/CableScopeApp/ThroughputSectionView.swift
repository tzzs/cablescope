import CableKit
import SwiftUI

/// 卷吞吐实测（Docs/03「实测吞吐」）：App UI 对 CableKit `ThroughputTester` 的封装，
/// 与 CLI `throughput` 子命令共用同一套系统访问逻辑（分层规则：本文件不做任何 IOKit/文件系统直读）。
///
/// 不与线缆会话绑定：macOS 不暴露"USB 存储设备 → 挂载卷"的直接映射（同 `PortGrouping` 对
/// Displays 的处理方式一致——没有可靠归属时不强行归属），因此改为独立区域，列出全部候选卷由用户手动选择。
struct ThroughputSectionView: View {
    @StateObject private var model = ThroughputSectionModel()

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
                        Label(model.isRunning ? "测速中（写入 + 读取，各约 5 秒）…" : "开始测速",
                              systemImage: "play.fill")
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
                        InfoChip(text: "写入 \(Self.speedText(result.writeMBps))",
                                 systemImage: "square.and.arrow.up", color: .blue)
                        InfoChip(text: "读取 \(Self.speedText(result.readMBps))",
                                 systemImage: "square.and.arrow.down", color: .green)
                    }
                    Text("\(result.volumeName) · 写出 \(Self.mbText(result.bytesWritten)) · "
                         + "读出 \(Self.mbText(result.bytesRead)) · 共 \(String(format: "%.1f", result.elapsedSeconds)) 秒")
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

    private static func speedText(_ mbps: Double?) -> String {
        mbps.map { String(format: "%.1f MB/s", $0) } ?? "无有效数据"
    }

    private static func mbText(_ bytes: Int64) -> String {
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
                lastResult = try await ThroughputTester.measure(at: candidate.url)
            } catch let error as ThroughputError {
                lastError = error.description
            } catch {
                lastError = "测速失败：\(error.localizedDescription)"
            }
            isRunning = false
        }
    }
}
