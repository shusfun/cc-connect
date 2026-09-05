// FILE: RemodexMenuBarApp.swift
// Purpose: Entry point for the macOS app that owns the bundled Bridge process.
// Layer: Companion app
// Exports: RemodexMenuBarApp
// Depends on: SwiftUI, BridgeMenuBarStore, BridgeMenuBarViews

import SwiftUI

@MainActor
final class RemodexMenuBarAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let coordinator = WindowCoordinator.shared
        coordinator.configure(makeContent: { NSHostingView(rootView: BridgeMenuBarContentView(store: .shared)) }, log: { BridgeControlService.shared.record($0, stage: "window") })
        if let icon = Bundle.main.url(forResource: "Remodex", withExtension: "icns").flatMap(NSImage.init(contentsOf:)) { NSApp.applicationIconImage = icon }
        else { BridgeControlService.shared.record("app_icon_missing", stage: "window") }
        let loginLaunch = NSAppleEventManager.shared().currentAppleEvent?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        coordinator.launch(atLogin: loginLaunch, activated: DeviceAccessService.shared.isActivated)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        WindowCoordinator.shared.show()
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            BridgeControlService.shared.stopSynchronously()
        }
    }
}

@main
struct RemodexMenuBarApp: App {
    @NSApplicationDelegateAdaptor(RemodexMenuBarAppDelegate.self) private var appDelegate
    @StateObject private var store = BridgeMenuBarStore.shared

    var body: some Scene {
        MenuBarExtra {
            RemodexQuickMenu(store: store)
        } label: {
            BridgeMenuBarLabel(
                snapshot: store.snapshot,
                isBusy: store.isRefreshing || store.isPerformingAction
            )
        }
    }
}

struct RemodexQuickMenu: View {
    @ObservedObject var store: BridgeMenuBarStore
    var body: some View {
        Text(store.phase)
        Button("打开 Remodex") { WindowCoordinator.shared.show() }
        Divider()
        Button("启动 Bridge", action: store.startBridge)
        Button("停止 Bridge", action: store.stopBridge)
        Divider()
        Button("退出 Remodex") { NSApp.terminate(nil) }
    }
}
