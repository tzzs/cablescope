# Changelog

## [0.4.0](https://github.com/tzzs/cablescope/compare/v0.3.0...v0.4.0) (2026-09-20)


### Features

* **build:** 新增 App 的 Homebrew formula，源码构建绕开公证依赖 ([ba87dfd](https://github.com/tzzs/cablescope/commit/ba87dfd46bf58766718015be0387568da7589048))
* **build:** 新增 App 的 Homebrew formula，源码构建绕开公证依赖 ([fc8cac2](https://github.com/tzzs/cablescope/commit/fc8cac23d19eba867d96e26a9c9db2a94a2ea976))

## [0.3.0](https://github.com/tzzs/cablescope/compare/v0.2.1...v0.3.0) (2026-09-19)


### Features

* **build:** 发布流水线改名 Publish，新增手动补发入口与未公证提示 ([a1f91ed](https://github.com/tzzs/cablescope/commit/a1f91ed14b663c1f1e01e7a7ba8aa5efad6f6274))
* **build:** 发布流水线改名 Publish，新增手动补发入口与未公证提示 ([2eba35b](https://github.com/tzzs/cablescope/commit/2eba35b832028634cc34e5928696aef846e410b1))
* **build:** 新增 CLI 的 Homebrew formula，App 与 CLI 分作两个独立包 ([488f89a](https://github.com/tzzs/cablescope/commit/488f89a645f3ee4a26e6e3c100dd218673f77b73))
* **build:** 新增 CLI 的 Homebrew formula，App 与 CLI 分作两个独立包 ([25f096f](https://github.com/tzzs/cablescope/commit/25f096f1d6b64a7a38c98627c823b438025569eb))


### Bug Fixes

* **build:** 手动补发路径加两道护栏 ([84b0121](https://github.com/tzzs/cablescope/commit/84b01218636e10191f4e983e35c0d7331abf315e))
* **build:** 手动补发路径加两道护栏，避免降级 tap 与缺模板时炸掉 ([9ef504e](https://github.com/tzzs/cablescope/commit/9ef504e64838e411741d5e072d71dff0a6ded7c7))

## [0.2.1](https://github.com/tzzs/cablescope/compare/v0.2.0...v0.2.1) (2026-09-19)


### Bug Fixes

* **build:** 修复发版链路断点，release-please 恢复打 tag 与建 Release ([16a4a58](https://github.com/tzzs/cablescope/commit/16a4a5887b7ea9ebd54a45a4f1d702f9fefe1e97))
* **build:** 修复发版链路断点，release-please 恢复打 tag 与建 Release ([ff09b5e](https://github.com/tzzs/cablescope/commit/ff09b5e516ecaada6a8034f4465195a92eebb7c1))

## [0.2.0](https://github.com/tzzs/cablescope/compare/v0.1.0...v0.2.0) (2026-09-17)


### Features

* **app:** CableScope macOS 菜单栏应用与打包脚本 ([baaee16](https://github.com/tzzs/cablescope/commit/baaee16f4a74ef0e2ff58229b38f26f1568449ba))
* **app:** 主窗口工具栏化、菜单勾选项统一、状态栏品牌图标 ([87f8d5a](https://github.com/tzzs/cablescope/commit/87f8d5a5631faaee302ee8c2593a08b712408de8))
* **app:** 会话详情页身份信息分层展示、PD 档位组件复用、Dock 图标显示开关 ([16da4fb](https://github.com/tzzs/cablescope/commit/16da4fbecfe7d4eb554d21750272de5feea973be))
* **app:** 吞吐实测接入菜单栏 App，文档过期描述清偿 ([1fa074e](https://github.com/tzzs/cablescope/commit/1fa074ec4a3ef8c9f8f9497660de4711c3d3a09b))
* **app:** 多线缆 UI、端口/诊断/PD 档位接入、插拔通知、检查更新 ([471ed01](https://github.com/tzzs/cablescope/commit/471ed0105e959c122fc5e03e68459dc089fe22ea))
* **app:** 雷雳设备按拓扑深度缩进（详情区与 CLI pretty 同步） ([ec9b949](https://github.com/tzzs/cablescope/commit/ec9b949ebc04095c05bace4646e9b2983ebf9d9f))
* **build:** add release-please for automated version PRs and tagging ([4c91671](https://github.com/tzzs/cablescope/commit/4c91671a5931fbc7b238b8bad929dcf393dc1fe8))
* **build:** add release-please for automated version PRs and tagging ([09d6c71](https://github.com/tzzs/cablescope/commit/09d6c71f5ef400dda75743f2861958570f6fb682))
* **build:** 发版自动同步 Homebrew cask 到独立 tap 仓库 ([10de3d9](https://github.com/tzzs/cablescope/commit/10de3d97d24fbaeba541e13e76de9ada555b7d85))
* **cablekit:** IOKit 适配层、快照流与线缆评级引擎 ([27f71c9](https://github.com/tzzs/cablescope/commit/27f71c920b46539764525b82ced6a07732607ec2))
* **cli:** CableScopeCLI 命令行工具 ([0ccb8a8](https://github.com/tzzs/cablescope/commit/0ccb8a8d89f1d4e1e263b7bc9183ea95fe7d735b))
* **cli:** pretty/watch/rating 接入端口数据，新增 throughput 子命令 ([ff596a9](https://github.com/tzzs/cablescope/commit/ff596a9c0b7912cfe7ff4e1c4e41506bb602b747))
* DisplayPort 传输节点直读，外接显示器精确归属到线缆卡片 ([779091e](https://github.com/tzzs/cablescope/commit/779091e46794e57fbcd9de8e0c887cef25b28d13))
* **kit:** IOKit 属性检查器同类名条目按端口序号消歧 ([d1d6064](https://github.com/tzzs/cablescope/commit/d1d60642c7edda8f562bef64e0fb6a26eac304bb))
* **kit:** USB-C 端口控制器直读数据层 + 充电诊断 + 评级存储统一 ([af4243b](https://github.com/tzzs/cablescope/commit/af4243b791ecb0e00a52129fb825bc8214af255d))
* **kit:** VID 厂商目录、e-marker 可信度信号、雷雳代际、吞吐测速 ([15678ba](https://github.com/tzzs/cablescope/commit/15678baa5e89d979709b537f1db270654c91a502))
* **kit:** 雷雳 120G 非对称代际修复与设备拓扑深度字段 ([f5877f5](https://github.com/tzzs/cablescope/commit/f5877f5abd0228bc1f847c532ba7dc868b6450c4))
* **widget:** CableScope 桌面小组件 ([01df6ec](https://github.com/tzzs/cablescope/commit/01df6ec11f5c0ccc44e0d877bfc10b5135e640a4))
* 设置页 + 语言/主题切换 + 线缆变化通知扩展 ([0f10863](https://github.com/tzzs/cablescope/commit/0f10863f4208137b416f9b9c34a31e7430a66fd2))


### Bug Fixes

* **app:** 主窗口工具栏充电状态图标化，与操作按钮对齐 ([1c96a3f](https://github.com/tzzs/cablescope/commit/1c96a3f65183a28af2a5a6574970326ccc2e318e))
* **app:** 主窗口工具栏移除充电状态图标 ([354bccf](https://github.com/tzzs/cablescope/commit/354bccfb12b62ab91daab9a99f21a013d6a403e6))
* **app:** 启动时自动呈现主窗口 ([7b536b5](https://github.com/tzzs/cablescope/commit/7b536b53474eceace689ba8b0df8072185f52204))
* **app:** 工具栏图标配色统一、主窗口加设置入口、去掉设置的省略号 ([f1f0550](https://github.com/tzzs/cablescope/commit/f1f055093733dacb367993652dd8a065ea30311c))
* **app:** 菜单项文字增加左右内边距，避免贴着高亮背景边缘 ([5178eb4](https://github.com/tzzs/cablescope/commit/5178eb4f8ecc4fd1db57ed402c7449fd72322dcc))
* **app:** 设置页按 HIG 规范重排，消除四周大片空白 ([7444fb5](https://github.com/tzzs/cablescope/commit/7444fb5f098647a1c2399b8709e2360bb5ae3892))
* **app:** 语言切换遗漏文案、通知授权提醒、未签名构建下的通知崩溃 ([3667b85](https://github.com/tzzs/cablescope/commit/3667b852a77d69414a366e9ddeca96a239ea3942))
* **kit:** Bundle.module 资源整体缺失时崩溃改为安全回退 ([2fb4f85](https://github.com/tzzs/cablescope/commit/2fb4f85b928e8827d190a17ee202c15adb0875a8))
* **kit:** CableKit 英文文案改用经典 .strings，不依赖 SwiftPM 编译 .xcstrings ([5401f72](https://github.com/tzzs/cablescope/commit/5401f7248e8e657ee10d4f1598a021817357cc56))
* **kit:** CI 工具链下资源 bundle 探测漏掉与 .xctest 同级路径 ([581e997](https://github.com/tzzs/cablescope/commit/581e9970bfb2565d80a12d728d7a4f9abfa0bd31))
* **kit:** CI 工具链下资源 bundle 探测漏掉与 .xctest 同级路径 ([9c60992](https://github.com/tzzs/cablescope/commit/9c60992db0ccc4df5a98b044b0fc5c51c8d3e32c))
* **kit:** 吞吐实测候选卷排除只读挂载卷，避免选中即报空间不足 ([c1cdc2e](https://github.com/tzzs/cablescope/commit/c1cdc2ed851379cc2cd756fdfeb4bdf6e3d8214c))
* SwiftPM 裸运行通知中心崩溃、打包脚本资源 bundle 缺失、构建告警清理（Swift 6 并发 + 过时 API） ([c0defcd](https://github.com/tzzs/cablescope/commit/c0defcd9574ff5d63cb3013bebbffe5f3f60df29))
