// FILE: BridgeMenuBarStore.swift
// Purpose: Owns App-managed Bridge controls, status polling, login launch, diagnostics, and relay settings.
// Layer: Companion app state
// Exports: BridgeMenuBarStore
// Depends on: AppKit, Combine, ServiceManagement, BridgeControlService

import AppKit
import Combine
import ServiceManagement

@MainActor
final class BridgeMenuBarStore: ObservableObject {
    @Published var snapshot: BridgeSnapshot?
    @Published var relayOverride: String
    @Published var launchAtLogin = false
    @Published var isRefreshing = false
    @Published var isPerformingAction = false
    @Published var transientMessage = ""
    @Published var errorMessage = ""

    private static let relayOverrideKey = "remodex.menuBar.relayOverride"
    private static let defaultRelayURL = "wss://cc.syggu.cn"
    private let service = BridgeControlService.shared
    private var refreshLoopTask: Task<Void, Never>?

    init() {
        relayOverride = UserDefaults.standard.string(forKey: Self.relayOverrideKey)
            ?? Self.defaultRelayURL
        configureLaunchAtLoginDefault()
        refreshLoopTask = Task { @MainActor [weak self] in
            await self?.startOnLaunch()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                self?.refresh()
            }
        }
    }

    deinit {
        refreshLoopTask?.cancel()
    }

    func refresh() {
        snapshot = service.loadSnapshot(relayOverride: relayOverride)
    }

    func saveRelayOverride(_ value: String) {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            errorMessage = "Relay 地址不能为空。"
            return
        }
        relayOverride = normalized
        UserDefaults.standard.set(normalized, forKey: Self.relayOverrideKey)
        if service.isRunning {
            restartBridge()
        } else {
            refresh()
        }
    }

    func startBridge() {
        runAction(successMessage: "Bridge 已启动。") {
            try await self.service.startBridge(relayOverride: self.relayOverride)
            try await self.waitForPairing()
        }
    }

    func stopBridge() {
        runAction(successMessage: "Bridge 已停止。") {
            await self.service.stopBridge()
            self.refresh()
        }
    }

    func restartBridge() {
        runAction(successMessage: "Bridge 已重启。") {
            try await self.service.restartBridge(relayOverride: self.relayOverride)
            try await self.waitForPairing()
        }
    }

    func refreshPairing() {
        runAction(successMessage: "配对码已刷新。") {
            try await self.service.refreshPairing(relayOverride: self.relayOverride)
            try await self.waitForPairing()
        }
    }

    func resetPairing() {
        runAction(successMessage: "手机信任关系已重置。") {
            try await self.service.resetPairing(relayOverride: self.relayOverride)
            try await self.waitForPairing()
        }
    }

    func resumeLastThread() {
        runAction(successMessage: "已在 Codex Desktop 打开最近任务。") {
            try await self.service.resumeLastThread()
            self.refresh()
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = enabled
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            errorMessage = error.localizedDescription
        }
    }

    func openLogsFolder() {
        let path = snapshot?.stateDirectoryPath ?? fileManagerStatePath
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    func openPowerSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.energysaver") else { return }
        NSWorkspace.shared.open(url)
    }

    func copyDiagnostics() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(service.redactedDiagnostics(relayOverride: relayOverride), forType: .string)
        transientMessage = "脱敏诊断已复制。"
    }

    private func startOnLaunch() async {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            try await service.startBridge(relayOverride: relayOverride)
            try await waitForPairing()
        } catch {
            errorMessage = error.localizedDescription
            refresh()
        }
    }

    private func waitForPairing() async throws {
        for _ in 0..<30 {
            refresh()
            if snapshot?.pairingSession?.pairingPayload != nil {
                return
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw BridgeRuntimeError.commandFailed("Bridge 未在预期时间内生成配对码，请检查日志。")
    }

    private func configureLaunchAtLoginDefault() {
        let appService = SMAppService.mainApp
        if appService.status == .notRegistered {
            try? appService.register()
        }
        launchAtLogin = appService.status == .enabled
    }

    private func runAction(
        successMessage: String,
        operation: @escaping @MainActor () async throws -> Void
    ) {
        guard !isPerformingAction else { return }
        isPerformingAction = true
        transientMessage = ""
        errorMessage = ""
        Task { @MainActor in
            defer { isPerformingAction = false }
            do {
                try await operation()
                transientMessage = successMessage
                refresh()
            } catch {
                errorMessage = error.localizedDescription
                refresh()
            }
        }
    }

    private var fileManagerStatePath: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".remodex").path
    }
}
