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
    static let shared = BridgeMenuBarStore()
    @Published var snapshot: BridgeSnapshot?
    @Published var relayOverride: String
    @Published var launchAtLogin = false
    @Published var isRefreshing = false
    @Published var isPerformingAction = false
    @Published var transientMessage = ""
    @Published var errorMessage = ""
    @Published var phase = "未启动"
    @Published var errorCode = ""
    @Published var operationID = UUID()
    @Published var logUnavailable = false

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
                await DeviceAccessService.shared.refresh()
            }
        }
    }

    deinit {
        refreshLoopTask?.cancel()
    }

    func refresh() {
        snapshot = service.loadSnapshot(relayOverride: relayOverride)
        logUnavailable = service.logFailure
        if !isPerformingAction && service.isRunning {
            if snapshot?.bridgeStatus?.connectionStatus == "connected" { phase = "已连接" }
            else { phase = "等待 Relay 连接" }
        }
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
        guard DeviceAccessService.shared.isActivated else {
            phase = "等待设备激活"; errorCode = "activation_required"
            errorMessage = "请先在连接与配对页面使用 GitHub 激活设备，再启动 Bridge。"
            service.record("activation_required"); showWindow(); return
        }
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
        runAction(successMessage: "配对码已刷新。", stopOnFailure: false) {
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
        pasteboard.setString(service.redactedDiagnostics(relayOverride: relayOverride) + "\n阶段：\(phase)\n错误码：\(errorCode)\n操作：\(operationID)", forType: .string)
        transientMessage = "脱敏诊断已复制。"
    }

    private func startOnLaunch() async {
        guard DeviceAccessService.shared.isActivated else { refresh(); return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            try await service.startBridge(relayOverride: relayOverride)
            try await waitForPairing()
        } catch {
            service.record("automatic_start_failed")
            phase = "启动失败"; errorCode = "automatic_start_failed"
            errorMessage = error.localizedDescription
            showWindow()
            refresh()
        }
    }

    private func waitForPairing() async throws {
        phase = "连接 Relay"
        for _ in 0..<150 {
            refresh()
            guard service.isRunning else { throw BridgeRuntimeError.commandFailed("Bridge 进程已退出（\(service.lastExitCode.map(String.init) ?? "未知")），请打开诊断查看日志。") }
            if let code = snapshot?.bridgeStatus?.lastError, !code.isEmpty {
                let messages = ["invalid_relay_path": "Relay 路径不正确，请更新应用。", "invalid_device_proof": "设备签名校验失败，请核对激活状态。", "credential_invalid": "设备凭据已失效，请重新激活。", "access_revoked": "设备授权已撤销。", "relay_handshake_rejected": "Relay 拒绝连接，请查看诊断编号。", "relay_dns_failed": "Relay 域名解析失败。", "relay_connection_refused": "Relay 拒绝网络连接。", "relay_tls_failed": "Relay TLS 证书校验失败。"]
                errorMessage = messages[code] ?? "Relay 连接未完成（\(code)）"
                errorCode = code
            }
            if snapshot?.bridgeStatus?.connectionStatus == "connected" {
                phase = (snapshot?.trustedDevice?.trustedPhoneCount ?? 0) > 0 ? "已配对" : "可配对"
                service.record("relay_ready", operation: operationID)
                return
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        await service.stopBridge()
        throw BridgeRuntimeError.commandFailed(errorMessage.isEmpty ? "连接 Relay 超时，本次 Bridge 已停止。" : errorMessage)
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
        stopOnFailure: Bool = true,
        operation: @escaping @MainActor () async throws -> Void
    ) {
        guard !isPerformingAction else { transientMessage = "正在处理，请等待当前操作完成。"; return }
        operationID = UUID(); phase = "前置检查"; errorCode = ""
        service.record("action_started", operation: operationID)
        isPerformingAction = true
        transientMessage = ""
        errorMessage = ""
        Task { @MainActor in
            defer { isPerformingAction = false }
            do {
                try await operation()
                transientMessage = successMessage
                if !service.isRunning { phase = "已停止" }
                refresh()
            } catch {
                if stopOnFailure { await self.service.stopBridge() }
                phase = "操作失败"; errorCode = "bridge_action_failed"
                service.record("action_failed", operation: operationID)
                errorMessage = error.localizedDescription
                showWindow()
                refresh()
            }
        }
    }

    func showWindow() {
        WindowCoordinator.shared.show()
    }

    private var fileManagerStatePath: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".remodex").path
    }
}
