import AppKit
import SwiftUI
import Darwin

struct UsageBar: View {
    let actual: Double?
    let theory: Double?
    let window: Window
    let style: ProgressStyle
    let resetCredits: [ResetCredit]
    let now: Date
    let forecast: Date?
    private var boundaries: [Date] { style.boundaries(start: window.start, end: window.end) }
    private func position(_ date: Date, width: CGFloat) -> CGFloat {
        guard let start = window.start, let end = window.end, end > start else { return 0 }
        return width * date.timeIntervalSince(start) / end.timeIntervalSince(start)
    }
    var body: some View {
        let points = boundaries
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    if let actual {
                        Capsule().fill(Color.accentColor)
                            .frame(width: geometry.size.width * max(0, min(100, actual)) / 100)
                    }
                }.frame(height: 8)
                    .mask {
                        Path { path in
                            path.addRect(CGRect(x: 0, y: 0, width: geometry.size.width, height: 8))
                            for date in points.dropFirst().dropLast() {
                                path.addRect(CGRect(x: position(date, width: geometry.size.width) - 1, y: 0, width: 2, height: 8))
                            }
                        }.fill(style: FillStyle(eoFill: true))
                    }.offset(y: 4)
                if let theory {
                    RoundedRectangle(cornerRadius: 1).fill(Color.primary.opacity(0.75))
                        .frame(width: 2, height: 16)
                        .offset(x: max(0, min(geometry.size.width - 2, geometry.size.width * theory / 100 - 1)))
                }
                if let forecast {
                    Image(systemName: "flag.fill").font(.system(size: 10)).foregroundStyle(.purple)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                        .help("重置预告参考时间\n\(dateText(forecast))\n此标记不是个人额度的确定重置时间。")
                        .offset(x: position(forecast, width: geometry.size.width) - 8, y: -9)
                }
                ForEach(window.resetExpiryDates(resetCredits), id: \.self) { expiry in
                    let count = resetCredits.filter { $0.expiresAt == expiry.timeIntervalSince1970 }.count
                    Image(systemName: "diamond.fill")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Color.orange)
                        .shadow(color: Color(nsColor: .windowBackgroundColor), radius: 1)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                        .help("重置机会到期：\(count) 次\n到期时间：\(dateText(expiry))\n\(creditTimeRemaining(expiry, now: now))")
                        .accessibilityLabel("\(count) 次重置机会，\(dateText(expiry))到期，\(creditTimeRemaining(expiry, now: now))")
                        .offset(x: position(expiry, width: geometry.size.width) - 8)
                }
                if points.count > 1 {
                    ForEach(0..<(points.count - 1), id: \.self) { index in
                        let left = position(points[index], width: geometry.size.width)
                        let right = position(points[index + 1], width: geometry.size.width)
                        if right - left >= 20 {
                            Text(label(index, points: points)).font(.system(size: 8.5)).foregroundStyle(.secondary)
                                .lineLimit(1).minimumScaleFactor(0.8)
                                .frame(width: right - left).offset(x: left, y: 21)
                                .help("开始：\(dateText(points[index]))\n结束：\(dateText(points[index + 1]))")
                        }
                    }
                }
            }
        }.frame(height: points.count > 1 ? 35 : 16)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(style.title)，实际已用 \(percent(actual))，理论已用 \(percent(theory))")
    }
    private func label(_ index: Int, points: [Date]) -> String {
        let hourly = ProgressStyle.usesHourlySegments(start: points.first!, end: points.last!)
        if style == .rollingDays {
            if hourly { return "第\(index + 1)小时" }
            let hours = points[index + 1].timeIntervalSince(points[index]) / 3600
            if hours < 24 { return String(format: "%g小时", hours) }
            return "第\(index + 1)天"
        }
        let formatter = DateFormatter()
        let calendar = Calendar.current
        let sameMonth = calendar.component(.month, from: points.first!) == calendar.component(.month, from: points.last!) && calendar.component(.year, from: points.first!) == calendar.component(.year, from: points.last!)
        formatter.dateFormat = hourly ? "HH:mm" : (sameMonth ? "d日" : "M/d")
        return formatter.string(from: points[index])
    }
}
