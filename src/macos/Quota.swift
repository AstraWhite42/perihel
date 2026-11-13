import AppKit
import SwiftUI
import Darwin

struct Window: Codable {
    let usedPercent: Double?
    let windowDurationMins: Double?
    let resetsAt: Double?
    var isWeekly: Bool { windowDurationMins == 10080 }
    var supportsBudgetDetails: Bool { windowDurationMins != 300 }
    var remaining: Double? { usedPercent.map { max(0, min(100, 100 - $0)) } }
    var end: Date? { resetsAt.map(Date.init(timeIntervalSince1970:)) }
    var start: Date? {
        guard let end, let minutes = windowDurationMins, minutes > 0 else { return nil }
        return end.addingTimeInterval(-minutes * 60)
    }
    func resetExpiryDates(_ credits: [ResetCredit]) -> [Date] {
        guard let start, let end, end > start else { return [] }
        return Array(Set(credits.compactMap { credit -> Date? in
            guard let timestamp = credit.expiresAt, timestamp.isFinite else { return nil }
            let date = Date(timeIntervalSince1970: timestamp)
            return date >= start && date <= end ? date : nil
        })).sorted()
    }
    func theoreticalAtMidnight(_ now: Date, calendar: Calendar = .current) -> Double? {
        guard let midnight = calendar.dateInterval(of: .day, for: now)?.end else { return nil }
        return theoretical(midnight)
    }
    func theoretical(_ now: Date) -> Double? {
        guard let start, let minutes = windowDurationMins, minutes > 0 else { return nil }
        return max(0, min(100, now.timeIntervalSince(start) / (minutes * 60) * 100))
    }
}
struct Bucket: Codable {
    let limitName: String?
    let primary: Window?
    let secondary: Window?
    let planType: String?
    var orderedWindows: [(String, Window)] {
        let windows: [(String, Window)] = [("primary", primary), ("secondary", secondary)].compactMap { key, window in
            window.map { (key, $0) }
        }
        return windows.filter { $0.1.isWeekly } + windows.filter { !$0.1.isWeekly }
    }
}
struct ResetCredit: Codable { let expiresAt: Double? }
struct Resets: Codable { let availableCount: Int?; let credits: [ResetCredit]? }
struct Snapshot: Codable {
    let rateLimits: Bucket?
    let rateLimitsByLimitId: [String: Bucket]?
    let rateLimitResetCredits: Resets?
    var buckets: [(String, Bucket)] {
        if let items = rateLimitsByLimitId, !items.isEmpty {
            return items.sorted { a, b in
                if a.key == "codex" { return b.key != "codex" }
                if b.key == "codex" { return false }
                return a.key < b.key
            }.map { ($0.key, $0.value) }
        }
        return rateLimits.map { [("codex", $0)] } ?? []
    }
    var mainWindow: Window? { buckets.first?.1.orderedWindows.first?.1 }
    func hasExpiredWindow(at now: Date) -> Bool {
        buckets.contains { _, bucket in
            bucket.orderedWindows.contains { _, window in window.end.map { $0 <= now } ?? false }
        }
    }
}
