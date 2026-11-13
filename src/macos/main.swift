import AppKit
import SwiftUI
import Darwin

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
