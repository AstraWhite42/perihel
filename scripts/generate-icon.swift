import AppKit

let output = CommandLine.arguments[1]
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}
let tile = NSBezierPath(roundedRect: NSRect(x: 72, y: 72, width: 880, height: 880), xRadius: 198, yRadius: 198)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = color(0.03, 0.04, 0.12, 0.28)
shadow.shadowBlurRadius = 18
shadow.shadowOffset = NSSize(width: 0, height: -10)
shadow.set()
color(0.10, 0.12, 0.25).setFill()
tile.fill()
NSGraphicsContext.restoreGraphicsState()
NSGradient(colors: [color(0.075, 0.09, 0.20), color(0.19, 0.23, 0.41)])!.draw(in: tile, angle: 60)
color(0.65, 0.72, 0.92, 0.14).setStroke()
tile.lineWidth = 2
tile.stroke()

// Eight energy cells and a returning arrow express a replenishing quota cycle.
let center = NSPoint(x: 512, y: 512)
for index in 0..<8 {
    let start = 90 - CGFloat(index) * 37.5
    let arc = NSBezierPath()
    arc.appendArc(withCenter: center, radius: 286, startAngle: start - 4, endAngle: start - 33.5, clockwise: true)
    arc.lineWidth = 66
    arc.lineCapStyle = .butt
    (index < 6 ? color(0.68, 0.86, 1) : color(0.32, 0.39, 0.57)).setStroke()
    arc.stroke()
}
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 330, y: 764))
arrow.line(to: NSPoint(x: 193, y: 707))
arrow.line(to: NSPoint(x: 314, y: 634))
arrow.close()
color(0.68, 0.86, 1).setFill()
arrow.fill()
let radius: CGFloat = 146
let spark = NSBezierPath()
spark.move(to: NSPoint(x: 512, y: 512 + radius))
for point in [NSPoint(x: 553, y: 553), NSPoint(x: 512 + radius, y: 512), NSPoint(x: 553, y: 471), NSPoint(x: 512, y: 512 - radius), NSPoint(x: 471, y: 471), NSPoint(x: 512 - radius, y: 512), NSPoint(x: 471, y: 553)] { spark.line(to: point) }
spark.close()
NSGradient(colors: [color(1, 0.73, 0.35), color(1, 0.94, 0.76)])!.draw(in: spark, angle: 90)
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
