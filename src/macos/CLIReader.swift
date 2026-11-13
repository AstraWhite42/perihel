import AppKit
import SwiftUI
import Darwin

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
