# CableScope App Icon

「线圈 + 脉冲」：线缆绕成的粗环代表 **Cable**，一道白色示波器脉冲穿过环口代表 **Scope**（实时协商信号）；环形轮廓同时构成 CableScope 的首字母 **C**。

## 文件

| 文件 | 用途 |
| --- | --- |
| `AppIcon.svg` | 分层母版（`background` / `middle` / `foreground` 三组），用于预览与归档 |
| `AppIcon-foreground.svg` | 前景层（扁平矢量标记），拖入 Icon Composer 作为图层 |
| `AppIcon-background.svg` | 背景层（满幅渐变），可拖入 Icon Composer，或直接在工具内选预设渐变 |
| `preview-*.png` | 快速预览（模拟 macOS 26 Dock 圆角遮罩，非真实玻璃渲染） |

## macOS 26 规范对照（Liquid Glass）

- **1024×1024 统一画布**：Mac 与 iPhone/iPad 同尺寸网格。
- **不内置遮罩**：源文件不含圆角矩形/超椭圆遮罩，由系统自动裁切并加 specular 高光。
- **图层 ≤ 4 组 + 背景**：母版仅用 3 层（背景、光晕、标记），留有余量。
- **图层保持扁平**：无内建投影/高光，玻璃质感（specular、translucency、模糊、阴影）由 Icon Composer 按组施加。
- **单色/着色模式可读**：波形为纯白，着色（Tinted）与单色（Mono）外观下仍有明确主体。
- **粗描边、单一焦点**：主环描边 80px、脉冲 46px（约画布 7.8% / 4.5%），32px 下仍可辨认。
- **安全区**：标记整体位于画布中央约 75% 区域内，不会被遮罩裁切。

## 导入 Icon Composer（Xcode 26 自带）

1. 新建文档，画布 1024。
2. 背景层：拖入 `AppIcon-background.svg`，或在画布 Inspector 里选系统渐变预设（官方预设已针对新材质调优）。
3. 中间层（可选）：光晕在 `AppIcon.svg` 的 `middle` 组里，需要视差深度时把该组单独存成 SVG 拖入（省略也不影响主体）。
4. 前景层：拖入 `AppIcon-foreground.svg`；每组按需开启 Liquid Glass，若细窄处出现过度褶皱感，可关闭该组 specular。
5. 逐一切换 Default / Dark / Tinted / Clear 外观检查对比度。
6. 导出 `CableScope.icon`，拖入 Xcode 资产目录，在 Target 设置中选择该 App Icon（`.icon` 由 actool 编译，向下兼容旧系统时自动回退 `.icns`/PNG）。

## 备注

- 预览 PNG 的圆角（rx≈232）只是近似，真实遮罩与玻璃高光以系统渲染为准。
- 菜单栏图标是另一套资产（template image / SF Symbol），与应用图标无关。
- 若需要旧系统 `.icns`：可用 `preview-1024.png` 通过 `iconutil` 生成 iconset。
