# CableScope App Icon

「端口评级环」：一段 220° 开口弧线代表**评级仪表**（CableScope 独有的线缆能力评级功能），USB-C 接口安放在弧线的圆心/开口正下方，像是仪表正在读取这个接口。

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
- **单色/着色模式可读**：接口描边为纯白，弧线为品牌蓝渐变；着色（Tinted）与单色（Mono）外观下两者都会转为系统指定的单一色调，但弧线在上、接口在下，形状分离，仍能分辨主体。
- **粗描边、两个焦点**：弧线描边 48px、接口描边 40px（约画布 4.7% / 3.9%），32px 下仍可辨认，见 `preview-32.png`。
- **安全区**：标记整体外接矩形 (230.1, 319.5)–(793.9, 704.5)，中心精确落在画布几何中心 (512, 512)，不会被遮罩裁切。

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
