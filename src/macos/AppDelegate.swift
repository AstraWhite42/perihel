import AppKit
import SwiftUI
import Darwin

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let store: Store
    var status: NSStatusItem!
    var popover = NSPopover()
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
        let controller = NSHostingController(rootView: PanelView(store: store))
        controller.sizingOptions = [.preferredContentSize]
        panel.contentViewController = controller
        return panel
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
        store.endPanelSession()
    }
    @objc func wake() { store.refresh() }
}
