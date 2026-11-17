// 生成应用图标 AppIcon.icns：叠放的提示词卡片 + 提示符 + 光标。
// 用法：swift scripts/make-icon.swift <输出路径.icns>（make app 自动调用）
// 图标用代码绘制，仓库里不存图片文件；改设计就改这个文件。
import AppKit

// 1024 画布，按 macOS 图标网格：主体圆角矩形 824×824，偏移 100，圆角约 185
let canvas: CGFloat = 1024
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let radius: CGFloat = 185
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

func gradient(_ colors: [CGColor]) -> CGGradient {
    CGGradient(colorsSpace: sRGB, colors: colors as CFArray, locations: [0, 1])!
}

func roundedBar(_ ctx: CGContext, _ rect: CGRect, _ fill: CGColor) {
    let r = min(rect.width, rect.height) / 2
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil))
    ctx.setFillColor(fill)
    ctx.fillPath()
}

func card(_ ctx: CGContext, center: CGPoint, angle: CGFloat, fill: CGColor) {
    ctx.saveGState()
    ctx.translateBy(x: center.x, y: center.y)
    ctx.rotate(by: angle * .pi / 180)
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, 0.22))
    ctx.addPath(CGPath(roundedRect: CGRect(x: -235, y: -200, width: 470, height: 400),
                       cornerWidth: 44, cornerHeight: 44, transform: nil))
    ctx.setFillColor(fill)
    ctx.fillPath()
    ctx.restoreGState()
}

func drawIcon(_ ctx: CGContext) {
    let indigo: UInt32 = 0x3B2FB8
    let shape = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // 底板：投影 + 渐变 + 顶部高光
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.28))
    ctx.addPath(shape)
    ctx.setFillColor(color(indigo))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    ctx.drawLinearGradient(gradient([color(0x6D6BF5), color(indigo)]),
                           start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
    ctx.drawLinearGradient(gradient([color(0xFFFFFF, 0.18), color(0xFFFFFF, 0)]),
                           start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.midY), options: [])
    ctx.restoreGState()

    // 三张叠放的卡片
    card(ctx, center: CGPoint(x: 485, y: 500), angle: 12, fill: color(0xFFFFFF, 0.35))
    card(ctx, center: CGPoint(x: 505, y: 490), angle: 5, fill: color(0xFFFFFF, 0.6))
    card(ctx, center: CGPoint(x: 525, y: 470), angle: -3, fill: color(0xFFFFFF))

    // 最前面的卡片：> 提示符、输入行、光标、两行正文
    ctx.saveGState()
    ctx.translateBy(x: 525, y: 470)
    ctx.rotate(by: -3 * .pi / 180)
    ctx.setStrokeColor(color(indigo))
    ctx.setLineWidth(30)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: -170, y: 110))
    ctx.addLine(to: CGPoint(x: -115, y: 60))
    ctx.addLine(to: CGPoint(x: -170, y: 10))
    ctx.strokePath()
    roundedBar(ctx, CGRect(x: -80, y: 45, width: 170, height: 30), color(indigo))
    roundedBar(ctx, CGRect(x: 108, y: 20, width: 22, height: 80), color(0xF5A524))
    roundedBar(ctx, CGRect(x: -170, y: -60, width: 330, height: 26), color(indigo, 0.25))
    roundedBar(ctx, CGRect(x: -170, y: -120, width: 240, height: 26), color(indigo, 0.25))
    ctx.restoreGState()
}

func png(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: CGFloat(size) / canvas, y: CGFloat(size) / canvas)
    drawIcon(ctx)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("用法：swift scripts/make-icon.swift <输出路径.icns>\n".utf8))
    exit(2)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1])
let iconset = output.deletingPathExtension().appendingPathExtension("iconset")
let fm = FileManager.default
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

for points in [16, 32, 128, 256, 512] {
    try png(size: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try png(size: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
try? fm.removeItem(at: iconset)
exit(iconutil.terminationStatus)
