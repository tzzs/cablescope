# CableScope · 线缆透视

macOS 菜单栏工具：检测连接数据线（USB-C / 雷电）的**充电速度、传输速度、视频能力**与**线缆评级**。

核心思路：macOS 不直接读取线缆 e-marker 芯片，系统看到的是"协商结果"。CableScope 展示实时协商信息，并通过**历史协商峰值**推断线缆规格下限（如 PD 协商到 20V×5A ⇒ 必为 5A e-marker 线）。

## 功能

| 维度 | 内容 |
| --- | --- |
| ⚡ 充电 | 瞬时功率（W）、电压/电流、PD 合同（与瞬时功率分开显示）、电量、实时功率曲线（App） |
| 🔌 传输 | USB 协商速率（USB 2.0 / 3.x / USB4 / 雷电）、设备列表 |
| 🖥 视频 | 显示器列表、分辨率/刷新率、DP 链路速率（外接显示器时） |
| 🏷 评级 | 基于历史协商峰值的线缆能力卡，持久化到本地 |

## 快速开始

要求：macOS 13+，Swift 5.10+ 工具链（Xcode 15+）。

```bash
# CLI：人类可读输出
swift run CableScopeCLI pretty

# CLI：JSON 快照 / 持续监听 / 线缆评级
swift run CableScopeCLI snapshot --pretty
swift run CableScopeCLI watch
swift run CableScopeCLI rating        # --reset 清空历史

# macOS 菜单栏 App（SwiftPM 可执行文件直接运行）
swift run CableScopeApp

# 或打包成 CableScope.app
./scripts/bundle_app.sh release && open build/CableScope.app
```

## CLI 子命令

| 子命令 | 说明 |
| --- | --- |
| `snapshot`（默认） | 输出 JSON 快照（`--pretty` 美化） |
| `pretty` | 分区块人类可读输出（电源/USB/显示器/雷电） |
| `watch` | 监听变化，内容变化时打印差异行（`--interval N` 调整兜底轮询） |
| `rating` | 记录并显示线缆能力卡（持久化于 `~/Library/Application Support/CableScope/`），`--reset` 清空 |

## 工程结构

```
Sources/
├── CableKit/          # 系统 IO 适配层（Swift Package library）
│   ├── Models/        #   数据契约：CableSnapshot / CableRating（Codable + Sendable）
│   ├── Services/      #   USBService / PowerService / DisplayService / ThunderboltService
│   ├── Monitor/       #   CableMonitor：快照组合 + 事件流（AsyncStream）
│   └── Rating/        #   CableRatingEngine：历史峰值 → 线缆评级（纯 Swift，可单测）
├── CableScopeCLI/     # 命令行工具
└── CableScopeApp/     # SwiftUI 菜单栏 App（MenuBarExtra + 主窗口 + Swift Charts 功率曲线）
Tests/
├── CableKitTests/       # 39 个测试：数据契约、评级引擎、四个解析器（真机样例回归）+ 真实环境冒烟
└── CableScopeCLITests/  # 34 个测试：参数解析、格式化、watch 快照差异计算
Docs/                  # 产品定位与命名 / 技术架构 / 数据获取指南
scripts/bundle_app.sh  # .app 打包脚本
```

## 数据来源（详见 [Docs/03-数据获取指南.md](Docs/03-数据获取指南.md)）

- **USB**：IOKit `IOUSBHostDevice`（协商速率、LocationID、VID/PID）
- **充电**：IORegistry `AppleSmartBattery`（瞬时功率 = `AdapterDetails.AdapterVoltage` × 顶层 `Amperage`；PD 合同 = `AdapterDetails` 合同值）+ IOKit.ps 备用电量
- **显示器**：CoreGraphics（分辨率/刷新率）+ `NSScreen.localizedName`（macOS 26 移除了 CGDisplayProductName）
- **雷电**：`system_profiler SPThunderboltDataType -json` 递归展平

## 开发状态

- [x] CableKit 适配层（USB/电源/显示器/雷电 + 快照流 + 评级引擎）— 73/73 测试通过（含 CLI 测试 target）
- [x] CLI 四个子命令（真机验证：PD 合同识别、e-marker 推断、评级持久化）
- [x] macOS 菜单栏 App（功率大字、USB/显示器面板、实时功率曲线、线缆能力卡）
- [ ] 插拔系统通知（UNUserNotificationCenter）
- [ ] USB 实测吞吐（5 秒读写测速）
- [ ] IOKit 通知替代轮询、正式分发（公证）、App 图标

### 已知限制

- 线缆 e-marker 与品牌规格**不可直接读取**，评级为"基于协商峰值的下限推断"，UI/CLI 均已标注。
- 内置显示器无 DP link rate 字段，`linkRateLabel` 需接外接 DP/雷电显示器才会生效。
- `watch`/快照流当前为内容变化检测 + 兜底轮询（IOKit 通知桥接在 roadmap）。
- `.app` 打包脚本适用于本地使用；App Store/公证分发建议后续迁移 Xcode 工程。
