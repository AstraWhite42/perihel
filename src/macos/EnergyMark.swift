import AppKit
import SwiftUI
import Darwin

enum DepletionDirection: String, CaseIterable, Identifiable {
    case counterclockwise, clockwise
    var id: String { rawValue }
    var title: String { self == .counterclockwise ? "逆时针熄灭" : "顺时针熄灭" }
    func order(for index: Int) -> Int {
        self == .counterclockwise ? 6 - index : index
    }
}
enum EnergyMark {
    static func level(_ remaining: Double?) -> Int {
        guard let remaining, remaining.isFinite else { return -1 }
        // A cell remains lit at exactly half capacity.
        let percent: Double = max(0, min(100, remaining))
        let cells: Double = percent * 7 / 100
        return Int(floor(cells + 0.5 + 1e-10))
    }
    static func image(remaining: Double? = 100, direction: DepletionDirection = .counterclockwise) -> NSImage {
        let count = level(remaining)
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { _ in
            let step: CGFloat = 360 / 7
            let gap: CGFloat = 9
            func point(_ radius: CGFloat, _ angle: CGFloat) -> NSPoint {
                let radians = angle * .pi / 180
                return NSPoint(x: 10 + radius * cos(radians), y: 10 + radius * sin(radians))
            }
            func ink(_ index: Int) -> NSColor {
                NSColor.black.withAlphaComponent(count >= 0 && direction.order(for: index) >= 7 - count ? 1 : 0.20)
            }
            for index in 0..<6 {
                ink(index).setStroke()
                let arc = NSBezierPath()
                let start = 90 - CGFloat(index) * step
                arc.appendArc(withCenter: NSPoint(x: 10, y: 10), radius: 7, startAngle: start - gap / 2, endAngle: start - step + gap / 2, clockwise: true)
                arc.lineWidth = 2
                arc.lineCapStyle = .butt
                arc.stroke()
            }
            let baseAngle = 90 + step - gap / 2
            let base = point(7, baseAngle)
            let radians = baseAngle * .pi / 180
            let radial = NSPoint(x: cos(radians), y: sin(radians))
            let tangent = NSPoint(x: sin(radians), y: -cos(radians))
            let side: CGFloat = 3.8
            let altitude = side * sqrt(3) / 2
            let arrow = NSBezierPath()
            arrow.move(to: NSPoint(x: base.x + tangent.x * altitude, y: base.y + tangent.y * altitude))
            arrow.line(to: NSPoint(x: base.x + radial.x * side / 2, y: base.y + radial.y * side / 2))
            arrow.line(to: NSPoint(x: base.x - radial.x * side / 2, y: base.y - radial.y * side / 2))
            arrow.close(); ink(6).setFill(); arrow.fill()
            let star = NSBezierPath()
            for (index, angle) in stride(from: CGFloat(90), to: CGFloat(-270), by: -45).enumerated() {
                let vertex = point(index % 2 == 0 ? 3.4 : 1.3, angle)
                if index == 0 { star.move(to: vertex) } else { star.line(to: vertex) }
            }
            star.close(); NSColor.black.setFill(); star.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = remaining.map { "近星点，剩余额度 \(Int($0.rounded()))%，\(direction.title)" } ?? "近星点，额度未知"
        return image
    }
}
