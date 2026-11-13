import AppKit
import SwiftUI
import Darwin

enum MenuBarDisplay: String, CaseIterable, Identifiable {
    case remaining, budget, iconOnly
    var id: String { rawValue }
    var title: String {
        switch self {
        case .remaining: return "剩余百分比"
        case .budget: return "领先／落后百分比"
        case .iconOnly: return "不显示百分比"
        }
    }
    static func load(from settings: UserDefaults) -> MenuBarDisplay {
        if let value = settings.string(forKey: "menuBarDisplay"), let mode = MenuBarDisplay(rawValue: value) { return mode }
        return settings.object(forKey: "showPercentage") as? Bool == false ? .iconOnly : .remaining
    }
    func text(window: Window?, now: Date) -> String? {
        switch self {
        case .iconOnly: return ""
        case .remaining: return window?.remaining.map { "\(Int($0.rounded()))%" }
        case .budget:
            guard let window, let actual = window.usedPercent, let theory = window.theoretical(now) else { return nil }
            let difference = actual - theory
            if abs(difference) < 0.05 { return "0.0%" }
            return String(format: "%+.1f%%", difference)
        }
    }
}

enum AppTheme: String, CaseIterable, Identifiable {
    case readable, system
    var id: String { rawValue }
    var title: String { self == .readable ? "清晰底色" : "系统原生" }
}

enum ProgressStyle: String, CaseIterable, Identifiable {
    case calendarDays, rollingDays, continuous
    var id: String { rawValue }
    var title: String {
        switch self {
        case .calendarDays: return "按自然时点分段"
        case .rollingDays: return "按等分时长分段"
        case .continuous: return "不分段"
        }
    }
    static func usesHourlySegments(start: Date, end: Date) -> Bool {
        end.timeIntervalSince(start) <= 86400
    }
    func boundaries(start: Date?, end: Date?, calendar: Calendar = .current) -> [Date] {
        guard self != .continuous, let start, let end, end > start else { return [] }
        let hourly = Self.usesHourlySegments(start: start, end: end)
        var points = [start]
        var current = start
        while points.count <= 512 {
            let next: Date?
            if self == .calendarDays { next = calendar.dateInterval(of: hourly ? .hour : .day, for: current)?.end }
            else { next = current.addingTimeInterval(hourly ? 3600 : 86400) }
            guard let next, next > current else { return [] }
            if next >= end { points.append(end); return points }
            points.append(next); current = next
        }
        return []
    }
}
