import AppKit
import SwiftUI

/// CableScope 品牌线缆图标：状态栏图标和菜单面板标题共用。
///
/// 直接复用 App 图标（`Design/AppIcon`）的造型——弧形评级表盘 + USB-C 端口——而不是
/// 借用语义相近但造型不同的系统 SF Symbol「cable.connector」（普通线缆插头图案）。
/// `StatusBarGlyph.pdf` 是该造型按等比例简化出的单色矢量稿：PDF 是 AppKit 里历史最久、
/// 最可靠的分辨率无关模板图格式，`isTemplate = true` 后会像 SF Symbol 一样自动跟随
/// 菜单栏 / 深浅色模式的前景色着色。
enum BrandGlyph {
    /// PDF 原生画布是 72×54pt（矢量设计尺寸），直接拿来当状态栏图标会明显偏大偏粗——
    /// `MenuBarExtra` 的状态项图标走的是 AppKit 的 `NSStatusBarButton` 渲染管线，
    /// 认的是 `NSImage.size` 这个属性本身，SwiftUI 这边后续叠加的 `.frame()` 并不能
    /// 覆盖它。所以按目标尺寸直接改写 `size`，而不是指望 `.resizable()+.frame()`。
    static func image(size: CGSize) -> Image {
        guard let url = Bundle.module.url(forResource: "StatusBarGlyph", withExtension: "pdf"),
              let nsImage = NSImage(contentsOf: url) else {
            return Image(systemName: "cable.connector")
        }
        nsImage.size = size
        nsImage.isTemplate = true
        return Image(nsImage: nsImage)
    }
}
