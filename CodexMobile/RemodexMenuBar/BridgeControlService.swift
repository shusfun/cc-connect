// FILE: BridgeControlService.swift
// Purpose: Owns the single bundled Bridge process for the lifetime of Remodex.app.
// Layer: Companion app service
// Exports: BridgeControlService, BridgeRuntimeError
// Depends on: CryptoKit, Darwin, Foundation, BridgeControlModels

import CryptoKit
import Darwin
import Foundation

enum BridgeRuntimeError: LocalizedError {
    case runtimeMissing(String)
    case relayMissing
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .runtimeMissing(let path):
            return "App 内置 Bridge runtime 不完整：\(path)"
        case .relayMissing:
            return "请先配置 Relay 地址。"
        case .commandFailed(let message):
            return message
        }
    }
}

@MainActor
final class BridgeControlService {
    static let shared = BridgeControlService()

    private let fileManager = FileManager.default
    private var snapshotRead: Task<BridgeDiskState, Never>?
    private var snapshotReadID: UUID?
    private let logQueue = DispatchQueue(label: "remodex.app.diagnostics", qos: .utility)
    private let logBudget = TransportBudget(bytes: 64, count: 64)
    private var diagnosticSequence: UInt64 = 0
    private var runtimeVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    private var bridgeProcess: Process?
    private var parentPipe: Pipe?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    private(set) var generation = UUID()
    private(set) var lastExitCode: Int32?
    private(set) var logFailure = false
    private var recentDiagnostics: [String] = []
    private let operations = BridgeOperationQueue()
    private var intent = UUID()
    private(set) var wantsRunning = false
    private var desiredRelay: String?
    private var recovery = BridgeRecoveryPolicy()
    private var recoveryTask: Task<Void, Never>?
    private var heartbeatStamp: String?
    private var heartbeatObservedAt = ProcessInfo.processInfo.systemUptime
    private var staleChecks = 0
    private var wakeGraceUntil: TimeInterval = 0
    private(set) var recoveryPhase = ""
    private let terminalErrors: Set<String> = ["activation_required", "activation_failed", "credential_invalid", "credential_revoked", "device_revoked", "access_revoked", "pairing_revoked", "invalid_device_proof", "update_required", "platform_not_supported", "invalid_relay_path", "relay_response_invalid", "connection_replaced"]

    private init() { record("app_opened") }

    // 只接受内部定义的事件码，不写入请求、凭据或未经脱敏的错误正文。
    func record(_ event: String, operation: UUID? = nil, exit: Int32? = nil, stage: String? = nil, code: String? = nil, requestID: UUID? = nil, httpStatus: Int? = nil, durationMs: Int? = nil) {
        func safe(_ value: String) -> String { value.range(of: "^[a-z][a-z0-9_]{0,79}$", options: .regularExpression) != nil ? value : "unknown" }
        let summary = [safe(event), stage.map(safe), code.map(safe), operation.map { "operation=\($0.uuidString)" }, requestID.map { "request=\($0.uuidString)" }, httpStatus.map { "http=\($0)" }].compactMap { $0 }.joined(separator: " ")
        recentDiagnostics.append(summary)
        recentDiagnostics = Array(recentDiagnostics.suffix(20))
        diagnosticSequence &+= 1
        let sequence = diagnosticSequence
        guard logBudget.acquire(1) else { logFailure = true; return }
        let directory = logsDirectory
        var row: [String: Any] = ["time": ISO8601DateFormatter().string(from: Date()), "event": safe(event), "generation": generation.uuidString,
                                  "version": runtimeVersion, "source": Bundle.main.object(forInfoDictionaryKey: "RemodexSourceSHA") as? String ?? "unknown"]
        if let operation { row["operation"] = operation.uuidString }
        if let exit { row["exit"] = exit }
        if let stage { row["stage"] = safe(stage) }
        if let code { row["code"] = safe(code) }
        if let requestID { row["requestID"] = requestID.uuidString }
        if let httpStatus { row["httpStatus"] = httpStatus }
        if let durationMs { row["durationMs"] = durationMs }
        let entry = row
        logQueue.async { [weak self, logBudget] in
            defer { logBudget.release(1) }
            let fileManager = FileManager.default
            let failed: Bool
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                let url = directory.appendingPathComponent("app.jsonl")
                if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 2_000_000 {
                    let previous = directory.appendingPathComponent("app.previous.jsonl")
                    if fileManager.fileExists(atPath: previous.path) { try fileManager.removeItem(at: previous) }
                    try fileManager.moveItem(at: url, to: previous)
                }
                if !fileManager.fileExists(atPath: url.path) { fileManager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
                var data = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]); data.append(10)
                let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
                try handle.seekToEnd(); try handle.write(contentsOf: data)
                failed = false
            } catch { failed = true }
            Task { @MainActor [weak self] in
                guard let self, self.diagnosticSequence == sequence else { return }
                self.logFailure = failed
            }
        }
    }

    var isRunning: Bool {
        bridgeProcess?.isRunning == true
    }

    func startBridge(relayOverride: String?) async throws {
        intent = UUID()
        let requested = intent
        wantsRunning = true
        desiredRelay = relayOverride
        recoveryTask?.cancel(); recoveryTask = nil
        recovery.reset()
        operations.cancel()
        try await operations.perform {
            guard self.intent == requested, self.wantsRunning else { throw CancellationError() }
            try await self.launchBridge(relayOverride: relayOverride)
        }
    }

    private func launchBridge(relayOverride: String?) async throws {
        guard !isRunning else { return }
        generation = UUID(); lastExitCode = nil
        heartbeatStamp = nil
        heartbeatObservedAt = ProcessInfo.processInfo.systemUptime
        staleChecks = 0
        record("preflight")
        let activationBootstrap: Data
        do {
            try validateBundledRuntime()
            activationBootstrap = try DeviceAccessService.shared.bootstrap(relay: relayOverride ?? "")
        } catch {
            wantsRunning = false
            recoveryPhase = "启动条件不满足，需要处理"
            throw error
        }
        guard let relay = relayOverride?.trimmingCharacters(in: .whitespacesAndNewlines), !relay.isEmpty else {
            wantsRunning = false
            throw BridgeRuntimeError.relayMissing
        }

        try fileManager.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        fileManager.createFile(atPath: stdoutLogURL.path, contents: nil)
        fileManager.createFile(atPath: stderrLogURL.path, contents: nil)
        let stdout = try FileHandle(forWritingTo: stdoutLogURL)
        let stderr = try FileHandle(forWritingTo: stderrLogURL)
        try stdout.seekToEnd()
        try stderr.seekToEnd()

        let parentPipe = Pipe()
        let process = Process()
        process.executableURL = nodeURL
        process.arguments = [helperURL.path, "run"]
        process.currentDirectoryURL = bridgeRootURL
        process.environment = ProcessInfo.processInfo.environment.merging([
            "REMODEX_RELAY": relay,
            "REMODEX_DEVICE_STATE_DIR": stateDirectory.path,
            "REMODEX_OWNER_GENERATION": generation.uuidString,
            "REMODEX_KEEP_MAC_AWAKE": "0",
            "REMODEX_DESKTOP_IPC_LIVE_SYNC": "1",
            "REMODEX_DESKTOP_AUTO_FOLLOW": "1",
        ]) { _, appValue in appValue }
        process.standardInput = parentPipe
        process.standardOutput = stdout
        process.standardError = stderr
        let launchedGeneration = generation
        process.terminationHandler = { [weak self] terminated in
            Task { @MainActor in
                guard let self, self.generation == launchedGeneration else { return }
                self.lastExitCode = terminated.terminationStatus
                self.record("process_exited", exit: terminated.terminationStatus)
                self.finishTerminatedProcess()
            }
        }

        do {
            try process.run()
            bridgeProcess = process
            self.parentPipe = parentPipe
            stdoutHandle = stdout
            stderrHandle = stderr
            record("process_spawned")
            try parentPipe.fileHandleForWriting.write(contentsOf: activationBootstrap)
        } catch {
            try? parentPipe.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            record("process_start_failed")
            try? stdout.close()
            try? stderr.close()
            throw BridgeRuntimeError.commandFailed("Bridge 启动失败，请查看诊断中的启动阶段。")
        }

        bridgeProcess = process
        self.parentPipe = parentPipe
        stdoutHandle = stdout
        stderrHandle = stderr
    }

    func stopBridge() async {
        intent = UUID()
        let requested = intent
        wantsRunning = false
        recoveryPhase = ""
        recoveryTask?.cancel(); recoveryTask = nil
        operations.cancel()
        try? await operations.perform {
            guard self.intent == requested else { return }
            await self.terminateBridge()
        }
    }

    private func terminateBridge() async {
        guard let process = bridgeProcess else { return }
        let stoppingGeneration = generation
        try? parentPipe?.fileHandleForWriting.close()
        for _ in 0..<20 where process.isRunning {
            await Self.stopPause()
        }
        if process.isRunning {
            process.terminate()
        }
        for _ in 0..<10 where process.isRunning {
            await Self.stopPause()
        }
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
        for _ in 0..<20 where process.isRunning { await Self.stopPause() }
        guard !process.isRunning else {
            recoveryPhase = "停止未完成，进程仍存在"
            record("process_stop_failed")
            return
        }
        if generation == stoppingGeneration { finishTerminatedProcess() }
    }

    private static func stopPause() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { continuation.resume() }
        }
    }

    func restartBridge(relayOverride: String?) async throws {
        intent = UUID()
        let requested = intent
        wantsRunning = true
        desiredRelay = relayOverride
        recoveryTask?.cancel(); recoveryTask = nil
        operations.cancel()
        try await operations.perform {
            guard self.intent == requested else { throw CancellationError() }
            await self.terminateBridge()
            guard !self.isRunning else { throw BridgeRuntimeError.commandFailed("旧 Bridge 尚未退出，不会启动重复进程。") }
            guard self.intent == requested, self.wantsRunning else { throw CancellationError() }
            try await self.launchBridge(relayOverride: relayOverride)
        }
    }

    func refreshPairing(relayOverride: String?) async throws {
        let requested = intent
        try await operations.perform {
            guard self.intent == requested else { throw CancellationError() }
            try await self.refreshCurrentPairing(relayOverride: relayOverride)
        }
    }

    private func refreshCurrentPairing(relayOverride: String?) async throws {
        guard isRunning, let parentPipe else { throw BridgeRuntimeError.commandFailed("请先启动 Bridge。") }
        let old = await loadSnapshot(relayOverride: relayOverride).pairingSession?.qrText
        try Task.checkCancellation()
        let currentGeneration = generation
        try parentPipe.fileHandleForWriting.write(contentsOf: Data("{\"command\":\"refresh-pairing\"}\n".utf8))
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(200))
            guard generation == currentGeneration, isRunning else { throw BridgeRuntimeError.commandFailed("Bridge 已停止，未刷新配对码。") }
            if let next = await loadSnapshot(relayOverride: relayOverride).pairingSession?.qrText, next != old { return }
        }
        throw BridgeRuntimeError.commandFailed("刷新配对邀请失败，请检查 Relay 连接后重试。旧邀请不会被延长。")
    }

    func resetPairing(relayOverride: String?) async throws {
        intent = UUID()
        let requested = intent
        recoveryTask?.cancel(); recoveryTask = nil
        operations.cancel()
        try await operations.perform {
            guard self.intent == requested else { throw CancellationError() }
            await self.terminateBridge()
            guard !self.isRunning else { throw BridgeRuntimeError.commandFailed("旧 Bridge 尚未退出，不能重置配对。") }
            do { try await self.runControlCommand("reset-pairing") }
            catch { if self.intent == requested { self.wantsRunning = false }; throw error }
            guard self.intent == requested else { throw CancellationError() }
            self.wantsRunning = true
            self.desiredRelay = relayOverride
            try await self.launchBridge(relayOverride: relayOverride)
        }
    }

    func resumeLastThread() async throws {
        try await operations.perform { try await self.runControlCommand("resume") }
    }

    func didWake() {
        wakeGraceUntil = ProcessInfo.processInfo.systemUptime + 30
        heartbeatObservedAt = ProcessInfo.processInfo.systemUptime
        staleChecks = 0
    }

    func recoverIfNeeded(snapshot: BridgeSnapshot?) {
        guard wantsRunning, !operations.isBusy, recoveryTask == nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let code = snapshot?.bridgeStatus?.lastError, terminalErrors.contains(code) || snapshot?.bridgeStatus?.state == "blocked" {
            wantsRunning = false
            recoveryPhase = "需要处理：\(code)"
            record("recovery_blocked", code: code)
            return
        }
        if isRunning {
            let stamp = snapshot?.bridgeStatus?.updatedAt
            if let stamp, stamp != heartbeatStamp {
                heartbeatStamp = stamp
                heartbeatObservedAt = now
                staleChecks = 0
                recovery.observeHealthy(at: now)
                recoveryPhase = ""
                return
            }
            guard now >= wakeGraceUntil, now - heartbeatObservedAt > 60 else { return }
            staleChecks += 1
            guard staleChecks >= 2 else { return }
        }
        let requested = intent
        let delay = recovery.delay(now: now, jitter: Double.random(in: 0...1))
        recoveryPhase = delay >= 300 ? "恢复冷却中" : "正在恢复"
        recoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.intent == requested { self.recoveryTask = nil } }
            do {
                try await Task.sleep(for: .seconds(delay))
                guard self.intent == requested, self.wantsRunning else { return }
                try await self.operations.perform {
                    guard self.intent == requested, self.wantsRunning else { throw CancellationError() }
                    self.recovery.recordAttempt(at: ProcessInfo.processInfo.systemUptime)
                    await self.terminateBridge()
                    guard !self.isRunning else { throw BridgeRuntimeError.commandFailed("旧 Bridge 尚未退出，恢复已延后。") }
                    guard self.intent == requested, self.wantsRunning else { throw CancellationError() }
                    try await self.launchBridge(relayOverride: self.desiredRelay)
                    self.record("recovery_started")
                }
            } catch is CancellationError { }
            catch {
                self.record("recovery_failed")
                if case BridgeRuntimeError.runtimeMissing = error {
                    self.wantsRunning = false
                    self.recoveryPhase = "运行时缺失，需要更新应用"
                }
            }
        }
    }

    func stopSynchronously() {
        wantsRunning = false
        intent = UUID()
        recoveryTask?.cancel()
        operations.cancel()
        guard let process = bridgeProcess else { return }
        try? parentPipe?.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
        }
        if !process.isRunning { finishTerminatedProcess() }
    }

    func loadSnapshot(relayOverride: String?) async -> BridgeSnapshot {
        let observedGeneration = generation
        let task: Task<BridgeDiskState, Never>
        if let snapshotRead { task = snapshotRead }
        else {
            let state = stateDirectory, node = nodeURL, helper = helperURL, root = bridgeRootURL
            task = Task.detached(priority: .utility) { BridgeDiskState.read(state: state, node: node, helper: helper, root: root) }
            snapshotRead = task
            snapshotReadID = UUID()
        }
        let readID = snapshotReadID
        let disk = await task.value
        if snapshotReadID == readID { snapshotRead = nil; snapshotReadID = nil }
        if disk.version != "—" { runtimeVersion = disk.version }
        let effectiveConfig = disk.config ?? BridgeDaemonConfig(
            relayUrl: relayOverride,
            codexEndpoint: nil,
            refreshEnabled: nil
        )
        let currentStatus = observedGeneration == generation && isRunning && disk.status?.belongsTo(generation) == true ? disk.status : nil
        return BridgeSnapshot(
            currentVersion: disk.version,
            isRunning: isRunning,
            processID: bridgeProcess?.isRunning == true ? Int(bridgeProcess!.processIdentifier) : nil,
            runtimeAvailable: disk.runtimeError == nil,
            runtimeError: disk.runtimeError,
            daemonConfig: effectiveConfig,
            bridgeStatus: currentStatus,
            pairingSession: currentStatus == nil ? nil : disk.pairing,
            trustedDevice: disk.trusted,
            stdoutLogPath: stdoutLogURL.path,
            stderrLogPath: stderrLogURL.path
        )
    }

    func redactedDiagnostics(relayOverride: String?) async -> String {
        let snapshot = await loadSnapshot(relayOverride: relayOverride)
        return [
            "Remodex \(snapshot.currentVersion)",
            "Bridge: \(snapshot.isRunning ? "running" : "stopped")",
            "PID: \(snapshot.processID.map(String.init) ?? "none")",
            "Connection: \(snapshot.bridgeStatus?.connectionStatus ?? "unknown")",
            "Relay error: \(snapshot.bridgeStatus?.relayDiagnostic?.code ?? "none")",
            "Relay HTTP: \(snapshot.bridgeStatus?.relayDiagnostic?.status.map(String.init) ?? "none")",
            "Relay request: \(snapshot.bridgeStatus?.relayDiagnostic?.requestId ?? "none")",
            "Codex: \(snapshot.codexStatusLabel)",
            "Trusted phones: \(snapshot.trustedDevice?.trustedPhoneCount ?? 0)",
            "Last sync: \(snapshot.bridgeStatus?.updatedAt ?? "unknown")",
            "Last exit: \(lastExitCode.map(String.init) ?? "none")",
            "App log: \(logFailure ? "unavailable" : "available")",
            "Recent operations:\n\(recentDiagnostics.joined(separator: "\n"))",
        ].joined(separator: "\n")
    }

    private func runControlCommand(_ command: String) async throws {
        try validateBundledRuntime()
        let environment = ProcessInfo.processInfo.environment.merging([
            "REMODEX_DEVICE_STATE_DIR": stateDirectory.path,
        ]) { _, appValue in appValue }
        let runner = AsyncProcessRunner(executable: nodeURL, arguments: [helperURL.path, "control", command], directory: bridgeRootURL, environment: environment)
        try await runner.run(initialInput: Data("{}\n".utf8))
    }

    private func validateBundledRuntime() throws {
        guard fileManager.isExecutableFile(atPath: nodeURL.path) else {
            throw BridgeRuntimeError.runtimeMissing(nodeURL.path)
        }
        guard fileManager.fileExists(atPath: helperURL.path) else {
            throw BridgeRuntimeError.runtimeMissing(helperURL.path)
        }
        guard fileManager.fileExists(atPath: bridgeRootURL.appendingPathComponent("node_modules/ws/index.js").path)
                || fileManager.fileExists(atPath: bridgeRootURL.appendingPathComponent("node_modules/ws/package.json").path) else {
            throw BridgeRuntimeError.runtimeMissing(bridgeRootURL.appendingPathComponent("node_modules/ws").path)
        }
    }

    private func finishTerminatedProcess() {
        try? stdoutHandle?.close()
        try? stderrHandle?.close()
        stdoutHandle = nil
        stderrHandle = nil
        parentPipe = nil
        bridgeProcess = nil
    }

    private var runtimeRootURL: URL {
        (Bundle.main.resourceURL ?? Bundle.main.bundleURL).appendingPathComponent("RemodexRuntime", isDirectory: true)
    }

    private var nodeURL: URL {
        runtimeRootURL.appendingPathComponent("node/bin/node")
    }

    private var bridgeRootURL: URL {
        runtimeRootURL.appendingPathComponent("bridge", isDirectory: true)
    }

    private var helperURL: URL {
        bridgeRootURL.appendingPathComponent("bin/remodex-app-helper.js")
    }

    private var stateDirectory: URL {
        fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".remodex", isDirectory: true)
    }

    private var logsDirectory: URL {
        stateDirectory.appendingPathComponent("logs", isDirectory: true)
    }

    private var stdoutLogURL: URL {
        logsDirectory.appendingPathComponent("bridge.stdout.log")
    }

    private var stderrLogURL: URL {
        logsDirectory.appendingPathComponent("bridge.stderr.log")
    }
}

private struct BridgeDiskState {
    let version: String
    let runtimeError: String?
    let config: BridgeDaemonConfig?
    let status: BridgeRuntimeStatus?
    let pairing: BridgePairingSession?
    let trusted: BridgeTrustedDeviceSummary?

    static func read(state: URL, node: URL, helper: URL, root: URL) -> BridgeDiskState {
        func read<Value: Decodable>(_ filename: String) -> Value? {
            guard let handle = try? FileHandle(forReadingFrom: state.appendingPathComponent(filename)) else { return nil }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: 1_048_577), data.count <= 1_048_576 else { return nil }
            return try? JSONDecoder().decode(Value.self, from: data)
        }
        func fingerprint(_ value: String?) -> String? {
            guard let value, !value.isEmpty else { return nil }
            return SHA256.hash(data: Data(value.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        }
        let manager = FileManager.default
        var missing: String?
        if !manager.isExecutableFile(atPath: node.path) { missing = node.path }
        else if !manager.fileExists(atPath: helper.path) { missing = helper.path }
        else if !manager.fileExists(atPath: root.appendingPathComponent("node_modules/ws/index.js").path)
            && !manager.fileExists(atPath: root.appendingPathComponent("node_modules/ws/package.json").path) { missing = "node_modules/ws" }
        let package = (try? Data(contentsOf: root.appendingPathComponent("package.json"))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let device: BridgeDeviceStateFile? = read("device-state.json")
        let trusted = device.map { value in
            BridgeTrustedDeviceSummary(macDeviceFingerprint: fingerprint(value.macDeviceId), trustedPhoneCount: value.trustedPhones?.count ?? 0,
                                       trustedPhoneFingerprint: fingerprint(value.trustedPhones?.keys.sorted().first), lastSeenDeviceKind: value.lastSeenDeviceKind,
                                       lastSeenPhoneAppVersion: value.lastSeenPhoneAppVersion)
        }
        return BridgeDiskState(version: package?["version"] as? String ?? "—", runtimeError: missing.map { "App 内置 Bridge runtime 不完整：\($0)" },
                               config: read("daemon-config.json"), status: read("bridge-status.json"), pairing: read("pairing-session.json"), trusted: trusted)
    }
}
