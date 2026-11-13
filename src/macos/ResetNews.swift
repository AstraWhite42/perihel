import AppKit
import SwiftUI

struct ResetNewsSource: Decodable {
    let type: String
    let url: String?
    var link: URL? {
        guard let url, let value = URL(string: url), value.scheme == "https" else { return nil }
        return value
    }
}
struct ResetAnnouncement: Decodable {
    let id: String
    let reset_type: String
    let announced_at: String
    let scheduled_for: String?
    let text: String
    let source: ResetNewsSource
    var target: Date? { scheduled_for.flatMap(newsDate) }
}
struct ResetWatch: Decodable {
    let observed_at: String
    let expires_at: String
    let text: String
    let source: ResetNewsSource
}
struct ResetNewsResponse: Decodable {
    struct Payload: Decodable {
        let latest_reset: ResetAnnouncement?
        let scheduled_reset: ResetAnnouncement?
        let active_watch: ResetWatch?
    }
    struct Meta: Decodable { let generated_at: String }
    let data: Payload
    let meta: Meta
}
func newsDate(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)
}
struct ResetNewsNotice {
    let title: String
    let text: String
    let source: ResetNewsSource
    let published: Date?
    let target: Date?
    let banked: Bool
    let completed: Bool
    let stale: Bool
    var isDeadline: Bool {
        text.range(of: #"\b(before|by|no later than)\b|之前|不晚于|最晚"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
    var timeLabel: String { isDeadline ? "预告时间上限" : "预告参考时间" }
    var theoryTitle: String { isDeadline ? "预告上限理论" : "预告时点理论" }
    func reference(in window: Window, now: Date) -> Date? {
        guard !banked, !completed, !stale, let target, target > now,
              let start = window.start, let end = window.end, target >= start, target <= end else { return nil }
        return target
    }
}
final class ResetNewsFeed: ObservableObject {
    @Published private(set) var response: ResetNewsResponse?
    @Published private(set) var failed = false
    @Published private(set) var checkedAt: Date?
    private var etag: String?
    private var busy = false
    private var nextAttempt = Date.distantPast
    private var timer: Timer?
    private let session: URLSession
    private var completed: ResetAnnouncement?
    init(automaticRefresh: Bool, session: URLSession = URLSession(configuration: .ephemeral)) {
        self.session = session
        guard automaticRefresh else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.refresh() }
    }
    deinit { timer?.invalidate(); session.invalidateAndCancel() }
    func accept(_ data: Data, now: Date = Date()) throws {
        let decoded = try JSONDecoder().decode(ResetNewsResponse.self, from: data)
        guard newsDate(decoded.meta.generated_at) != nil else { throw URLError(.cannotParseResponse) }
        if let previous = response?.data.scheduled_reset, let latest = decoded.data.latest_reset,
           previous.id == latest.id, decoded.data.scheduled_reset?.id != previous.id {
            completed = latest
        }
        response = decoded
        checkedAt = now
        failed = false
    }
    func notice(now: Date) -> ResetNewsNotice? {
        guard let response else { return nil }
        let stale = failed || now.timeIntervalSince(checkedAt ?? .distantPast) > 1800
        if let announcement = response.data.scheduled_reset {
            return ResetNewsNotice(title: announcement.reset_type == "banked" ? "重置机会发放预告" : "重置预告", text: announcement.text, source: announcement.source, published: newsDate(announcement.announced_at), target: announcement.target, banked: announcement.reset_type != "regular", completed: false, stale: stale)
        }
        if let watch = response.data.active_watch, let expiry = newsDate(watch.expires_at), expiry > now {
            return ResetNewsNotice(title: "重置动向 · 尚未确认", text: watch.text, source: watch.source, published: newsDate(watch.observed_at), target: nil, banked: false, completed: false, stale: stale)
        }
        if let completed, let checkedAt, now.timeIntervalSince(newsDate(completed.announced_at) ?? checkedAt) < 86400 {
            return ResetNewsNotice(title: "公开消息称已完成", text: "个人额度是否恢复，请以当前账户数据为准。", source: completed.source, published: newsDate(completed.announced_at), target: nil, banked: completed.reset_type == "banked", completed: true, stale: stale)
        }
        return nil
    }
    func refresh() {
        guard !busy, Date() >= nextAttempt else { return }
        busy = true
        nextAttempt = Date().addingTimeInterval(300)
        var request = URLRequest(url: URL(string: "https://codex-resets.com/api/v1/status")!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        session.dataTask(with: request) { [weak self] data, result, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                guard error == nil, let http = result as? HTTPURLResponse else { self.failed = true; return }
                if http.statusCode == 304, self.response != nil {
                    self.checkedAt = Date(); self.failed = false; return
                }
                if http.statusCode == 429 {
                    let delay = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 300
                    self.nextAttempt = Date().addingTimeInterval(max(300, delay))
                }
                guard http.statusCode == 200, let data, data.count <= 1_000_000 else { self.failed = true; return }
                do {
                    try self.accept(data)
                    self.etag = http.value(forHTTPHeaderField: "ETag")
                } catch { self.failed = true }
            }
        }.resume()
    }
}
struct ResetNewsView: View {
    let notice: ResetNewsNotice
    let now: Date
    @ViewState private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Label(notice.title, systemImage: notice.target == nil ? "text.bubble" : "flag.fill")
                    .foregroundStyle(.purple)
                Spacer(minLength: 4)
                if let url = notice.source.link { Link("来源 ↗", destination: url) }
            }.font(.caption.weight(.medium))
            if let target = notice.target, !notice.completed {
                Text(target > now ? "\(notice.timeLabel)：\(shortDate(target)) · 距今 \(countdown(target, now))" : "公告时间已过，等待确认")
                    .font(.caption).fixedSize(horizontal: false, vertical: true)
                Text("具体时间和适用范围以原文为准。")
                    .font(.caption2).foregroundStyle(.secondary)
            } else if notice.title == "重置预告" { Text("时间待定").font(.caption) }
            Text(notice.text).font(.caption).lineLimit(expanded ? nil : 3)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            HStack {
                Button(expanded ? "收起原文" : "展开原文") { expanded.toggle() }.buttonStyle(.plain)
                Spacer()
                Link("数据：Codex Resets ↗", destination: URL(string: "https://codex-resets.com")!)
            }.font(.caption2).foregroundStyle(.secondary)
            if let published = notice.published { Text("发布于 \(shortDate(published))").font(.caption2).foregroundStyle(.secondary) }
            if notice.stale { Text("消息更新延迟，暂不作为用量目标。").font(.caption2).foregroundStyle(.orange) }
        }.padding(8).background(Color.purple.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }
}
