# CableScope · 线缆透视

![Swift 5.10+](https://img.shields.io/badge/Swift-5.10%2B-orange) ![macOS 14+](https://img.shields.io/badge/macOS-14%2B-lightgrey) ![License: MIT](https://img.shields.io/badge/License-MIT-yellow) [![CI](https://github.com/tzzs/cablescope/actions/workflows/ci.yml/badge.svg)](https://github.com/tzzs/cablescope/actions/workflows/ci.yml)

macOS 菜单栏工具：检测连接数据线（USB-C / 雷电）的**充电速度、传输速度、视频能力**与**线缆评级**。

> For the English version, see [README.md](README.md)。

核心思路：多数 Mac 上系统只看到"协商结果"，看不到线缆本身。在 Apple Silicon 上，CableScope 直读 USB-C 端口控制器（AppleHPM）——包括线缆的 e-marker 芯片——并展示实时协商信息；拿不到 e-marker 数据时，通过**历史协商峰值**推断线缆规格下限（如 PD 协商到 20V×5A ⇒ 必为 5A e-marker 线）。

## 功能

| 维度 | 内容 |
| --- | --- |
| ⚡ 充电 | 瞬时功率（W）、电压/电流、PD 合同（与瞬时功率分开显示）、PD 档位表（直读，当前协商档标出）、充电瓶颈归因、电量、实时功率曲线（App） |
| 🔌 传输 | USB 协商速率（USB 2.0 / 3.x / USB4 / 雷电）、设备列表 |
| 🖥 视频 | 显示器列表、分辨率/刷新率、DP 链路速率（外接显示器时） |
| 🎛 端口控制器 | Apple Silicon 直读 USB-C 端口控制器（AppleHPM / AppleTC）：端口状态、插拔方向、支持的传输能力（CC / USB2 / USB3 / USB4 / DisplayPort）；Intel/老机型自动降级为推断模式 |
| 🧬 e-marker | 直读线缆 e-marker 芯片（SOP' Discover Identity）：线缆速度档、3A / 5A 电流评级、厂商 ID + 产品类型 |
| 🏷 评级 | 基于历史协商峰值的线缆能力卡，持久化到本地（按端口分桶，拔线不清零） |
| 🧵 多线缆 | 设备按物理端口聚合为线缆会话（USB 根端口分组 + 雷雳 receptacle 编号）：主窗口每线一张卡片 + 可切换的详情区，菜单栏每线一行，CLI 输出按端口分组 |
| 🔔 通知 | 插拔系统通知（UNUserNotificationCenter）；未打包运行（无 bundle）时静默禁用 |
| 🔬 IOKit 检查器 | 任意 IOKit 类的 IORegistry **全量原始属性**（USB 设备、电池、显示器连接、雷电端口…）：App 专属窗口 + CLI 子命令；快照 JSON 亦携带各设备 `rawProperties` |

## 快速开始

要求：macOS 14+，Swift 5.10+ 工具链（Xcode 15+）。

```bash
# CLI：人类可读输出
swift run CableScopeCLI pretty

# CLI：JSON 快照 / 持续监听 / 线缆评级
swift run CableScopeCLI snapshot --pretty
swift run CableScopeCLI watch
swift run CableScopeCLI rating        # --reset 清空历史

# CLI：按类名导出 IORegistry 全量属性（可 --json）
swift run CableScopeCLI properties                        # 默认 IOUSBHostDevice
swift run CableScopeCLI properties AppleSmartBattery
swift run CableScopeCLI properties IODisplayConnect --json

# macOS 菜单栏 App（SwiftPM 可执行文件直接运行）
swift run CableScopeApp

# 或打包成 CableScope.app
./scripts/bundle_app.sh release && open build/CableScope.app
```

## CLI 子命令

| 子命令 | 说明 |
| --- | --- |
| `snapshot`（默认） | 输出 JSON 快照（`--pretty` 美化） |
| `pretty` | 分区块人类可读输出（电源/线缆端口/显示器），设备按物理端口分组、按 hub 层级缩进 |
| `watch` | 监听变化，内容变化时打印差异行（`--interval N` 调整兜底轮询） |
| `rating` | 记录并显示线缆能力卡（持久化于 `~/Library/Application Support/CableScope/`），`--reset` 清空 |
| `properties [类名]` | 按类名枚举 IORegistry 条目，输出**全量** IOKit 属性（ioreg 风格文本；`--json` 结构化输出） |

## 工程结构

```
Sources/
├── CableKit/          # 系统 IO 适配层（Swift Package library）
│   ├── Models/        #   数据契约：CableSnapshot / CableSession / CableRating（Codable + Sendable）
│   ├── Services/      #   USBService / PowerService / DisplayService / ThunderboltService / RegistryService
│   ├── Monitor/       #   CableMonitor：快照组合 + 事件流（AsyncStream）
│   └── Rating/        #   CableRatingEngine：历史峰值 → 线缆评级，按线缆会话分桶（纯 Swift，可单测）
├── CableScopeCLI/     # 命令行工具
└── CableScopeApp/     # SwiftUI 菜单栏 App（MenuBarExtra + 主窗口 + Swift Charts 功率曲线）
Tests/
├── CableKitTests/       # 126 个测试：数据契约、按端口分桶评级引擎 + 旧格式迁移、端口分组、六组解析器（真机样例回归）+ 诊断/评级存储/真机冒烟
└── CableScopeCLITests/  # 34 个测试：参数解析、格式化、watch 快照差异计算
Docs/                  # 数据获取指南 / 优化路线图
scripts/bundle_app.sh  # .app 打包脚本
```

## 数据来源（详见 [Docs/03-数据获取指南.md](Docs/03-数据获取指南.md)）

- **USB**：IOKit `IOUSBHostDevice`（协商速率、LocationID、VID/PID）
- **充电**：IORegistry `AppleSmartBattery`（瞬时功率 = `AdapterDetails.AdapterVoltage` × 顶层 `Amperage`；PD 合同 = `AdapterDetails` 合同值）+ IOKit.ps 备用电量
- **显示器**：CoreGraphics（分辨率/刷新率）+ `NSScreen.localizedName`（macOS 26 移除了 CGDisplayProductName）
- **雷电**：`system_profiler SPThunderboltDataType -json` 递归展平

## 开发状态

- [x] CableKit 适配层（USB/电源/显示器/雷电 + 快照流 + 评级引擎）— 164/164 测试通过（含 CLI 测试 target）
- [x] CLI 五个子命令（真机验证：PD 合同识别、e-marker 推断、评级持久化）
- [x] macOS 菜单栏 App（整机概览、每线一卡 + 线缆详情、实时功率曲线、端口评级）
- [x] IOKit 属性检查器（App 专属窗口 + CLI `properties` 子命令；快照携带全量 `rawProperties`）
- [x] 多线缆布局（按物理端口聚合线缆会话：USB 根端口分组 + 雷雳 receptacle 编号，旧 ratings.json 自动迁移）
- [x] 插拔系统通知（UNUserNotificationCenter）
- [ ] USB 实测吞吐（5 秒读写测速）
- [ ] IOKit 通知替代轮询、正式分发（公证）、App 图标

### 已知限制

- e-marker 直读需要 Apple Silicon（AppleHPM）；Intel/老机型以及无 e-marker 线缆的评级为"基于协商峰值的下限推断"，UI/CLI 均已标注；品牌规格仍不可读取。
- 显示器与充电功率**无法归属到具体某根线**（macOS 只暴露当前活跃适配器，显示器也没有端口映射数据）：固定挂在整机概览；仅接一根线时充电状态自动提升到该线卡片。
- 端口名暂为技术格式（"USB 端口 0x014" / "雷雳端口 2"），左/右物理方位需要更深层的 registry 端口拓扑工作（v2）。
- 内置显示器无 DP link rate 字段，`linkRateLabel` 需接外接 DP/雷电显示器才会生效。
- `watch`/快照流当前为内容变化检测 + 兜底轮询（IOKit 通知桥接在 roadmap）。
- `.app` 打包脚本适用于本地使用；App Store/公证分发建议后续迁移 Xcode 工程。

## 参与贡献

欢迎贡献！本地构建（`swift build` / `swift test`）、代码结构一分钟导览、PR 指引（含 `usb-vendors.json` 厂商条目格式与真机 fixture 测试要求）与措辞红线，见 [CONTRIBUTING.md](CONTRIBUTING.md)。

提交 issue 时请附：机型与芯片（Apple Silicon / Intel）、macOS 版本，以及相关 IOKit 类的 IORegistry 输出（如 `swift run CableScopeCLI properties <类名> --json`）。

## 许可证

[MIT](LICENSE)。CableScope 的全部数据均在本机采集与存储（无遥测、无网络请求），详见 [PRIVACY.md](PRIVACY.md)。
