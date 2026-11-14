import AppKit
import SwiftUI
import Darwin

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
        didSet { settings.set(theme.rawValue, forKey: "theme") }
    }
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
