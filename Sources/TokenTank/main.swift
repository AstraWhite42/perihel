import AppKit
import SwiftUI
import Darwin

enum EnergyMark {
    static func level(_ remaining: Double?) -> Int {
        guard let remaining, remaining.isFinite else { return -1 }
        return Int(ceil(max(0, min(100, remaining)) / 12.5))
    }
    static func image(remaining: Double? = 100) -> NSImage {
        let count = level(remaining)
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { _ in
            for index in 0..<8 {
                NSColor.black.withAlphaComponent(index < count ? 1 : 0.20).setStroke()
                let arc = NSBezierPath()
                let start = 90 - CGFloat(index) * 37.5
                arc.appendArc(withCenter: NSPoint(x: 10, y: 10), radius: 7.1, startAngle: start - 4, endAngle: start - 33.5, clockwise: true)
                arc.lineWidth = 2.2
                arc.lineCapStyle = .butt
                arc.stroke()
            }
            NSColor.black.setFill()
            let star = NSBezierPath()
            star.move(to: NSPoint(x: 10, y: 13.7))
            for point in [NSPoint(x: 11.1, y: 11.1), NSPoint(x: 13.7, y: 10), NSPoint(x: 11.1, y: 8.9), NSPoint(x: 10, y: 6.3), NSPoint(x: 8.9, y: 8.9), NSPoint(x: 6.3, y: 10), NSPoint(x: 8.9, y: 11.1)] { star.line(to: point) }
            star.close(); star.fill()
            let arrow = NSBezierPath()
            arrow.move(to: NSPoint(x: 5.5, y: 16.2))
            arrow.line(to: NSPoint(x: 2.1, y: 14.8))
            arrow.line(to: NSPoint(x: 5.1, y: 13))
            arrow.close(); arrow.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = remaining.map { "近星点，剩余额度 \(Int($0.rounded()))%" } ?? "近星点，额度未知"
        return image
    }
}

struct Window: Codable {
    let usedPercent: Double?
    let windowDurationMins: Double?
    let resetsAt: Double?
    var remaining: Double? { usedPercent.map { max(0, min(100, 100 - $0)) } }
    var end: Date? { resetsAt.map(Date.init(timeIntervalSince1970:)) }
    var start: Date? {
        guard let end, let minutes = windowDurationMins, minutes > 0 else { return nil }
        return end.addingTimeInterval(-minutes * 60)
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
    var mainWindow: Window? { buckets.first?.1.primary ?? buckets.first?.1.secondary }
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
        try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "token_tank", "title": "近星点", "version": AppVersion.version]]])
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
                    try send(["id": 3, "method": "account/rateLimits/read"])
                } else if id == 3, let result = response["result"] {
                    let snapshot = try JSONDecoder().decode(Snapshot.self, from: JSONSerialization.data(withJSONObject: result))
                    return Inspection(snapshot: snapshot, cliVersion: cliVersion)
                }
            }
        }
        throw QuotaError(message: "额度查询超时，请检查网络后重试。")
    }
}

enum ProgressStyle: String, CaseIterable, Identifiable {
    case calendarDays, rollingDays, continuous
    var id: String { rawValue }
    var title: String {
        switch self {
        case .calendarDays: return "按每日零点分段"
        case .rollingDays: return "每 24 小时分段"
        case .continuous: return "不分段"
        }
    }
    func boundaries(start: Date?, end: Date?, calendar: Calendar = .current) -> [Date] {
        guard self != .continuous, let start, let end, end > start else { return [] }
        var points = [start]
        var current = start
        while points.count <= 512 {
            let next: Date?
            if self == .calendarDays { next = calendar.dateInterval(of: .day, for: current)?.end }
            else { next = current.addingTimeInterval(86400) }
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
    @Published var cliVersion: String?
    @Published var setupIssue: SetupIssue?
    @Published var showSetup: Bool
    @Published var showPercentage: Bool {
        didSet {
            settings.set(showPercentage, forKey: "showPercentage")
            onChange?()
        }
    }
    @Published var progressStyle: ProgressStyle {
        didSet { settings.set(progressStyle.rawValue, forKey: "progressStyle") }
    }
    var onChange: (() -> Void)?
    private let settings: UserDefaults
    private var timer: Timer?
    private var lastAttempt = Date.distantPast
    init(automaticRefresh: Bool = true, settings: UserDefaults = .standard) {
        self.settings = settings
        showSetup = !settings.bool(forKey: "hasCompletedSetup")
        showPercentage = settings.object(forKey: "showPercentage") as? Bool ?? true
        progressStyle = settings.string(forKey: "progressStyle").flatMap(ProgressStyle.init(rawValue:)) ?? .calendarDays
        guard automaticRefresh else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.now = Date()
            let expired = self.snapshot?.mainWindow?.end.map { $0 <= self.now } ?? false
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
                    self.snapshot = inspection.snapshot; self.cliVersion = inspection.cliVersion
                    self.updatedAt = Date(); self.error = nil; self.setupIssue = nil
                case .failure(let error):
                    self.error = error.localizedDescription
                    self.setupIssue = (error as? QuotaError)?.issue
                    if self.setupIssue != nil {
                        self.showSetup = true
                        self.snapshot = nil; self.updatedAt = nil
                    }
                }
                self.onChange?()
            }
        }
    }
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
func windowTitle(_ name: String, _ window: Window) -> String {
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
    private var boundaries: [Date] { style.boundaries(start: window.start, end: window.end) }
    private func position(_ date: Date, width: CGFloat) -> CGFloat {
        guard let start = window.start, let end = window.end, end > start else { return 0 }
        return width * date.timeIntervalSince(start) / end.timeIntervalSince(start)
    }
    var body: some View {
        let points = boundaries
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Capsule().fill(Color.primary.opacity(0.08)).frame(height: 8).offset(y: 4)
                if let actual {
                    Capsule().fill(Color.accentColor)
                        .frame(width: geometry.size.width * max(0, min(100, actual)) / 100, height: 8).offset(y: 4)
                }
                if points.count > 2 {
                    ForEach(Array(points.dropFirst().dropLast().enumerated()), id: \.offset) { _, date in
                        Rectangle().fill(Color(nsColor: .windowBackgroundColor))
                            .frame(width: 2, height: 8)
                            .offset(x: position(date, width: geometry.size.width) - 1, y: 4)
                    }
                }
                if let theory {
                    RoundedRectangle(cornerRadius: 1).fill(Color.primary.opacity(0.75))
                        .frame(width: 2, height: 16)
                        .offset(x: max(0, min(geometry.size.width - 2, geometry.size.width * theory / 100 - 1)))
                }
                if points.count > 1 {
                    ForEach(0..<(points.count - 1), id: \.self) { index in
                        let left = position(points[index], width: geometry.size.width)
                        let right = position(points[index + 1], width: geometry.size.width)
                        if right - left >= 20 {
                            Text(label(index, points: points)).font(.system(size: 8.5)).foregroundStyle(.secondary)
                                .lineLimit(1).minimumScaleFactor(0.8)
                                .frame(width: right - left).offset(x: left, y: 21)
                                .help("\(dateText(points[index])) 至 \(dateText(points[index + 1]))")
                        }
                    }
                }
            }
        }.frame(height: points.count > 1 ? 35 : 16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(style.title)，实际已用 \(percent(actual))，理论已用 \(percent(theory))")
    }
    private func label(_ index: Int, points: [Date]) -> String {
        if style == .rollingDays {
            let hours = points[index + 1].timeIntervalSince(points[index]) / 3600
            if hours < 24 { return String(format: "%g小时", hours) }
            return "第\(index + 1)天"
        }
        let formatter = DateFormatter()
        let calendar = Calendar.current
        let sameMonth = calendar.component(.month, from: points.first!) == calendar.component(.month, from: points.last!) && calendar.component(.year, from: points.first!) == calendar.component(.year, from: points.last!)
        formatter.dateFormat = sameMonth ? "d日" : "M/d"
        return formatter.string(from: points[index])
    }
}
struct WindowView: View {
    let title: String
    let window: Window
    let now: Date
    let progressStyle: ProgressStyle
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
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
            Grid(horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("用量").frame(maxWidth: .infinity, alignment: .leading)
                    Text("已用").frame(width: 78, alignment: .trailing)
                    Text("剩余").frame(width: 78, alignment: .trailing)
                }.font(.caption).foregroundStyle(.secondary)
                usageRow("实际", window.usedPercent, window.remaining)
                usageRow("理论", window.theoretical(now), window.theoretical(now).map { 100 - $0 })
            }.font(.subheadline).monospacedDigit()
            VStack(alignment: .leading, spacing: 5) {
                UsageBar(actual: window.usedPercent, theory: window.theoretical(now), window: window, style: progressStyle)
                HStack(spacing: 5) {
                    Circle().fill(Color.accentColor).frame(width: 5, height: 5)
                    Text("实际已用")
                    Text("·")
                    Text("刻度为理论进度")
                }.font(.caption2).foregroundStyle(.secondary)
            }
            if let actual = window.usedPercent, let theory = window.theoretical(now) {
                Text(String(format: "比匀速预算%@ %.1f 个百分点", actual >= theory ? "多用" : "少用", abs(actual - theory)))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            VStack(spacing: 6) {
                detail("开始（推算）", window.start)
                detail("下次重置", window.end)
            }
        }.padding(14).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }
    func usageRow(_ title: String, _ used: Double?, _ remaining: Double?) -> some View {
        GridRow {
            Text(title).frame(maxWidth: .infinity, alignment: .leading)
            Text(percent(used)).frame(width: 78, alignment: .trailing)
            Text(percent(remaining)).frame(width: 78, alignment: .trailing)
        }
    }
    func detail(_ name: String, _ date: Date?) -> some View {
        HStack { Text(name).foregroundStyle(.secondary); Spacer(); Text(shortDate(date)).monospacedDigit().help(dateText(date)) }.font(.caption)
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
private typealias ViewState<Value> = SwiftUI.State<Value>
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
                Image(nsImage: EnergyMark.image(remaining: store.snapshot?.mainWindow?.remaining)).foregroundStyle(Color.accentColor)
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
                    Toggle("菜单栏显示百分比", isOn: $store.showPercentage)
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

        }.padding(16).frame(width: 400).background(Color(nsColor: .windowBackgroundColor))
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
                    if let primary = bucket.primary { WindowView(title: windowTitle(name, primary), window: primary, now: store.now, progressStyle: store.progressStyle) }
                    if let secondary = bucket.secondary { WindowView(title: windowTitle(name, secondary), window: secondary, now: store.now, progressStyle: store.progressStyle) }
                }
                if snapshot.buckets.isEmpty { Text("当前账户未返回额度窗口。").foregroundStyle(.secondary) }
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("可用重置").font(.subheadline.weight(.medium))
                        Text(snapshot.rateLimitResetCredits?.availableCount.map { "\($0) 次" } ?? "暂无数据").font(.subheadline.weight(.semibold))
                        Spacer()
                        if let credits = snapshot.rateLimitResetCredits?.credits, !credits.isEmpty {
                            Button { showCredits.toggle() } label: {
                                Image(systemName: showCredits ? "chevron.up" : "chevron.down").frame(width: 20, height: 20)
                            }.buttonStyle(.borderless).help(showCredits ? "收起到期明细" : "展开到期明细")
                        }
                    }
                    if let nearestExpiry {
                        Text("最近到期 · \(shortDate(nearestExpiry))").font(.caption).foregroundStyle(.secondary).help(dateText(nearestExpiry))
                    }
                    if showCredits, let credits = snapshot.rateLimitResetCredits?.credits {
                        Divider()
                        ForEach(Array(credits.sorted { ($0.expiresAt ?? .infinity) < ($1.expiresAt ?? .infinity) }.enumerated()), id: \.offset) { index, credit in
                            HStack {
                                Text("重置机会 \(index + 1)").foregroundStyle(.secondary)
                                Spacer()
                                let expiry = credit.expiresAt.map(Date.init(timeIntervalSince1970:))
                                Text(expiry.map { shortDate($0) + " 到期" } ?? "未提供到期时间").help(dateText(expiry))
                            }.font(.caption).monospacedDigit()
                        }
                    }
                }.padding(.horizontal, 2)
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
    let store = Store()
    var status: NSStatusItem!
    let popover = NSPopover()
    private var renderedLevel = -2
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.target = self; status.button?.action = #selector(toggle)
        status.button?.imagePosition = .imageLeading
        popover.behavior = .transient; popover.delegate = self
        let controller = NSHostingController(rootView: PanelView(store: store))
        controller.sizingOptions = [.preferredContentSize]
        popover.contentViewController = controller
        store.onChange = { [weak self] in self?.updateTitle() }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(wake), name: NSWorkspace.didWakeNotification, object: nil)
        updateTitle(); store.refresh()
        if store.showSetup {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.toggle() }
        }
    }
    func updateTitle() {
        let expired = store.snapshot?.mainWindow?.end.map { $0 <= Date() } ?? false
        let remaining = store.snapshot?.mainWindow?.remaining
        let level = EnergyMark.level(remaining)
        if renderedLevel != level {
            status.button?.image = EnergyMark.image(remaining: remaining)
            renderedLevel = level
        }
        status.button?.title = store.showPercentage ? (remaining.map { " \(Int($0.rounded()))%\(store.error != nil || expired ? " !" : "")" } ?? (store.loading ? " …" : " —")) : ""
        status.button?.toolTip = store.error ?? remaining.map { "近星点 · Codex 剩余额度 \(Int($0.rounded()))%" } ?? "近星点 · Codex 订阅额度"
        status.button?.setAccessibilityLabel(remaining.map { "Codex 剩余额度 \(Int($0.rounded()))%" } ?? "Codex 订阅额度")
    }
    @objc func toggle() {
        if popover.isShown { popover.performClose(nil) }
        else if let button = status.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
            if !store.loading { store.refresh() }
        }
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
            let icon = EnergyMark.image(remaining: value)
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
} else if CommandLine.arguments.contains("--self-test") {
    precondition(EnergyMark.level(nil) == -1)
    precondition(EnergyMark.level(0) == 0)
    precondition(EnergyMark.level(1) == 1)
    precondition(EnergyMark.level(12.5) == 1)
    precondition(EnergyMark.level(12.6) == 2)
    precondition(EnergyMark.level(93) == 8)
    precondition(EnergyMark.level(100) == 8)
    let window = Window(usedPercent: 30, windowDurationMins: 60, resetsAt: 7200)
    precondition(window.start == Date(timeIntervalSince1970: 3600))
    precondition(window.remaining == 70)
    precondition(window.theoretical(Date(timeIntervalSince1970: 5400)) == 50)
    precondition(window.theoretical(Date(timeIntervalSince1970: 0)) == 0)
    precondition(window.theoretical(Date(timeIntervalSince1970: 9000)) == 100)
    let sparse = try JSONDecoder().decode(Snapshot.self, from: Data("{\"rateLimitsByLimitId\":{},\"rateLimitResetCredits\":null}".utf8))
    precondition(sparse.buckets.isEmpty)
    let suiteName = "org.sourcepowered.tokentank.tests." + UUID().uuidString
    let preferences = UserDefaults(suiteName: suiteName)!
    defer { preferences.removePersistentDomain(forName: suiteName) }
    let settingsStore = Store(automaticRefresh: false, settings: preferences)
    precondition(settingsStore.showSetup && settingsStore.showPercentage && settingsStore.progressStyle == .calendarDays)
    var changes = 0
    settingsStore.onChange = { changes += 1 }
    settingsStore.showPercentage = false
    settingsStore.progressStyle = .continuous
    precondition(changes == 1)
    settingsStore.snapshot = sparse
    settingsStore.finishSetup()
    let reloaded = Store(automaticRefresh: false, settings: preferences)
    precondition(!reloaded.showSetup && !reloaded.showPercentage && reloaded.progressStyle == .continuous)
    preferences.set("unknown", forKey: "progressStyle")
    precondition(Store(automaticRefresh: false, settings: preferences).progressStyle == .calendarDays)
    let iso = ISO8601DateFormatter()
    let start = iso.date(from: "2026-10-13T13:00:00+08:00")!
    let end = start.addingTimeInterval(7 * 86400)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    let equal = ProgressStyle.rollingDays.boundaries(start: start, end: end, calendar: calendar)
    precondition(equal.count == 8)
    precondition(zip(equal, equal.dropFirst()).allSatisfy { $1.timeIntervalSince($0) == 86400 })
    let civil = ProgressStyle.calendarDays.boundaries(start: start, end: end, calendar: calendar)
    precondition(civil.count == 9)
    precondition(civil[1].timeIntervalSince(start) == 11 * 3600)
    precondition(end.timeIntervalSince(civil[civil.count - 2]) == 13 * 3600)
    let midnight = calendar.startOfDay(for: start)
    precondition(ProgressStyle.calendarDays.boundaries(start: midnight, end: midnight.addingTimeInterval(7 * 86400), calendar: calendar).count == 8)
    precondition(ProgressStyle.continuous.boundaries(start: start, end: end).isEmpty)
    precondition(ProgressStyle.calendarDays.boundaries(start: nil, end: end).isEmpty)
    let short = ProgressStyle.rollingDays.boundaries(start: start, end: start.addingTimeInterval(5 * 3600))
    precondition(short.count == 2)
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    for (first, last, hours) in [("2026-03-08T00:00:00-08:00", "2026-03-09T00:00:00-07:00", 23), ("2026-11-01T00:00:00-07:00", "2026-11-02T00:00:00-08:00", 25)] {
        let days = ProgressStyle.calendarDays.boundaries(start: iso.date(from: first), end: iso.date(from: last), calendar: calendar)
        precondition(days.count == 2 && days[1].timeIntervalSince(days[0]) == Double(hours * 3600))
    }
    print("PASS: window math, missing fields, quota icon levels, preferences, progress boundaries and DST")
} else if let index = CommandLine.arguments.firstIndex(of: "--render-preview"), CommandLine.arguments.count > index + 1 {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let previewSuite = "org.sourcepowered.tokentank.preview." + UUID().uuidString
    let previewSettings = UserDefaults(suiteName: previewSuite)!
    defer { previewSettings.removePersistentDomain(forName: previewSuite) }
    let store = Store(automaticRefresh: false, settings: previewSettings)
    store.showSetup = CommandLine.arguments.contains("--setup")
    if let index = CommandLine.arguments.firstIndex(of: "--progress-style"), CommandLine.arguments.count > index + 1, let style = ProgressStyle(rawValue: CommandLine.arguments[index + 1]) { store.progressStyle = style }
    do {
        let inspection = try CLIReader.inspect()
        store.snapshot = inspection.snapshot; store.cliVersion = inspection.cliVersion; store.updatedAt = Date()
    }
    catch { store.error = error.localizedDescription }
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
        let snapshot = try CLIReader.read()
        print("额度读取成功；窗口桶：\(snapshot.buckets.count)；剩余：\(percent(snapshot.mainWindow?.remaining))；重置机会：\(snapshot.rateLimitResetCredits?.availableCount.map(String.init) ?? "未知")")
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
