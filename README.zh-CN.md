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
| 🖥 视频 | 显示器列表、分辨率/刷新率、DP 链路速率；外接显示器可精确归属到具体线缆卡片（DisplayPort 传输节点直读端口归属 + EDID 身份匹配） |
| 🎛 端口控制器 | Apple Silicon 直读 USB-C 端口控制器（AppleHPM / AppleTC）：端口状态、插拔方向、支持的传输能力（CC / USB2 / USB3 / USB4 / DisplayPort）；Intel/老机型自动降级为推断模式 |
| 🧬 e-marker | 直读线缆 e-marker 芯片（SOP' Discover Identity）：线缆速度档、3A / 5A 电流评级、厂商 ID + 产品类型 |
| 🏷 评级 | 基于历史协商峰值的线缆能力卡，持久化到本地（按端口分桶，拔线不清零） |
| 🧵 多线缆 | 设备按物理端口聚合为线缆会话（USB 根端口分组 + 雷雳 receptacle 编号）：主窗口每线一张卡片 + 可切换的详情区，菜单栏每线一行，CLI 输出按端口分组 |
| 🧩 Widget | 桌面小组件（功率/电量、各端口头条）；跟随 App 的语言与主题设置 |
| 🔔 通知 | 插拔系统通知（UNUserNotificationCenter）；未打包运行（无 bundle）时静默禁用 |
| 🔬 IOKit 检查器 | 任意 IOKit 类的 IORegistry **全量原始属性**（USB 设备、电池、显示器连接、雷电端口…）：App 专属窗口 + CLI 子命令；快照 JSON 亦携带各设备 `rawProperties` |

## 安装

CableScope 提供**两个独立的产品**，可以只装其一，也可以都装。二者共用 `CableKit` 数据层，但分发渠道彼此独立，互不冲突。

**菜单栏 App**

```bash
brew install --cask tzzs/tap/cablescope
```

从 [最新 GitHub Release](https://github.com/tzzs/cablescope/releases) 的已公证（notarized）DMG 安装 `CableScope.app` 到 `/Applications`，在访达与启动台中显示为 **CableScope**。

> cask 只有在存在已公证构建时才会发布。在那之前请改用下面的 CLI，或直接从 Release 页面下载 DMG，首次打开时在「系统设置 → 隐私与安全性」中放行。

**命令行工具**

```bash
brew install tzzs/tap/cablescope-cli
```

在你的机器上从源码编译，安装 `cablescope` 命令。编译期需要 Xcode 15+ 工具链，但**不需要任何代码签名** —— 因此不受 App 签名状态影响，随时可用。

```bash
cablescope pretty
```

[tzzs/homebrew-tap](https://github.com/tzzs/homebrew-tap) 中的 cask 与 formula 都会在每次发版时自动更新，无需手动维护。

## 快速开始

如需从源码构建，要求：macOS 14+，Swift 5.10+ 工具链（Xcode 15+）。

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
| `throughput` | 可选的 U 盘实测吞吐基准（写入临时测试文件读写测速；`--volume <路径\|卷名>` 选卷，`--seconds N` 调整每阶段时长，默认 5 秒） |

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
├── CableKitTests/       # 176 个测试：数据契约、按端口分桶评级引擎 + 旧格式迁移、端口分组、解析器（真机样例回归）、诊断、厂商库、评级存储、IORegistry 检查器、profiler 缓存 + 真机冒烟
├── CableScopeCLITests/  # 43 个测试：参数解析（含 throughput）、格式化、watch 快照差异计算
└── CableScopeAppTests/  # 34 个测试：更新检查版本号比较、通知偏好开关逻辑、英文本地化、视图层文案格式化、MonitorViewModel 对真实 CableMonitor 的冒烟测试
Docs/                  # 数据获取指南 / 优化路线图
scripts/bundle_app.sh     # .app 打包脚本
scripts/check_layering.sh # 分层规则检查（CableKit 之外禁止直接碰 IOKit/CoreGraphics/system_profiler）
```

## 数据来源（详见 [Docs/03-数据获取指南.md](Docs/03-数据获取指南.md)）

- **USB**：IOKit `IOUSBHostDevice`（协商速率、LocationID、VID/PID）
- **充电**：IORegistry `AppleSmartBattery`（瞬时功率 = `AdapterDetails.AdapterVoltage` × 顶层 `Amperage`；PD 合同 = `AdapterDetails` 合同值）+ IOKit.ps 备用电量
- **显示器**：CoreGraphics（分辨率/刷新率）+ `NSScreen.localizedName`（macOS 26 移除了 CGDisplayProductName）
- **雷电**：`system_profiler SPThunderboltDataType -json` 递归展平

## 开发状态

- [x] CableKit 适配层（USB/电源/显示器/雷电 + 快照流 + 评级引擎）— 253/253 测试通过（含 CLI 与 App 测试 target）
- [x] CLI 六个子命令（真机验证：PD 合同识别、e-marker 推断、评级持久化）
- [x] macOS 菜单栏 App（整机概览、每线一卡 + 线缆详情、实时功率曲线、端口评级）
- [x] IOKit 属性检查器（App 专属窗口 + CLI `properties` 子命令；快照携带全量 `rawProperties`）
- [x] 多线缆布局（按物理端口聚合线缆会话：USB 根端口分组 + 雷雳 receptacle 编号，旧 ratings.json 自动迁移）
- [x] 插拔系统通知（UNUserNotificationCenter）
- [x] USB 实测吞吐（CLI `throughput` 子命令 + App「吞吐实测」区：挂载卷读写测速）
- [x] IOKit 通知替代轮询（AppleSmartBattery 兴趣通知 + USB 匹配通知 + 轮询兜底的混合模式）
- [x] App 图标（经典 Assets.car appiconset + Icon Composer Liquid Glass 分层，Xcode 与 SwiftPM/DMG 两路均已接入）
- [ ] 正式分发 —— 发版自动化已跑通（release-please → tag → 构建发布 → 同步 Homebrew tap），CLI 的 formula 不需要签名即可发布；已公证的 App 发布仍待配置 Apple 开发者 secrets（`APPLE_ID` / `APPLE_TEAM_ID` / `APPLE_APP_SPECIFIC_PASSWORD` / `DEVELOPER_ID_APPLICATION`）

### 已知限制

- e-marker 直读需要 Apple Silicon（AppleHPM）；Intel/老机型以及无 e-marker 线缆的评级为"基于协商峰值的下限推断"，UI/CLI 均已标注；品牌规格仍不可读取。
- 充电功率在多线时**无法归属到具体某根线**（macOS 只暴露当前活跃适配器；多根线同时插着时，除非恰好只有一个端口在协商合同，否则分不清是哪根线在收电）：这种情况下固定挂在整机概览；仅接一根线时充电状态自动提升到该线卡片。
- 外接显示器**已可**归属到具体某根线：`IOPortTransportStateDisplayPort` 传输节点自己上报归属的 USB-C/MagSafe 端口（`DisplayPortTransportService` + `PortGrouping.displayPortLinks`），再按 EDID 身份匹配到具体的 `CGDirectDisplayID`（`PortGrouping.matchedDisplay`）取到分辨率/刷新率。EDID 匹配不唯一时（如坞站带两台同型号显示器）只展示链路自身已知的厂商/型号信息，不猜分辨率。
- 端口名暂为技术格式（"USB 端口 0x014" / "雷雳端口 2"），左/右物理方位需要更深层的 registry 端口拓扑工作（v2）。
- 内置显示器无 DP link rate 字段，`DisplaySnapshot.linkRateLabel`（system_profiler 尽力而为解析）需接外接 DP/雷电显示器才会生效；线缆卡片上的 DisplayPort 链路速率（`DisplayPortLinkSnapshot.linkRateDescription`）来自专门的传输节点，链路存在时恒可靠有值。
- `watch`/快照流为事件驱动唤醒（AppleSmartBattery 兴趣通知 + USB 匹配通知）+ 兜底轮询的内容变化检测。
- 两处 `system_profiler` 读取（显示器信息、雷雳拓扑）带缓存，以保证常驻菜单栏的开销足够低（实测 `watch` 每 20 秒的 CPU 从 3.15s 降到 0.40s）。显示器变化会立即失效缓存（缓存 key 就是在线显示器 ID 集合），但新接入的**雷雳设备**最多需要 5 秒才会出现——雷雳没有同等便宜的变化探针。
- `.app` 打包脚本适用于本地使用；App Store/公证分发建议后续迁移 Xcode 工程。

## 参与贡献

欢迎贡献！本地构建（`swift build` / `swift test`）、代码结构一分钟导览、PR 指引（含 `usb-vendors.json` 厂商条目格式与真机 fixture 测试要求）与措辞红线，见 [CONTRIBUTING.md](CONTRIBUTING.md)。

提交 issue 时请附：机型与芯片（Apple Silicon / Intel）、macOS 版本，以及相关 IOKit 类的 IORegistry 输出（如 `swift run CableScopeCLI properties <类名> --json`）。

## 许可证

[MIT](LICENSE)。CableScope 的全部数据均在本机采集与存储（无遥测、无网络请求），详见 [PRIVACY.md](PRIVACY.md)。
