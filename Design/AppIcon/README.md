# CableScope App Icon

「聚焦接口」：柔黑渐变背景上，一条左右对称的探测环包围 USB-C 接口，接口内部增加横向舌片以强化 Type-C 识别。前景使用单一浅色和粗线条，兼顾大尺寸品牌表达与小尺寸辨识度。

## 文件与用途

| 文件 | 用途 |
| --- | --- |
| `AppIcon.svg` | 不带遮罩的完整 SVG 母版，含 `background` / `foreground` 两组 |
| `AppIcon-background.svg` | 1024×1024 的柔黑渐变背景层 |
| `AppIcon-foreground.svg` | 透明背景的探测环和接口前景层；曲线使用 Bézier 命令，以兼容 Icon Composer 的 SVG 导入 |
| `CableScope.icon` | Xcode 使用的 Icon Composer 图标包，内含背景及前景图层；旧光晕层保留为隐藏状态 |
| `preview-1024.png`、`preview-64.png`、`preview-32.png` | 从完整 SVG 渲染的平面预览，**不包含**系统遮罩或 Liquid Glass 效果 |
| `generate-statusbar-glyph.swift` | 由同一造型生成菜单栏 template 图标（`Sources/CableScopeApp/Resources/StatusBarGlyph.pdf`）的脚本 |

画布不内置圆角遮罩，背景铺满整个画布。前景以画布中心为对称轴，接口居中；颜色和线条不依赖文字或细节区分。

## 更新图标

1. 修改完整 SVG 与前景、背景 SVG，并同步 `CableScope.icon/Assets/` 中对应的图层。使用 Icon Composer 打开图标包，检查 Default、Dark、Tinted、Clear 外观及小尺寸效果。
2. 从 `AppIcon.svg` 渲染不带遮罩的 1024×1024 PNG，然后用 `sips` 缩放到 `Packaging/assets/AppIcon.xcassets/AppIcon.appiconset/Contents.json` 中的全部尺寸。不要使用带系统遮罩或阴影的预览作为母图。
3. 更新 `preview-*.png`，并注明它们是平面预览还是 Icon Composer 导出的系统效果。
4. 运行 `xcodegen generate` 和 Xcode 构建验证图标包编译；运行 `scripts/bundle_app.sh` 验证 SwiftPM 打包路径。
5. **重新生成菜单栏图标**：`swift Design/AppIcon/generate-statusbar-glyph.swift Sources/CableScopeApp/Resources/StatusBarGlyph.pdf`。它不会跟着 appiconset 自动更新——漏掉这一步，App 图标换了、菜单栏还停在旧造型。

Xcode 构建将 `.icon` 和经典 appiconset 编译进资源目录。SwiftPM/DMG 打包不使用 `.icon`，`scripts/bundle_app.sh` 从 appiconset 的 `icon_512x512@2x.png` 派生 `.icns`。菜单栏图标是独立资源（`StatusBarGlyph.pdf`），由上面的脚本按 72×54pt 单色 template 生成，以 15×11.25pt 显示。
