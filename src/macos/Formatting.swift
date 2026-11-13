import AppKit
import SwiftUI
import Darwin

func percent(_ value: Double?) -> String { value.map { String(format: "%.1f%%", $0) } ?? "暂无数据" }
func dateText(_ date: Date?) -> String {
    guard let date else { return "暂无数据" }
    let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter.string(from: date)
}
func shortDate(_ date: Date?) -> String {
    guard let date else { return "暂无数据" }
    let formatter = DateFormatter()
    formatter.dateFormat = Calendar.current.component(.year, from: date) == Calendar.current.component(.year, from: Date()) ? "M月d日 HH:mm" : "yyyy年M月d日 HH:mm"
    return formatter.string(from: date)
}
func countdown(_ end: Date?, _ now: Date) -> String {
    guard let end else { return "暂无数据" }
    let seconds = Int(end.timeIntervalSince(now))
    guard seconds > 0 else { return "等待重置" }
    if seconds < 60 { return "不到 1 分钟" }
    if seconds < 3600 { return "\(seconds / 60) 分钟" }
    if seconds < 86400 { return "\(seconds / 3600) 小时 \(seconds / 60 % 60) 分" }
    return "\(seconds / 86400) 天 \(seconds / 3600 % 24) 小时 \(seconds / 60 % 60) 分"
}
func creditTimeRemaining(_ expiry: Date?, now: Date) -> String {
    guard let expiry else { return "剩余时间未知" }
    guard expiry > now else { return "已到期" }
    return "剩余 " + countdown(expiry, now)
}
func creditExpirySummary(_ expiry: Date, now: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = Calendar.current.component(.year, from: expiry) == Calendar.current.component(.year, from: now) ? "M/d HH:mm" : "yyyy/M/d HH:mm"
    let seconds = Int(expiry.timeIntervalSince(now))
    let relative: String
    if seconds <= 0 { relative = "已到期" }
    else if seconds < 60 { relative = "不足1分钟" }
    else if seconds < 3600 { relative = "\(seconds / 60)分后" }
    else if seconds < 86400 { relative = "\(seconds / 3600)时\(seconds / 60 % 60)分后" }
    else { relative = "\(seconds / 86400)天\(seconds / 3600 % 24)时后" }
    return formatter.string(from: expiry) + " · " + relative
}
func planName(_ raw: String?) -> String {
    guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "套餐未知" }
    let names = [
        "free": "Free", "go": "Go", "plus": "Plus",
        "prolite": "Pro 100", "pro": "Pro 200", "promax": "Pro 500",
        "team": "Business", "self_serve_business_prolite": "Business",
        "self_serve_business_usage_based": "Business",
        "business": "Enterprise", "ent26": "Enterprise", "enterprise": "Enterprise",
        "enterprise_cbp_automation": "Enterprise", "enterprise_cbp_usage_based": "Enterprise",
        "edu": "Edu"
    ]
    return names[raw] ?? raw
}
func windowTitle(_ name: String, _ window: Window, plan: String?) -> String {
    let name = "\(name) · \(planName(plan))"
    guard let minutes = window.windowDurationMins, minutes > 0 else { return name }
    let duration: String
    if minutes.truncatingRemainder(dividingBy: 1440) == 0 { duration = "\(Int(minutes / 1440)) 天" }
    else if minutes.truncatingRemainder(dividingBy: 60) == 0 { duration = "\(Int(minutes / 60)) 小时" }
    else { duration = "\(Int(minutes)) 分钟" }
    return "\(name) · \(duration)窗口"
}
