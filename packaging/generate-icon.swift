import AppKit
import CoreGraphics
import Foundation

// 画 1024×1024 的 App 图标:深蓝 squircle 底 + 双层进度环 + 中心 T
func render(size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    let r = CGRect(x: 0, y: 0, width: size, height: size)
    let s = size / 1024.0  // 缩放因子

    // 1. squircle 背景:深蓝渐变(圆角矩形,macOS 图标标准 superellipse 近似用大圆角)
    let bgPath = NSBezierPath(roundedRect: r.insetBy(dx: 0, dy: 0), xRadius: size*0.223, yRadius: size*0.223)
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [NSColor(red: 0.10, green: 0.16, blue: 0.32, alpha: 1).cgColor,
                 NSColor(red: 0.06, green: 0.09, blue: 0.20, alpha: 1).cgColor] as CFArray,
        locations: [0, 1])!
    ctx.saveGState()
    ctx.addPath(bgPath.cgPath)
    ctx.clip()
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])
    ctx.restoreGState()

    let center = CGPoint(x: size/2, y: size/2)

    // 2. 外层进度环底(灰色轨道)
    let ringW: CGFloat = 52 * s
    let ringR: CGFloat = 300 * s
    func drawArc(_ start: CGFloat, _ end: CGFloat, _ color: NSColor, _ width: CGFloat, _ radius: CGFloat) {
        ctx.saveGState()
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.setStrokeColor(color.cgColor)
        let path = NSBezierPath()
        path.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: end, clockwise: false)
        path.stroke()
        ctx.restoreGState()
    }
    // 底环(整圈,暗色)
    drawArc(0, 360, NSColor(white: 1, alpha: 0.10), ringW, ringR)
    // 进度环(60%,亮蓝,从顶部 -90 开始顺时针)
    let pct: CGFloat = 0.60
    drawArc(-90, -90 + 360*pct, NSColor(red: 0.23, green: 0.51, blue: 0.96, alpha: 1), ringW, ringR)

    // 3. 内层小进度环(5h,橙色,40%)
    let ring2R: CGFloat = 210 * s
    let ring2W: CGFloat = 38 * s
    drawArc(0, 360, NSColor(white: 1, alpha: 0.08), ring2W, ring2R)
    drawArc(-90, -90 + 360*0.40, NSColor(red: 0.95, green: 0.55, blue: 0.20, alpha: 1), ring2W, ring2R)

    // 4. 中心:阿里云风格云朵(白色,呼应面板 logo)
    let cloudColor = NSColor.white
    cloudColor.setFill()
    // 云朵路径:中心缩放绘制(复用同样的三隆起形状)
    let cw: CGFloat = 200 * s  // 云宽
    let ch: CGFloat = 130 * s  // 云高
    let cx = center.x - cw/2
    let cy = center.y - ch/2
    let cloud = NSBezierPath()
    cloud.move(to: NSPoint(x: cx + cw*0.10, y: cy + ch*0.70))
    cloud.curve(to: NSPoint(x: cx + cw*0.22, y: cy + ch*0.42),
                controlPoint1: NSPoint(x: cx + cw*0.04, y: cy + ch*0.45),
                controlPoint2: NSPoint(x: cx + cw*0.10, y: cy + ch*0.38))
    cloud.curve(to: NSPoint(x: cx + cw*0.38, y: cy + ch*0.28),
                controlPoint1: NSPoint(x: cx + cw*0.24, y: cy + ch*0.22),
                controlPoint2: NSPoint(x: cx + cw*0.30, y: cy + ch*0.22))
    cloud.curve(to: NSPoint(x: cx + cw*0.55, y: cy + ch*0.18),
                controlPoint1: NSPoint(x: cx + cw*0.44, y: cy + ch*0.12),
                controlPoint2: NSPoint(x: cx + cw*0.48, y: cy + ch*0.12))
    cloud.curve(to: NSPoint(x: cx + cw*0.70, y: cy + ch*0.28),
                controlPoint1: NSPoint(x: cx + cw*0.62, y: cy + ch*0.14),
                controlPoint2: NSPoint(x: cx + cw*0.66, y: cy + ch*0.14))
    cloud.curve(to: NSPoint(x: cx + cw*0.85, y: cy + ch*0.40),
                controlPoint1: NSPoint(x: cx + cw*0.78, y: cy + ch*0.22),
                controlPoint2: NSPoint(x: cx + cw*0.86, y: cy + ch*0.22))
    cloud.curve(to: NSPoint(x: cx + cw*0.90, y: cy + ch*0.70),
                controlPoint1: NSPoint(x: cx + cw*1.00, y: cy + ch*0.50),
                controlPoint2: NSPoint(x: cx + cw*0.96, y: cy + ch*0.62))
    cloud.line(to: NSPoint(x: cx + cw*0.10, y: cy + ch*0.70))
    cloud.close()
    cloud.fill()

    img.unlockFocus()
    return img
}

func savePNG(_ img: NSImage, _ path: String) {
    let tiff = img.tiffRepresentation!
    let rep = NSBitmapImageRep(data: tiff)!
    let png = rep.representation(using: .png, properties: [:])!
    try! png.write(to: URL(fileURLWithPath: path))
}

// 输出 1024 主图 + 各尺寸
let sizes: [(String, CGFloat)] = [
    ("icon_1024", 1024), ("icon_512", 512), ("icon_256", 256),
    ("icon_128", 128), ("icon_64", 64), ("icon_32", 32), ("icon_16", 16)
]
for (name, px) in sizes {
    savePNG(render(size: px), "/tmp/icongen/\(name).png")
    print("生成 \(name).png")
}
print("done")
