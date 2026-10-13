import AppKit
import SwiftUI
import Darwin

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
struct QuotaError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class CLIReader {
    static func locate() -> String? {
        let custom = UserDefaults.standard.string(forKey: "cliPath")
        let paths = [custom, "/opt/homebrew/bin/codex", "/usr/local/bin/codex"] .compactMap { $0 }
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/codex" }
        return paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    static func read() throws -> Snapshot {
        guard let path = locate() else { throw QuotaError(message: "找不到 Codex CLI。请安装 CLI，或通过“选择 CLI”指定可执行文件。") }
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["app-server"]
        process.standardInput = input; process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = URL(fileURLWithPath: path).deletingLastPathComponent().path + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
        process.environment = environment
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
        try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "token_tank", "title": "Token Tank", "version": "0.1.0"]]])
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
                    throw QuotaError(message: (error["message"] as? String ?? "额度查询失败") + "。请确认已通过 codex login 登录订阅账户。")
                }
                if id == 1 {
                    try send(["method": "initialized"])
                    try send(["id": 2, "method": "account/rateLimits/read"])
                } else if id == 2, let result = response["result"] {
                    return try JSONDecoder().decode(Snapshot.self, from: JSONSerialization.data(withJSONObject: result))
                }
            }
        }
        throw QuotaError(message: "额度查询超时，请检查网络后重试。")
    }
}

final class Store: ObservableObject {
    @Published var snapshot: Snapshot?
    @Published var updatedAt: Date?
    @Published var error: String?
    @Published var loading = false
    @Published var now = Date()
    var onChange: (() -> Void)?
    private var timer: Timer?
    private var lastAttempt = Date.distantPast
    init() {
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
            let result = Result { try CLIReader.read() }
            DispatchQueue.main.async {
                self.loading = false
                switch result {
                case .success(let snapshot): self.snapshot = snapshot; self.updatedAt = Date(); self.error = nil
                case .failure(let error): self.error = error.localizedDescription
                }
                self.onChange?()
            }
        }
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
func countdown(_ end: Date?, _ now: Date) -> String {
    guard let end else { return "暂无数据" }
    let seconds = Int(end.timeIntervalSince(now))
    guard seconds > 0 else { return "等待刷新重置状态" }
    return "\(seconds / 86400)天 \(seconds / 3600 % 24)时 \(seconds / 60 % 60)分 \(seconds % 60)秒"
}
struct WindowView: View {
    let title: String
    let window: Window
    let now: Date
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.headline)
            HStack { Text("实际已用"); Spacer(); Text(percent(window.usedPercent)).monospacedDigit() }
            ProgressView(value: max(0, min(100, window.usedPercent ?? 0)), total: 100).tint(.blue)
            HStack { Text("实际剩余"); Spacer(); Text(percent(window.remaining)).monospacedDigit() }
            HStack { Text("理论已用 / 剩余"); Spacer(); Text("\(percent(window.theoretical(now))) / \(percent(window.theoretical(now).map { 100 - $0 }))").monospacedDigit() }
            ProgressView(value: window.theoretical(now) ?? 0, total: 100).tint(.teal)
            if let actual = window.usedPercent, let theory = window.theoretical(now) {
                Text(String(format: "比匀速预算%@ %.1f 个百分点", actual >= theory ? "多用" : "少用", abs(actual - theory)))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            detail("开始（推算）", dateText(window.start))
            detail("下次重置", dateText(window.end))
            detail("距离重置", countdown(window.end, now))
        }.padding(14).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }
    func detail(_ name: String, _ value: String) -> some View {
        HStack { Text(name).foregroundStyle(.secondary); Spacer(); Text(value).monospacedDigit() }.font(.caption)
    }
}
struct PanelView: View {
    @ObservedObject var store: Store
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "gauge.with.dots.needle.50percent").foregroundStyle(.blue)
                Text("Token Tank").font(.title3.bold())
                Spacer()
                if store.loading { ProgressView().controlSize(.small) }
                Button { store.refresh() } label: { Image(systemName: "arrow.clockwise") }.disabled(store.loading).help("刷新额度")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let snapshot = store.snapshot {
                        ForEach(snapshot.buckets, id: \.0) { key, bucket in
                            if let primary = bucket.primary { WindowView(title: "\(bucket.limitName ?? key) · 主窗口", window: primary, now: store.now) }
                            if let secondary = bucket.secondary { WindowView(title: "\(bucket.limitName ?? key) · 次窗口", window: secondary, now: store.now) }
                        }
                        if snapshot.buckets.isEmpty { Text("当前账户未返回额度窗口。") }
                        HStack {
                            Text("剩余重置次数").font(.headline)
                            Spacer()
                            Text(snapshot.rateLimitResetCredits?.availableCount.map { "\($0) 次" } ?? "暂无数据").font(.headline)
                        }
                        if let credits = snapshot.rateLimitResetCredits?.credits {
                            ForEach(Array(credits.enumerated()), id: \.offset) { _, credit in
                                Text("重置机会到期：\(credit.expiresAt.map { dateText(Date(timeIntervalSince1970: $0)) } ?? "未提供")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } else if store.error == nil {
                        Text("正在读取本机 Codex 登录账户的额度…").foregroundStyle(.secondary).padding(.vertical, 24)
                    }
                    if let error = store.error {
                        Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                    }
                    Text("理论用量按窗口内匀速消耗计算。时间使用系统时区：\(TimeZone.current.identifier)。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.frame(maxHeight: 540)
            Divider()
            Text("\(store.error != nil ? "上次成功" : "更新")：\(dateText(store.updatedAt))").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("选择 CLI…") { store.chooseCLI() }
                Spacer()
                Button("退出") { NSApp.terminate(nil) }
            }.font(.caption)
        }.padding(16).frame(width: 410).background(Color(nsColor: .windowBackgroundColor))
    }
}
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let store = Store()
    var status: NSStatusItem!
    let popover = NSPopover()
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.target = self; status.button?.action = #selector(toggle)
        popover.behavior = .transient; popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: PanelView(store: store))
        store.onChange = { [weak self] in self?.updateTitle() }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(wake), name: NSWorkspace.didWakeNotification, object: nil)
        updateTitle(); store.refresh()
    }
    func updateTitle() {
        let expired = store.snapshot?.mainWindow?.end.map { $0 <= Date() } ?? false
        let remaining = store.snapshot?.mainWindow?.remaining
        status.button?.title = remaining.map { "剩余 \(Int($0.rounded()))%\(store.error != nil || expired ? " !" : "")" } ?? (store.loading ? "额度 …" : "额度 —")
        status.button?.toolTip = store.error ?? "Token Tank · Codex 订阅额度"
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

if CommandLine.arguments.contains("--self-test") {
    let window = Window(usedPercent: 30, windowDurationMins: 60, resetsAt: 7200)
    precondition(window.start == Date(timeIntervalSince1970: 3600))
    precondition(window.remaining == 70)
    precondition(window.theoretical(Date(timeIntervalSince1970: 5400)) == 50)
    precondition(window.theoretical(Date(timeIntervalSince1970: 0)) == 0)
    precondition(window.theoretical(Date(timeIntervalSince1970: 9000)) == 100)
    let sparse = try JSONDecoder().decode(Snapshot.self, from: Data("{\"rateLimitsByLimitId\":{},\"rateLimitResetCredits\":null}".utf8))
    precondition(sparse.buckets.isEmpty)
    print("PASS: window math, clamping, missing fields")
} else if let index = CommandLine.arguments.firstIndex(of: "--render-preview"), CommandLine.arguments.count > index + 1 {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let store = Store()
    do { store.snapshot = try CLIReader.read(); store.updatedAt = Date() }
    catch { store.error = error.localizedDescription }
    let host = NSHostingView(rootView: PanelView(store: store).environment(\.colorScheme, .light))
    host.appearance = NSAppearance(named: .aqua)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 410, height: 690), styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.frame = window.contentView!.bounds
    window.orderBack(nil)
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
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
