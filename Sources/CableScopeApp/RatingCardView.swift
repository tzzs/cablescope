import CableKit
import SwiftUI

/// 🏷 线缆能力卡：评级摘要 + 观测统计 + 免责说明。
struct RatingCardView: View {
    @ObservedObject var viewModel: MonitorViewModel

    var body: some View {
        SectionCard(title: "线缆能力", systemImage: "tag.fill") {
            if let rating = viewModel.rating, rating.sampleCount > 0 {
                VStack(alignment: .leading, spacing: 10) {
                    Text(rating.summary)
                        .font(.title3.weight(.semibold))

                    HStack(spacing: 8) {
                        InfoChip(
                            text: "基于 \(rating.sampleCount) 次协商观测",
                            systemImage: "number",
                            color: .secondary
                        )
                        if rating.is5ACable {
                            InfoChip(text: "5A e-marker", systemImage: "checkmark.seal.fill", color: .orange)
                        }
                    }

                    HStack(spacing: 12) {
                        if let firstSeen = rating.firstSeen {
                            Text("首次观测 \(firstSeen.formatted(date: .abbreviated, time: .shortened))")
                        }
                        if let lastSeen = rating.lastSeen {
                            Text("最近观测 \(lastSeen.formatted(date: .abbreviated, time: .shortened))")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Text("线缆规格基于协商峰值推断，e-marker 信息不可直接读取。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("暂无评级数据")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text("线缆规格基于协商峰值推断，e-marker 信息不可直接读取。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
