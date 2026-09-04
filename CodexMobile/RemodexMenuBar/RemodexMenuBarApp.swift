// FILE: RemodexMenuBarApp.swift
// Purpose: Entry point for the macOS app that owns the bundled Bridge process.
// Layer: Companion app
// Exports: RemodexMenuBarApp
// Depends on: SwiftUI, BridgeMenuBarStore, BridgeMenuBarViews

import SwiftUI

final class RemodexMenuBarAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            BridgeControlService.shared.stopSynchronously()
        }
    }
}

@main
struct RemodexMenuBarApp: App {
    @NSApplicationDelegateAdaptor(RemodexMenuBarAppDelegate.self) private var appDelegate
    @StateObject private var store = BridgeMenuBarStore()

    var body: some Scene {
        MenuBarExtra {
            BridgeMenuBarContentView(store: store)
        } label: {
            BridgeMenuBarLabel(
                snapshot: store.snapshot,
                isBusy: store.isRefreshing || store.isPerformingAction
            )
        }
        .menuBarExtraStyle(.window)
    }
}
