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
    init(automaticRefresh: Bool = true) {
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
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                if let actual {
                    Capsule().fill(Color.accentColor)
                        .frame(width: geometry.size.width * max(0, min(100, actual)) / 100)
                }
                if let theory {
                    RoundedRectangle(cornerRadius: 1).fill(Color.primary.opacity(0.75))
                        .frame(width: 2, height: 14)
                        .offset(x: max(0, min(geometry.size.width - 2, geometry.size.width * theory / 100 - 1)))
                }
            }.frame(height: 8).frame(maxHeight: .infinity)
        }.frame(height: 16)
        .accessibilityLabel("实际已用 \(percent(actual))，理论已用 \(percent(theory))")
    }
}
struct WindowView: View {
    let title: String
    let window: Window
    let now: Date
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
                UsageBar(actual: window.usedPercent, theory: window.theoretical(now))
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
                Image(systemName: "gauge.with.dots.needle.50percent").foregroundStyle(Color.accentColor)
                Text("Token Tank").font(.headline).fixedSize()
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
                    Button("选择 Codex CLI…") { store.chooseCLI() }
                    Divider()
                    Button("退出 Token Tank") { NSApp.terminate(nil) }
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
            if let snapshot = store.snapshot {
                ForEach(snapshot.buckets, id: \.0) { key, bucket in
                    let name = bucket.limitName ?? (key == "codex" ? "Codex" : key)
                    if let primary = bucket.primary { WindowView(title: windowTitle(name, primary), window: primary, now: store.now) }
                    if let secondary = bucket.secondary { WindowView(title: windowTitle(name, secondary), window: secondary, now: store.now) }
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
            if let error = store.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange).textSelection(.enabled)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
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
        let icon = NSImage(systemSymbolName: "gauge.with.dots.needle.50percent", accessibilityDescription: "Codex 剩余额度")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
        icon?.isTemplate = true
        status.button?.image = icon
        status.button?.imagePosition = .imageLeading
        popover.behavior = .transient; popover.delegate = self
        let controller = NSHostingController(rootView: PanelView(store: store))
        controller.sizingOptions = [.preferredContentSize]
        popover.contentViewController = controller
        store.onChange = { [weak self] in self?.updateTitle() }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(wake), name: NSWorkspace.didWakeNotification, object: nil)
        updateTitle(); store.refresh()
    }
    func updateTitle() {
        let expired = store.snapshot?.mainWindow?.end.map { $0 <= Date() } ?? false
        let remaining = store.snapshot?.mainWindow?.remaining
        status.button?.title = remaining.map { " \(Int($0.rounded()))%\(store.error != nil || expired ? " !" : "")" } ?? (store.loading ? " …" : " —")
        status.button?.toolTip = store.error ?? remaining.map { "Token Tank · Codex 剩余额度 \(Int($0.rounded()))%" } ?? "Token Tank · Codex 订阅额度"
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

if let index = CommandLine.arguments.firstIndex(of: "--render-info"), CommandLine.arguments.count > index + 1 {
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
    let store = Store(automaticRefresh: false)
    do { store.snapshot = try CLIReader.read(); store.updatedAt = Date() }
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
