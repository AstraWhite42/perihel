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
        return Int(floor(max(0, min(100, remaining)) * 7 / 100 + 0.5 + 1e-10))
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
enum SetupIssue: String {
    case missingCLI, loginRequired, incompatibleCLI
}
struct QuotaError: LocalizedError {
    let message: String
    let issue: SetupIssue?
    init(message: String, issue: SetupIssue? = nil) { self.message = message; self.issue = issue }
    var errorDescription: String? { message }
}
struct Inspection {
    let snapshot: Snapshot
    let cliVersion: String
    let planType: String?
}

final class CLIReader {
    static func locate() -> String? {
        if let index = CommandLine.arguments.firstIndex(of: "--cli-path"), CommandLine.arguments.count > index + 1 {
            let path = CommandLine.arguments[index + 1]
            return FileManager.default.isExecutableFile(atPath: path) ? path : nil
        }
        let custom = UserDefaults.standard.string(forKey: "cliPath")
        let home = FileManager.default.homeDirectoryForCurrentUser
        let paths = [custom, "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
                     home.appendingPathComponent(".local/bin/codex").path,
                     home.appendingPathComponent(".npm-global/bin/codex").path,
                     home.appendingPathComponent(".volta/bin/codex").path].compactMap { $0 }
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/codex" }
        return paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    static func version(at path: String) throws -> String {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        process.environment = environment(for: path)
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline { usleep(10_000) }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL); process.waitUntilExit()
            throw QuotaError(message: "CLI 版本检测超时，请确认所选文件是 Codex CLI。", issue: .incompatibleCLI)
        }
        process.waitUntilExit()
        let value = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationStatus == 0, value.hasPrefix("codex-cli ") else {
            throw QuotaError(message: "所选程序不是可用的 Codex CLI，请重新选择或更新 CLI。", issue: .incompatibleCLI)
        }
        return value
    }
    static func environment(for path: String) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = URL(fileURLWithPath: path).deletingLastPathComponent().path + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
        return environment
    }
    static func read() throws -> Snapshot { try inspect().snapshot }
    static func inspect() throws -> Inspection {
        guard let path = locate() else { throw QuotaError(message: "尚未找到 Codex CLI。安装后点击重新检测，或选择已有的 CLI。", issue: .missingCLI) }
        let cliVersion = try version(at: path)
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["app-server"]
        process.standardInput = input; process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.environment = environment(for: path)
        try process.run()
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            // Bound shutdown even if the child ignores SIGTERM.
            let deadline = Date().addingTimeInterval(0.5)
            while process.isRunning && Date() < deadline { usleep(10_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            try? output.fileHandleForReading.close()
        }
        func send(_ value: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: value); data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "perihel", "title": "近星点", "version": AppVersion.version]]])
        var accountPlan: String?
        var buffer = Data()
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline {
            var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 200)
            if ready < 0 { if errno == EINTR { continue }; throw QuotaError(message: "读取 CLI 失败。") }
            if ready == 0 { continue }
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { throw QuotaError(message: "Codex CLI 已退出，请检查 CLI 是否可以正常运行。") }
            buffer.append(chunk)
            guard buffer.count < 4_000_000 else { throw QuotaError(message: "CLI 响应过大。") }
            while let newline = buffer.firstIndex(of: 10) {
                let line = buffer.prefix(upTo: newline); buffer.removeSubrange(...newline)
                guard let response = try JSONSerialization.jsonObject(with: line) as? [String: Any], let id = response["id"] as? Int else { continue }
                if let error = response["error"] as? [String: Any] {
                    let message = error["message"] as? String ?? "额度查询失败"
                    if error["code"] as? Int == -32601 {
                        throw QuotaError(message: "当前 CLI 缺少所需接口，请更新 Codex CLI 后重试。", issue: .incompatibleCLI)
                    }
                    let lower = message.lowercased()
                    let authFailure = ["unauthorized", "401", "not authenticated", "not logged", "login", "sign in", "token expired", "requires chatgpt"].contains { lower.contains($0) }
                    throw QuotaError(message: message, issue: authFailure ? .loginRequired : nil)
                }
                if id == 1 {
                    try send(["method": "initialized"])
                    try send(["id": 2, "method": "account/read", "params": ["refreshToken": false]])
                } else if id == 2 {
                    let result = response["result"] as? [String: Any]
                    let account = result?["account"] as? [String: Any]
                    guard let type = account?["type"] as? String, ["chatgpt", "chatgptAuthTokens"].contains(type) else {
                        throw QuotaError(message: "请在 Codex CLI 中登录你的 ChatGPT 订阅账户。API Key 登录不能用于订阅额度监控。", issue: .loginRequired)
                    }
                    accountPlan = account?["planType"] as? String
                    try send(["id": 3, "method": "account/rateLimits/read"])
                } else if id == 3, let result = response["result"] {
                    let snapshot = try JSONDecoder().decode(Snapshot.self, from: JSONSerialization.data(withJSONObject: result))
                    return Inspection(snapshot: snapshot, cliVersion: cliVersion, planType: accountPlan)
                }
            }
        }
        throw QuotaError(message: "额度查询超时，请检查网络后重试。")
    }
}

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

final class Store: ObservableObject {
    @Published var snapshot: Snapshot?
    @Published var updatedAt: Date?
    @Published var error: String?
    @Published var loading = false
    @Published var now = Date()
    @Published var panelSession = UUID()
    @Published var cliVersion: String?
    @Published var planType: String?
    @Published var setupIssue: SetupIssue?
    @Published var showSetup: Bool
    @Published var menuBarDisplay: MenuBarDisplay {
        didSet {
            settings.set(menuBarDisplay.rawValue, forKey: "menuBarDisplay")
            onChange?()
        }
    }
    @Published var depletionDirection: DepletionDirection {
        didSet { settings.set(depletionDirection.rawValue, forKey: "depletionDirection"); onChange?() }
    }
    @Published var progressStyle: ProgressStyle {
        didSet { settings.set(progressStyle.rawValue, forKey: "progressStyle") }
    }
    @Published var theme: AppTheme {
        didSet { settings.set(theme.rawValue, forKey: "theme"); onThemeChange?() }
    }
    var onThemeChange: (() -> Void)?
    var onChange: (() -> Void)?
    private let settings: UserDefaults
    private var timer: Timer?
    let resetNews: ResetNewsFeed
    private var lastAttempt = Date.distantPast
    init(automaticRefresh: Bool = true, settings: UserDefaults = .standard) {
        self.settings = settings
        resetNews = ResetNewsFeed(automaticRefresh: automaticRefresh)
        showSetup = !settings.bool(forKey: "hasCompletedSetup")
        menuBarDisplay = MenuBarDisplay.load(from: settings)
        depletionDirection = settings.string(forKey: "depletionDirection").flatMap(DepletionDirection.init(rawValue:)) ?? .counterclockwise
        progressStyle = settings.string(forKey: "progressStyle").flatMap(ProgressStyle.init(rawValue:)) ?? .calendarDays
        theme = settings.string(forKey: "theme").flatMap(AppTheme.init(rawValue:)) ?? .system
        guard automaticRefresh else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.now = Date()
            let expired = self.snapshot?.hasExpiredWindow(at: self.now) ?? false
            if self.now.timeIntervalSince(self.lastAttempt) >= (expired ? 30 : 120) { self.refresh() }
            self.onChange?()
        }
    }
    func refresh() {
        guard !loading else { return }
        loading = true; lastAttempt = Date(); onChange?()
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try CLIReader.inspect() }
            DispatchQueue.main.async {
                self.loading = false
                switch result {
                case .success(let inspection):
                    self.snapshot = inspection.snapshot; self.cliVersion = inspection.cliVersion; self.planType = inspection.planType
                    self.updatedAt = Date(); self.error = nil; self.setupIssue = nil
                case .failure(let error):
                    self.error = error.localizedDescription
                    self.setupIssue = (error as? QuotaError)?.issue
                    if self.setupIssue != nil {
                        self.showSetup = true
                        self.snapshot = nil; self.updatedAt = nil; self.planType = nil
                    }
                }
                self.onChange?()
            }
        }
    }
    func endPanelSession() { panelSession = UUID() }
    func finishSetup() {
        guard snapshot != nil else { return }
        settings.set(true, forKey: "hasCompletedSetup")
        showSetup = false
    }
    func copyCommand(_ command: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }
    func openLogin() {
        guard let path = CLIReader.locate() else { setupIssue = .missingCLI; return }
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(AppVersion.bundleIdentifier, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let file = directory.appendingPathComponent("Codex-login.command")
            let searchPath = CLIReader.environment(for: path)["PATH"] ?? "/usr/bin:/bin"
            let script = "#!/bin/zsh\nexport PATH=\(CLIReader.shellQuote(searchPath))\n\(CLIReader.shellQuote(path)) login\nprint '\n完成后返回近星点，点击重新检测。'\n"
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            let configuration = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([file], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"), configuration: configuration) { _, failure in
                if let failure { DispatchQueue.main.async { self.error = failure.localizedDescription } }
            }
        } catch { self.error = error.localizedDescription }
    }
    func chooseCLI() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = "选择 Codex CLI 可执行文件"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            guard FileManager.default.isExecutableFile(atPath: url.path) else { error = "所选文件不可执行。"; return }
            UserDefaults.standard.set(url.path, forKey: "cliPath"); refresh()
        }
    }
}
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
struct WindowView: View {
    @ObservedObject var resetNews: ResetNewsFeed
    let showsResetNews: Bool
    let resetCredits: [ResetCredit]
    let title: String
    let window: Window
    let now: Date
    let progressStyle: ProgressStyle
    private var notice: ResetNewsNotice? { showsResetNews && window.isWeekly ? resetNews.notice(now: now) : nil }
    private var forecast: Date? { notice?.reference(in: window, now: now) }
    @ViewState private var showBudgetDetails = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.subheadline.weight(.medium))
                Spacer(minLength: 8)
                Text(TimeZone.current.identifier).font(.caption2)
                    .lineLimit(1).truncationMode(.middle)
                    .help("当前系统时区：\(TimeZone.current.identifier)")
            }.foregroundStyle(.secondary)
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("剩余额度").font(.caption).foregroundStyle(.secondary)
                    Text(percent(window.remaining)).font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 5) {
                    Text("距离重置").font(.caption).foregroundStyle(.secondary)
                    Text(countdown(window.end, now)).font(.subheadline.weight(.medium)).monospacedDigit()
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("开始 \(shortDate(window.start))")
                        .help("开始时间（推算）：\(dateText(window.start))")
                    Spacer(minLength: 8)
                    Text("重置 \(shortDate(window.end))")
                        .help("下次重置：\(dateText(window.end))")
                }.font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                UsageBar(actual: window.usedPercent, theory: window.theoretical(now), window: window, style: progressStyle, resetCredits: resetCredits, now: now, forecast: forecast)
                HStack(spacing: 5) {
                    Circle().fill(Color.accentColor).frame(width: 5, height: 5)
                    Text("实际已用")
                    Text("·")
                    Text("理论刻度")
                    if !window.resetExpiryDates(resetCredits).isEmpty {
                        Image(systemName: "diamond.fill").font(.system(size: 6)).foregroundStyle(.orange)
                        Text("机会到期")
                    }
                    Spacer(minLength: 8)
                    if let actual = window.usedPercent, let theory = window.theoretical(now) {
                        let difference = actual - theory
                        if window.supportsBudgetDetails {
                        Button { showBudgetDetails.toggle() } label: {
                            HStack(spacing: 4) {
                                Text(abs(difference) < 0.05 ? "预算持平" : String(format: "%@预算 %.1f%%", difference > 0 ? "领先" : "落后", abs(difference)))
                                    .monospacedDigit()
                                Image(systemName: showBudgetDetails ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 8, weight: .semibold))
                            }.fixedSize().contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .help(showBudgetDetails ? "收起预算计算依据" : "查看实际与理论用量及差值")
                            .accessibilityLabel(showBudgetDetails ? "收起预算计算依据" : "展开预算计算依据")
                        } else {
                            Text(abs(difference) < 0.05 ? "预算持平" : String(format: "%@预算 %.1f%%", difference > 0 ? "领先" : "落后", abs(difference)))
                                .monospacedDigit()
                        }
                    }
                }.font(.caption2).foregroundStyle(.secondary)
            }
            if let notice { ResetNewsView(notice: notice, now: now) }
            if window.supportsBudgetDetails, showBudgetDetails, let actual = window.usedPercent, let theory = window.theoretical(now) {
                Divider()
            Grid(horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow {
                    Text("用量").frame(maxWidth: .infinity, alignment: .leading)
                    Text("已用").frame(width: 60, alignment: .trailing)
                    Text("剩余").frame(width: 60, alignment: .trailing)
                    HStack(spacing: 3) {
                        Text("差值")
                        Image(systemName: "questionmark.circle")
                            .font(.system(size: 10))
                    }.frame(width: 60, alignment: .trailing)
                        .contentShape(Rectangle())
                        .help("差值 = 当前实际已用 − 对应行的理论已用\n正值：领先预算\n负值：落后预算\n单位：百分点")
                        .accessibilityLabel("差值，悬停查看计算说明")
                }.font(.caption).foregroundStyle(.secondary)
                usageRow("实际", window.usedPercent, window.remaining)
                usageRow("当前理论", theory, 100 - theory, difference: actual - theory)
                let midnightTheory = window.theoreticalAtMidnight(now)
                usageRow("今晚24时理论", midnightTheory, midnightTheory.map { 100 - $0 }, difference: midnightTheory.map { actual - $0 }, explanation: "按系统时区计算今晚 24 时的理论用量。\n沿用当前额度窗口的匀速预算。\n若窗口在此前结束，理论已用记为 100%。")
                if let forecast, let forecastTheory = window.theoretical(forecast) {
                    usageRow(notice?.theoryTitle ?? "预告时点理论", forecastTheory, 100 - forecastTheory, difference: actual - forecastTheory,
                             explanation: "按预告参考时间计算当前周窗口的理论用量。\n实际已用减去该值即为差值。\n具体重置安排以公告原文为准。")
                }
            }.font(.subheadline).monospacedDigit()
            }
        }.padding(14).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
        .onAppear { if CommandLine.arguments.contains("--budget-details") { showBudgetDetails = true } }
    }
    func usageRow(_ title: String, _ used: Double?, _ remaining: Double?, difference: Double? = nil, explanation: String? = nil) -> some View {
        GridRow {
            HStack(spacing: 3) {
                Text(title)
                if explanation != nil {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .help(explanation ?? "")
            Text(percent(used)).frame(width: 60, alignment: .trailing)
            Text(percent(remaining)).frame(width: 60, alignment: .trailing)
            Text(difference.map { abs($0) < 0.05 ? "0.0%" : String(format: "%+.1f%%", $0) } ?? "—")
                .frame(width: 60, alignment: .trailing)
        }
    }
}
private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
struct UsageInfoView: View {
    let close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("额度说明").font(.headline)
                Spacer()
                Button(action: close) { Image(systemName: "xmark").frame(width: 22, height: 22) }
                    .buttonStyle(.borderless).accessibilityLabel("关闭说明")
            }
            section("理论用量", "按当前时间在额度窗口中的进度，计算匀速消耗时的理论已用和剩余百分比。它是消费节奏参考，不代表额度随时间补充。")
            section("窗口时间", "开始时间由“下次重置时间 − 窗口长度”推算。所有时间使用系统时区：\(TimeZone.current.identifier)。")
            section("重置机会", "可用次数以服务端返回值为准。到期明细可能不完整；未提供到期时间不代表永久有效。")
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text("近星点 \(AppVersion.version)（构建 \(AppVersion.build)）").font(.subheadline.weight(.medium))
                Text("作者：白星澈AstraWhite").font(.callout).foregroundStyle(.secondary)
            }
        }.padding(18).frame(width: 320, alignment: .leading)
    }
    private func section(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(body).font(.callout).foregroundStyle(.secondary)
                .lineSpacing(4).multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
struct SetupView: View {
    @ObservedObject var store: Store
    private var installed: Bool { CLIReader.locate() != nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("连接你的 Codex").font(.title3.weight(.semibold))
            Text("近星点复用本机 CLI 登录，只读取订阅额度。每位使用者登录自己的 ChatGPT 账户。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 9) {
                Label("1 · 安装 Codex CLI", systemImage: installed ? "checkmark.circle.fill" : "circle")
                    .font(.headline)
                if installed {
                    Text(store.cliVersion ?? "已找到 CLI，请完成登录检测。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(CLIReader.locate() ?? "").font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(2).textSelection(.enabled)
                } else {
                    Text("已安装 Homebrew 时，可在终端执行以下命令：")
                        .font(.caption).foregroundStyle(.secondary)
                    command("brew install --cask codex")
                }
                HStack {
                    Link("安装与更新说明", destination: URL(string: "https://learn.chatgpt.com/docs/codex/cli")!)
                    Spacer()
                    Button("选择已有 CLI…") { store.chooseCLI() }.disabled(store.loading)
                }.font(.caption)
            }.padding(12).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 9) {
                Label("2 · 登录 ChatGPT 账户", systemImage: store.snapshot != nil ? "checkmark.circle.fill" : "circle")
                    .font(.headline)
                Text("使用订阅账户登录，完成浏览器授权后返回这里重新检测。API Key 登录不适用于订阅额度。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                command(CLIReader.locate().map { CLIReader.shellQuote($0) + " login" } ?? "codex login")
                Button("打开终端登录…") { store.openLogin() }.disabled(!installed || store.loading)
            }.padding(12).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            if let error = store.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if store.snapshot != nil {
                Label("已连接，可以查看额度了。", systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(.green)
            }
            HStack {
                Button(store.loading ? "正在检测…" : "重新检测") { store.refresh() }.disabled(store.loading)
                Spacer()
                Button("开始使用") { store.finishSetup() }.disabled(store.snapshot == nil || store.loading)
                    .buttonStyle(.borderedProminent)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func command(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            Button { store.copyCommand(text) } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless).help("复制命令")
        }.padding(8).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
    }
}
typealias ViewState<Value> = SwiftUI.State<Value>
struct PanelView: View {
    @ObservedObject var store: Store
    @ViewState private var contentHeight: CGFloat = 320
    @ViewState private var showCredits = false
    @ViewState private var showInfo = false
    init(store: Store, expanded: Bool = false) {
        self.store = store
        _showCredits = ViewState(initialValue: expanded)
    }
    private var nearestExpiry: Date? {
        store.snapshot?.rateLimitResetCredits?.credits?.compactMap { $0.expiresAt }.min().map(Date.init(timeIntervalSince1970:))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(nsImage: EnergyMark.image(remaining: store.snapshot?.mainWindow?.remaining, direction: store.depletionDirection)).foregroundStyle(Color.accentColor)
                Text("近星点").font(.headline).fixedSize()
                Spacer(minLength: 4)
                HStack(spacing: 4) {
                    if store.loading { ProgressView().controlSize(.mini) }
                    else { Circle().fill(store.error == nil ? Color.green : Color.orange).frame(width: 5, height: 5) }
                    Text(updateText).font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                }.help("\(updateText)\n\(dateText(store.updatedAt))")
                Button { store.refresh() } label: {
                    toolbarIcon("arrow.clockwise")
                }.buttonStyle(.plain).disabled(store.loading).help("刷新额度")
                Button { showInfo.toggle() } label: {
                    toolbarIcon("info.circle")
                }.buttonStyle(.plain)
                    .accessibilityLabel("查看额度说明")
                    .popover(isPresented: $showInfo, arrowEdge: .top) {
                        UsageInfoView { showInfo = false }
                    }
                Menu {
                    Picker("主题", selection: $store.theme) {
                        ForEach(AppTheme.allCases) { theme in Text(theme.title).tag(theme) }
                    }.pickerStyle(.menu)
                    Divider()
                    Picker("能量格熄灭方向", selection: $store.depletionDirection) {
                        ForEach(DepletionDirection.allCases) { direction in Text(direction.title).tag(direction) }
                    }.pickerStyle(.menu)
                    Picker("菜单栏显示", selection: $store.menuBarDisplay) {
                        ForEach(MenuBarDisplay.allCases) { mode in Text(mode.title).tag(mode) }
                    }.pickerStyle(.menu)
                    Picker("进度条分段", selection: $store.progressStyle) {
                        ForEach(ProgressStyle.allCases) { style in
                            Text(style.title).tag(style)
                        }
                    }.pickerStyle(.menu)
                    Divider()
                    Button("连接与登录引导…") { store.showSetup = true; store.refresh() }
                    Button("选择 Codex CLI…") { store.chooseCLI() }
                    Divider()
                    Button("退出 近星点") { NSApp.terminate(nil) }
                } label: { toolbarIcon("gearshape") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).foregroundStyle(.secondary).fixedSize().help("设置")
            }
            ScrollView {
                content
                    .fixedSize(horizontal: false, vertical: true)
                    .background(GeometryReader { geometry in
                        Color.clear.preference(key: ContentHeightKey.self, value: geometry.size.height)
                    })
            }
            .frame(height: min(contentHeight, 480))
            .onPreferenceChange(ContentHeightKey.self) { height in
                if height > 0 && abs(contentHeight - height) > 0.5 { contentHeight = height }
            }

        }.padding(16).frame(width: 400)
        .background {
            if store.theme == .readable {
                Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
            }
        }
    }
    private func toolbarIcon(_ name: String) -> some View {
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.secondaryLabelColor]))
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) ?? NSImage()
        image.isTemplate = false
        return Image(nsImage: image)
            .renderingMode(.original)
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
    }
    private var updateText: String {
        if store.loading { return "正在刷新…" }
        guard let date = store.updatedAt else { return "尚未获取额度" }
        let minutes = max(0, Int(store.now.timeIntervalSince(date) / 60))
        let relative = minutes == 0 ? "刚刚更新" : "\(minutes) 分钟前更新"
        return store.error == nil ? relative : "上次成功：\(shortDate(date))"
    }
    @ViewBuilder private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            if store.showSetup {
                SetupView(store: store)
            } else if let snapshot = store.snapshot {
                ForEach(snapshot.buckets, id: \.0) { key, bucket in
                    let name = bucket.limitName ?? (key == "codex" ? "Codex" : key)
                    ForEach(bucket.orderedWindows, id: \.0) { _, window in
                        WindowView(resetNews: store.resetNews, showsResetNews: key == "codex", resetCredits: snapshot.rateLimitResetCredits?.credits ?? [], title: windowTitle(name, window, plan: bucket.planType ?? store.planType), window: window, now: store.now, progressStyle: store.progressStyle).id(store.panelSession)
                    }
                }
                if snapshot.buckets.isEmpty { Text("当前账户未返回额度窗口。").foregroundStyle(.secondary) }
                if snapshot.rateLimitResetCredits != nil {
                VStack(alignment: .leading, spacing: 8) {
                    Button { showCredits.toggle() } label: {
                        HStack {
                            Text("可用重置").font(.subheadline.weight(.medium))
                            Text(snapshot.rateLimitResetCredits?.availableCount.map { "\($0) 次" } ?? "暂无数据").font(.subheadline.weight(.semibold))
                            Spacer()
                            if let nearestExpiry {
                                Text("最近到期 \(creditExpirySummary(nearestExpiry, now: store.now))")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.85)
                                    .help("到期时间：\(dateText(nearestExpiry))\n\(creditTimeRemaining(nearestExpiry, now: store.now))")
                            }
                            if let credits = snapshot.rateLimitResetCredits?.credits, !credits.isEmpty {
                                Image(systemName: showCredits ? "chevron.up" : "chevron.down")
                                    .foregroundStyle(.secondary).frame(width: 20, height: 20)
                            }
                        }.frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .disabled(snapshot.rateLimitResetCredits?.credits?.isEmpty != false)
                        .help(showCredits ? "收起到期明细" : "展开到期明细")
                        .accessibilityLabel(showCredits ? "收起重置机会明细" : "展开重置机会明细")
                    if showCredits, let credits = snapshot.rateLimitResetCredits?.credits {
                        Divider()
                        ForEach(Array(credits.sorted { ($0.expiresAt ?? .infinity) < ($1.expiresAt ?? .infinity) }.enumerated()), id: \.offset) { index, credit in
                            HStack {
                                Text("重置机会 \(index + 1)").foregroundStyle(.secondary)
                                Spacer()
                                let expiry = credit.expiresAt.map(Date.init(timeIntervalSince1970:))
                                Text(expiry.map { creditExpirySummary($0, now: store.now) } ?? "未提供到期时间")
                                    .lineLimit(1).minimumScaleFactor(0.85)
                                    .help("到期时间：\(dateText(expiry))\n\(creditTimeRemaining(expiry, now: store.now))")
                            }.font(.caption).monospacedDigit()
                        }
                    }
                }.padding(.horizontal, 2)
                }
            } else if store.error == nil {
                Text("正在读取本机 Codex 账户额度…").foregroundStyle(.secondary).padding(.vertical, 24)
            }
            if !store.showSetup, let error = store.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange).textSelection(.enabled)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let store: Store
    var status: NSStatusItem!
    var popover = NSPopover()
    private var themeUpdate: DispatchWorkItem?
    private var focusObserversInstalled = false
    private var renderedLevel = -2
    private var renderedDirection: DepletionDirection?
    init(store: Store = Store()) { self.store = store; super.init() }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.target = self; status.button?.action = #selector(toggle)
        status.button?.imagePosition = .imageLeading
        popover = makePopover()
        installFocusObservers()
        store.onChange = { [weak self] in self?.updateTitle() }
        store.onThemeChange = { [weak self] in self?.scheduleThemeUpdate() }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(wake), name: NSWorkspace.didWakeNotification, object: nil)
        updateTitle(); store.refresh()
        if store.showSetup {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.toggle() }
        }
    }
    func installFocusObservers() {
        guard !focusObserversInstalled else { return }
        focusObserversInstalled = true
        NotificationCenter.default.addObserver(self, selector: #selector(applicationDidDeactivate), name: NSApplication.didResignActiveNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(workspaceApplicationActivated(_:)), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(menuDidEndTracking), name: NSMenu.didEndTrackingNotification, object: nil)
    }
    func closeForExternalFocus() {
        themeUpdate?.cancel()
        themeUpdate = nil
        if popover.isShown {
            let animates = popover.animates
            popover.animates = false
            popover.close()
            popover.animates = animates
        }
    }
    @objc func applicationDidDeactivate() { closeForExternalFocus() }
    @objc func workspaceApplicationActivated(_ notification: Notification) {
        guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        closeForExternalFocus()
    }
    @objc func menuDidEndTracking() {
        // Menu tracking may consume the outside click before the popover receives it.
        DispatchQueue.main.async { [weak self] in
            guard !NSApp.isActive,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            self?.closeForExternalFocus()
        }
    }
    func makePopover() -> NSPopover {
        let panel = NSPopover()
        panel.behavior = .transient
        panel.delegate = self
        if #available(macOS 14.0, *) {
            panel.hasFullSizeContent = store.theme == .readable
        }
        let controller = NSHostingController(rootView: PanelView(store: store))
        controller.sizingOptions = [.preferredContentSize]
        panel.contentViewController = controller
        return panel
    }
    func scheduleThemeUpdate() {
        themeUpdate?.cancel()
        let update = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let reopen = self.popover.isShown
            // Full-size content changes the native frame and safe-area geometry.
            // Recreate the container instead of reusing geometry from another theme.
            self.popover.delegate = nil
            self.popover.animates = false
            self.popover.close()
            self.store.endPanelSession()
            self.popover = self.makePopover()
            if reopen, let button = self.status.button {
                self.popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        themeUpdate = update
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: update)
    }
    func updateTitle() {
        let expired = store.snapshot?.hasExpiredWindow(at: store.now) ?? false
        let remaining = store.snapshot?.mainWindow?.remaining
        let level = EnergyMark.level(remaining)
        if renderedLevel != level || renderedDirection != store.depletionDirection {
            status.button?.image = EnergyMark.image(remaining: remaining, direction: store.depletionDirection)
            renderedLevel = level
            renderedDirection = store.depletionDirection
        }
        let value = store.menuBarDisplay.text(window: store.snapshot?.mainWindow, now: store.now)
        let warning = store.error != nil || expired ? " !" : ""
        status.button?.title = store.menuBarDisplay == .iconOnly ? "" : " " + (value ?? (store.loading ? "…" : "—")) + warning
        let budget = MenuBarDisplay.budget.text(window: store.snapshot?.mainWindow, now: store.now)
        let description = remaining.map { "Codex 剩余额度 \(Int($0.rounded()))%" } ?? "Codex 订阅额度"
        let budgetDescription = budget.map { "\n预算偏差 \($0)\n正值领先，负值落后" } ?? ""
        status.button?.toolTip = store.error ?? "近星点 · " + description + budgetDescription
        status.button?.setAccessibilityLabel(description + budgetDescription)
    }
    @objc func toggle() {
        if popover.isShown { popover.performClose(nil) }
        else if let button = status.button {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            if !store.loading { store.refresh() }
        }
    }
    func popoverDidClose(_ notification: Notification) {
        themeUpdate?.cancel()
        themeUpdate = nil
        store.endPanelSession()
    }
    @objc func wake() { store.refresh() }
}

if let index = CommandLine.arguments.firstIndex(of: "--render-icon-levels"), CommandLine.arguments.count > index + 1 {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 600, pixelsHigh: 220, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let levels: [Double?] = [100, 75, 50, 12, 0, nil]
    for row in 0..<2 {
        let y = CGFloat(row * 110)
        (row == 0 ? NSColor(white: 0.12, alpha: 1) : NSColor.white).setFill()
        NSRect(x: 0, y: y, width: 600, height: 110).fill()
        for (column, value) in levels.enumerated() {
            let icon = EnergyMark.image(remaining: value, direction: CommandLine.arguments.contains("--clockwise") ? .clockwise : .counterclockwise)
            icon.isTemplate = false
            let tinted = NSImage(size: icon.size)
            tinted.lockFocus()
            icon.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
            (row == 0 ? NSColor.white : NSColor.black).setFill()
            NSRect(origin: .zero, size: icon.size).fill(using: .sourceAtop)
            tinted.unlockFocus()
            let x = CGFloat(column * 100)
            tinted.draw(in: NSRect(x: x + 17, y: y + 62, width: 20, height: 20))
            tinted.draw(in: NSRect(x: x + 51, y: y + 52, width: 40, height: 40))
            let label = value.map { "\(Int($0))%" } ?? "未知"
            (label as NSString).draw(at: NSPoint(x: x + 32, y: y + 21), withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: row == 0 ? NSColor.white : NSColor.black])
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
} else if let index = CommandLine.arguments.firstIndex(of: "--render-info"), CommandLine.arguments.count > index + 1 {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let host = NSHostingView(rootView: UsageInfoView {}.environment(\.colorScheme, .light).background(Color(nsColor: .windowBackgroundColor)))
    host.appearance = NSAppearance(named: .aqua)
    let size = host.fittingSize
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    window.orderBack(nil)
    RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    host.layoutSubtreeIfNeeded()
    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { exit(1) }
    host.cacheDisplay(in: host.bounds, to: bitmap)
    guard let data = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
    try data.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
    window.orderOut(nil)
} else if CommandLine.arguments.contains("--news-probe") {
    let feed = ResetNewsFeed(automaticRefresh: true)
    let deadline = Date().addingTimeInterval(20)
    while feed.checkedAt == nil && !feed.failed && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    guard feed.checkedAt != nil else { fputs("重置消息读取失败\n", stderr); exit(1) }
    print("Codex Resets 读取成功；当前消息：\(feed.notice(now: Date())?.title ?? "无待执行预告或有效动向")")
} else if let index = CommandLine.arguments.firstIndex(of: "--render-preview"), CommandLine.arguments.count > index + 1 {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let previewSuite = "org.sourcepowered.perihel.preview." + UUID().uuidString
    let previewSettings = UserDefaults(suiteName: previewSuite)!
    defer { previewSettings.removePersistentDomain(forName: previewSuite) }
    let store = Store(automaticRefresh: false, settings: previewSettings)
    store.showSetup = CommandLine.arguments.contains("--setup")
    if let index = CommandLine.arguments.firstIndex(of: "--theme"), CommandLine.arguments.count > index + 1, let theme = AppTheme(rawValue: CommandLine.arguments[index + 1]) { store.theme = theme }
    if let index = CommandLine.arguments.firstIndex(of: "--progress-style"), CommandLine.arguments.count > index + 1, let style = ProgressStyle(rawValue: CommandLine.arguments[index + 1]) { store.progressStyle = style }
    do {
        let inspection = try CLIReader.inspect()
        store.snapshot = inspection.snapshot; store.cliVersion = inspection.cliVersion; store.planType = inspection.planType; store.updatedAt = Date()
    }
    catch { store.error = error.localizedDescription }
    if let fixtureIndex = CommandLine.arguments.firstIndex(of: "--news-fixture"), CommandLine.arguments.count > fixtureIndex + 1 {
        try store.resetNews.accept(Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[fixtureIndex + 1])))
    }
    let dark = CommandLine.arguments.contains("--dark")
    let host = NSHostingView(rootView: PanelView(store: store, expanded: CommandLine.arguments.contains("--expanded")).environment(\.colorScheme, dark ? .dark : .light))
    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 410, height: 690), styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.frame = window.contentView!.bounds
    window.orderBack(nil)
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    host.layoutSubtreeIfNeeded()
    let size = host.fittingSize
    window.setContentSize(size)
    host.frame = NSRect(origin: .zero, size: size)
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    host.layoutSubtreeIfNeeded()
    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { exit(1) }
    host.cacheDisplay(in: host.bounds, to: bitmap)
    guard let data = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
    try data.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
    window.orderOut(nil)
} else if CommandLine.arguments.contains("--probe") {
    do {
        let inspection = try CLIReader.inspect()
        let snapshot = inspection.snapshot
        print("额度读取成功；套餐：\(planName(snapshot.buckets.first?.1.planType ?? inspection.planType))；窗口桶：\(snapshot.buckets.count)；剩余：\(percent(snapshot.mainWindow?.remaining))；重置机会：\(snapshot.rateLimitResetCredits?.availableCount.map(String.init) ?? "未知")")
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
