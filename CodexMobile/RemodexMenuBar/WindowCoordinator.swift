import AppKit

/// 窗口和 Dock 只在此处切换；不拥有、启动或停止 Bridge。
@MainActor
final class WindowCoordinator: NSObject, NSWindowDelegate {
    static let shared = WindowCoordinator()
    private(set) var window: NSWindow?
    private var makeContent: (() -> NSView)?
    private var log: (String) -> Void = { _ in }
    private var pendingShow = false
    private var generation = 0

    func configure(makeContent: @escaping () -> NSView, log: @escaping (String) -> Void) {
        self.makeContent = makeContent; self.log = log
        if pendingShow { show() }
    }
    func launch(atLogin: Bool, activated: Bool) {
        if atLogin && activated { setPolicy(.accessory) } else { show() }
    }
    private func setPolicy(_ policy: NSApplication.ActivationPolicy) {
        guard NSApp.activationPolicy() != policy else { return }
        if NSApp.setActivationPolicy(policy) { log(policy == .regular ? "dock_shown" : "dock_hidden") }
        else { log("dock_policy_failed") }
    }
    func show() {
        guard let makeContent else { pendingShow = true; return }
        pendingShow = false; generation += 1
        setPolicy(.regular)
        if window == nil {
            let created = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 680), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            created.title = "Remodex"; created.identifier = NSUserInterfaceItemIdentifier("remodex-management")
            created.minSize = NSSize(width: 820, height: 600); created.isReleasedWhenClosed = false
            created.contentView = makeContent(); created.delegate = self; created.center(); window = created
        }
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); log("window_shown")
    }
    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        generation += 1; let closing = generation; log("window_closed")
        // 延迟到关闭完成，避免关窗与立即重开竞争导致新窗口的 Dock 被隐藏。
        Task { @MainActor in
            guard self.generation == closing else { return }
            self.setPolicy(.accessory)
        }
    }
    func windowDidMiniaturize(_ notification: Notification) { log("window_minimized") }
}
