import Foundation

func testResetNews() throws {
    let now = Date(timeIntervalSince1970: 1800000000)
    let formatter = ISO8601DateFormatter()
    func date(_ seconds: Double) -> String { formatter.string(from: now.addingTimeInterval(seconds)) }
    let source: [String: Any] = ["type": "x_post", "url": "https://x.com/thsottiaux/status/123", "author": "thsottiaux"]
    func announcement(_ type: String = "regular", time: Any = NSNull(), text: String = "Reset tomorrow.") -> [String: Any] {
        ["id": "123", "reset_type": type, "announced_at": date(-60), "scheduled_for": time, "text": text, "source": source]
    }
    func payload(scheduled: Any = NSNull(), watch: Any = NSNull(), latest: Any = NSNull()) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["data": ["scheduled_reset": scheduled, "active_watch": watch, "latest_reset": latest], "meta": ["generated_at": date(0)]])
    }
    let feed = ResetNewsFeed(automaticRefresh: false)
    let window = Window(usedPercent: 25, windowDurationMins: 10080, resetsAt: now.addingTimeInterval(86400).timeIntervalSince1970)
    try feed.accept(payload(), now: now)
    precondition(feed.notice(now: now) == nil)
    try feed.accept(payload(scheduled: announcement(time: date(3600))), now: now)
    precondition(feed.notice(now: now)?.reference(in: window, now: now) == now.addingTimeInterval(3600))
    precondition(feed.notice(now: now.addingTimeInterval(1801))?.stale == true)
    precondition(feed.notice(now: now.addingTimeInterval(1801))?.reference(in: window, now: now) == nil)
    try feed.accept(payload(scheduled: announcement(time: date(3600), text: "Landing before 10am.")), now: now)
    precondition(feed.notice(now: now)?.theoryTitle == "预告上限理论")
    try feed.accept(payload(scheduled: announcement(time: date(-60))), now: now)
    precondition(feed.notice(now: now) != nil && feed.notice(now: now)?.reference(in: window, now: now) == nil)
    try feed.accept(payload(scheduled: announcement(time: date(90000))), now: now)
    precondition(feed.notice(now: now)?.reference(in: window, now: now) == nil)
    try feed.accept(payload(scheduled: announcement()), now: now)
    precondition(feed.notice(now: now)?.target == nil)
    try feed.accept(payload(scheduled: announcement("banked", time: date(3600))), now: now)
    precondition(feed.notice(now: now)?.reference(in: window, now: now) == nil)
    let watch: [String: Any] = ["observed_at": date(-60), "expires_at": date(600), "text": "Possible reset", "source": source]
    try feed.accept(payload(watch: watch), now: now)
    precondition(feed.notice(now: now)?.title == "重置动向 · 尚未确认")
    precondition(feed.notice(now: now)?.target == nil)
    precondition(feed.notice(now: now.addingTimeInterval(600)) == nil)
    try feed.accept(payload(scheduled: announcement(time: date(3600)), watch: watch), now: now)
    precondition(feed.notice(now: now)?.title == "重置预告")
    try feed.accept(payload(latest: announcement()), now: now)
    precondition(feed.notice(now: now)?.completed == true)
    precondition(feed.notice(now: now)?.reference(in: window, now: now) == nil)
    do { try feed.accept(Data("invalid".utf8)); preconditionFailure("Invalid feed accepted") } catch {}
    precondition(feed.notice(now: now)?.completed == true)
    precondition(ResetNewsSource(type: "x_post", url: "file:///tmp/example").link == nil)
    precondition(newsDate("2026-10-24T13:25:10.971Z") != nil)
    precondition(newsDate("2026-10-24T13:25:10Z") != nil)
    precondition(newsDate("not a date") == nil)
}

private final class ResetNewsTestProtocol: URLProtocol {
    static var status = 200
    static var body = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: ["Retry-After": "600"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
func testResetNewsTransport() throws {
    let valid = Data(#"{"data":{"latest_reset":null,"scheduled_reset":null,"active_watch":null},"meta":{"generated_at":"2026-10-24T12:00:00Z"}}"#.utf8)
    for status in [200, 304, 429, 503] {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ResetNewsTestProtocol.self]
        let feed = ResetNewsFeed(automaticRefresh: false, session: URLSession(configuration: configuration))
        if status == 304 { try feed.accept(valid, now: Date().addingTimeInterval(-100)) }
        ResetNewsTestProtocol.status = status
        ResetNewsTestProtocol.body = valid
        let previous = feed.checkedAt
        feed.refresh()
        let deadline = Date().addingTimeInterval(3)
        while !feed.failed && feed.checkedAt == previous && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        if status == 200 || status == 304 { precondition(!feed.failed && feed.checkedAt != previous) }
        else { precondition(feed.failed && feed.response == nil) }
    }
}
