import CoreGraphics
import Foundation

// 菜单栏 glyph 生成器：只保留 App 图标里的 USB-C 接口造型，按 72×54pt
// 画布放大重绘成单色 template PDF。探测环属于大尺寸 App 图标的第二层语义，
// 在 15×11.25pt 的状态栏槽位中会挤压接口，因而在这里按小尺寸做响应式简化。
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/StatusBarGlyph.pdf"

let canvasW: CGFloat = 72
let canvasH: CGFloat = 54

var box = CGRect(x: 0, y: 0, width: canvasW, height: canvasH)
let url = URL(fileURLWithPath: out)
guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else {
    FileHandle.standardError.write(Data("cannot create pdf context\n".utf8)); exit(1)
}
ctx.beginPDFPage(nil)
ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
ctx.setLineCap(.round)
ctx.setLineJoin(.round)

// USB-C 接口：放大到接近画布宽度，保持圆角胶囊端。
let portRect = CGRect(x: 3.5, y: 12, width: 65, height: 30)
ctx.setLineWidth(6.5)
ctx.addPath(CGPath(roundedRect: portRect, cornerWidth: 15, cornerHeight: 15, transform: nil))
ctx.strokePath()

// 内部舌片：与 App 图标同样的居中横向结构，在小尺寸下保留 Type-C 识别点。
ctx.setLineWidth(5)
ctx.move(to: CGPoint(x: 20, y: 27))
ctx.addLine(to: CGPoint(x: 52, y: 27))
ctx.strokePath()

ctx.endPDFPage()
ctx.closePDF()
print("wrote \(out)")
