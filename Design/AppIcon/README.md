# CableScope App Icon

「端口评级环」：一段 220° 开口弧线代表**评级仪表**（CableScope 独有的线缆能力评级功能），USB-C 接口安放在弧线的圆心/开口正下方，像是仪表正在读取这个接口。

## 文件

| 文件 | 用途 |
| --- | --- |
| `AppIcon.svg` | 分层母版（`background` / `foreground` 两组），用于预览与归档 |
| `AppIcon-foreground.svg` | 前景层（弧线仪表 + USB-C 接口），拖入 Icon Composer 作为前景图层 |
| `AppIcon-background.svg` | 背景层（满幅渐变），可拖入 Icon Composer，或直接在工具内选预设渐变 |
| `AppIcon-middle.svg` | 中间层（光晕）**当前不使用**——`CableScope.icon` 里这层是 hidden，`AppIcon.svg` 母版也未引用；文件留着，以后想加回光晕再拖入 |
| `CableScope.icon` | Icon Composer 导出的分层图标包（背景 + 前景两个可见图层，光晕层 hidden + `icon.json` 参数），Xcode 26 / `actool` 可直接消费 |
| `preview-*.png` | Icon Composer 导出的 **真实** Liquid Glass 渲染（Default 外观，含系统遮罩与高光），不是模拟图 |

## macOS 26 规范对照（Liquid Glass）

- **1024×1024 统一画布**：Mac 与 iPhone/iPad 同尺寸网格。
- **不内置遮罩**：源文件不含圆角矩形/超椭圆遮罩，由系统自动裁切并加 specular 高光。
- **图层 ≤ 4 组 + 背景**：母版当前仅用 2 层（背景、标记），光晕层暂不启用，留有余量。
- **图层保持扁平**：无内建投影/高光，玻璃质感（specular、translucency、模糊、阴影）由 Icon Composer 按组施加。
- **单色/着色模式可读**：接口描边为纯白，弧线为品牌蓝渐变；着色（Tinted）与单色（Mono）外观下两者都会转为系统指定的单一色调，但弧线在上、接口在下，形状分离，仍能分辨主体。
- **粗描边、两个焦点**：弧线描边 48px、接口描边 40px（约画布 4.7% / 3.9%），32px 下仍可辨认，见 `preview-32.png`。
- **安全区**：标记整体外接矩形 (230.1, 319.5)–(793.9, 704.5)，中心精确落在画布几何中心 (512, 512)，不会被遮罩裁切。

## 导入 Icon Composer（Xcode 26 自带，逐步操作）

Icon Composer 是 Xcode 26 附带的独立 App，不在 Xcode 主窗口内；命令行/脚本无法驱动它，以下步骤需要手工在图形界面里完成。

1. **启动 Icon Composer**：⌘+Space 打开 Spotlight，搜索 "Icon Composer" 直接打开；如果没搜到，去 `Xcode.app/Contents/Applications/Icon Composer.app`（Finder 里对 Xcode.app 右键"显示包内容"能找到）。
2. **新建文档**：File → New（⌘N），得到一块 1024×1024 画布，左侧是图层列表，右上通常有 Default / Dark / Tinted / Clear 外观切换。
3. **拖入背景层**：Finder 打开本目录，把 `AppIcon-background.svg` 直接拖到 Icon Composer 的背景层位置（也可以不拖文件，改在画布 Inspector 里选系统渐变预设）。
4. **拖入前景层**：把 `AppIcon-foreground.svg` 拖入作为前景层（弧线仪表 + USB-C 接口）。中间层（光晕）当前不用，跳过；如果以后想试试加回去，`AppIcon-middle.svg` 已经是现成文件，直接拖入即可。
5. **调整 Liquid Glass 效果**：选中前景层组，右侧 Inspector 可开关 specular highlight、调 translucency/refraction 强度；如果接口的描边在开启 specular 后出现过度"褶皱感"，关掉该组的 specular 即可，弧线层可以保留默认效果。
6. **逐一切换外观检查**：Default / Dark / Tinted / Clear 都点一遍，重点看 Tinted/Mono——系统会把前景转成单一色调，确认弧线和接口两个形状仍然分得清（因为二者上下分离，不靠颜色区分，应该没问题）。
7. **检查小尺寸**：用 Icon Composer 的尺寸预览条看 16/32/64px 下是否还清楚。
8. **保存 / 导出**：`.icon` 是 Icon Composer 唯一的原生格式（不是"众多格式里选一个"），实测菜单里没有格式选择弹窗——直接 File → Save（⌘S）保存下来的就是 `.icon` 包；已保存为本目录下的 `CableScope.icon`。需要单独导出某个外观/尺寸的 PNG 做核对时，用 File → Export 按点数（pt）+ 倍率（@1x/@2x/@3x）选具体规格。
9. **验证尺寸**：不需要为发布逐一手工导出各尺寸——`.icon` 是矢量图层，Xcode/`actool` 在编译时会自动为所有尺寸和 Default/Dark/Tinted/Clear 四种外观生成对应位图。导出 PNG 只是为了在这里存一份可以直接打开看的真实渲染效果（见下方 `preview-*.png`），不是构建的必需品。
10. **接入 Xcode 工程（待验证）**：`xcodegen generate` 生成 `CableScope.xcodeproj`（该文件本身不入库）后用 Xcode 打开，尝试把 `CableScope.icon` 拖进项目导航器、在 `CableScopeApp` Target 的 App Icon 设置里选中它作为图标源——这一步 xcodegen/`project.yml` 是否需要额外配置尚未实测验证，建议先在 Xcode 里手动试一次，确认可行后再考虑要不要把配置写回 `project.yml`。在验证通过前，`project.yml` 仍然指向 `Packaging/assets/AppIcon.xcassets`（经典 PNG appiconset），构建不受影响。

## 备注

- `preview-*.png` 和真机遮罩、玻璃高光效果一致（Icon Composer 原生导出，不是近似模拟）；但**不能**拿来当 `Packaging/assets/AppIcon.xcassets` 或 `.icns` 的源图——appiconset/icns 需要不带遮罩、不带阴影的满幅方图，两者用途不同，appiconset 那份仍然从 `AppIcon.svg` 走 `qlmanage`/`sips` 生成（见仓库里现成的 `icon_512x512@2x.png`）。
- 菜单栏图标是另一套资产（template image / SF Symbol），与应用图标无关。
- 旧系统 `.icns`：`scripts/bundle_app.sh` 已经在打包时自动从 `Packaging/assets/AppIcon.xcassets/AppIcon.appiconset/icon_512x512@2x.png` 派生，不需要额外操作。
