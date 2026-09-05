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
    private let decoder = JSONDecoder()
    private var bridgeProcess: Process?
    private var parentPipe: Pipe?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    private(set) var generation = UUID()
    private(set) var lastExitCode: Int32?
    private(set) var logFailure = false
    private var recentDiagnostics: [String] = []

    private init() { record("app_opened") }

    // 只接受内部定义的事件码，不写入请求、凭据或未经脱敏的错误正文。
    func record(_ event: String, operation: UUID? = nil, exit: Int32? = nil, stage: String? = nil, code: String? = nil, requestID: UUID? = nil, httpStatus: Int? = nil, durationMs: Int? = nil) {
        func safe(_ value: String) -> String { value.range(of: "^[a-z][a-z0-9_]{0,79}$", options: .regularExpression) != nil ? value : "unknown" }
        let summary = [safe(event), stage.map(safe), code.map(safe), operation.map { "operation=\($0.uuidString)" }, requestID.map { "request=\($0.uuidString)" }, httpStatus.map { "http=\($0)" }].compactMap { $0 }.joined(separator: " ")
        recentDiagnostics.append(summary)
        recentDiagnostics = Array(recentDiagnostics.suffix(20))
        do {
            try fileManager.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
            let url = logsDirectory.appendingPathComponent("app.jsonl")
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 2_000_000 {
                let previous = logsDirectory.appendingPathComponent("app.previous.jsonl")
                if fileManager.fileExists(atPath: previous.path) { try fileManager.removeItem(at: previous) }
                try fileManager.moveItem(at: url, to: previous)
            }
            if !fileManager.fileExists(atPath: url.path) { fileManager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
            var row: [String: Any] = ["time": ISO8601DateFormatter().string(from: Date()), "event": safe(event), "generation": generation.uuidString,
                                      "version": bundledVersion, "source": Bundle.main.object(forInfoDictionaryKey: "RemodexSourceSHA") as? String ?? "unknown"]
            if let operation { row["operation"] = operation.uuidString }
            if let exit { row["exit"] = exit }
            if let stage { row["stage"] = safe(stage) }
            if let code { row["code"] = safe(code) }
            if let requestID { row["requestID"] = requestID.uuidString }
            if let httpStatus { row["httpStatus"] = httpStatus }
            if let durationMs { row["durationMs"] = durationMs }
            var data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]); data.append(10)
            let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
            try handle.seekToEnd(); try handle.write(contentsOf: data)
            logFailure = false
        } catch { logFailure = true }
    }

    var isRunning: Bool {
        bridgeProcess?.isRunning == true
    }

    func detectRuntimeAvailability() -> Result<String, Error> {
        do {
            try validateBundledRuntime()
            return .success(bundledVersion)
        } catch {
            return .failure(error)
        }
    }

    func startBridge(relayOverride: String?) async throws {
        guard !isRunning else { return }
        generation = UUID(); lastExitCode = nil
        record("preflight")
        try validateBundledRuntime()
        let activationBootstrap = try DeviceAccessService.shared.bootstrap(relay: relayOverride ?? "")
        guard let relay = relayOverride?.trimmingCharacters(in: .whitespacesAndNewlines), !relay.isEmpty else {
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
        guard let process = bridgeProcess else { return }
        let stoppingGeneration = generation
        try? parentPipe?.fileHandleForWriting.close()
        for _ in 0..<20 where process.isRunning {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if process.isRunning {
            process.terminate()
        }
        for _ in 0..<10 where process.isRunning {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
        if generation == stoppingGeneration { finishTerminatedProcess() }
    }

    func restartBridge(relayOverride: String?) async throws {
        await stopBridge()
        try await startBridge(relayOverride: relayOverride)
    }

    func refreshPairing(relayOverride: String?) async throws {
        guard isRunning, let parentPipe else { throw BridgeRuntimeError.commandFailed("请先启动 Bridge。") }
        let old = loadSnapshot(relayOverride: relayOverride).pairingSession?.qrText
        let currentGeneration = generation
        try parentPipe.fileHandleForWriting.write(contentsOf: Data("{\"command\":\"refresh-pairing\"}\n".utf8))
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(200))
            guard generation == currentGeneration, isRunning else { throw BridgeRuntimeError.commandFailed("Bridge 已停止，未刷新配对码。") }
            if let next = loadSnapshot(relayOverride: relayOverride).pairingSession?.qrText, next != old { return }
        }
        throw BridgeRuntimeError.commandFailed("刷新配对邀请失败，请检查 Relay 连接后重试。旧邀请不会被延长。")
    }

    func resetPairing(relayOverride: String?) async throws {
        await stopBridge()
        try await runControlCommand("reset-pairing")
        try await startBridge(relayOverride: relayOverride)
    }

    func resumeLastThread() async throws {
        try await runControlCommand("resume")
    }

    func stopSynchronously() {
        guard let process = bridgeProcess else { return }
        try? parentPipe?.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
        }
        finishTerminatedProcess()
    }

    func loadSnapshot(relayOverride: String?) -> BridgeSnapshot {
        let runtime = detectRuntimeAvailability()
        let runtimeError: String?
        let version: String
        switch runtime {
        case .success(let value):
            version = value
            runtimeError = nil
        case .failure(let error):
            version = "—"
            runtimeError = error.localizedDescription
        }

        let persistedConfig: BridgeDaemonConfig? = readStateFile(named: "daemon-config.json")
        let effectiveConfig = persistedConfig ?? BridgeDaemonConfig(
            relayUrl: relayOverride,
            codexEndpoint: nil,
            refreshEnabled: nil
        )
        let status: BridgeRuntimeStatus? = readStateFile(named: "bridge-status.json")
        let currentStatus = isRunning && status?.belongsTo(generation) == true ? status : nil
        return BridgeSnapshot(
            currentVersion: version,
            isRunning: isRunning,
            processID: bridgeProcess?.isRunning == true ? Int(bridgeProcess!.processIdentifier) : nil,
            runtimeAvailable: runtimeError == nil,
            runtimeError: runtimeError,
            daemonConfig: effectiveConfig,
            bridgeStatus: currentStatus,
            pairingSession: currentStatus == nil ? nil : readStateFile(named: "pairing-session.json"),
            trustedDevice: readTrustedDeviceSummary(),
            stdoutLogPath: stdoutLogURL.path,
            stderrLogPath: stderrLogURL.path
        )
    }

    func redactedDiagnostics(relayOverride: String?) -> String {
        let snapshot = loadSnapshot(relayOverride: relayOverride)
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
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = nodeURL
        process.arguments = [helperURL.path, command]
        process.currentDirectoryURL = bridgeRootURL
        process.environment = ProcessInfo.processInfo.environment.merging([
            "REMODEX_DEVICE_STATE_DIR": stateDirectory.path,
        ]) { _, appValue in appValue }
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw BridgeRuntimeError.commandFailed(message?.isEmpty == false ? message! : "Bridge helper 执行失败。")
        }
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

    private func readStateFile<Value: Decodable>(named filename: String) -> Value? {
        let url = stateDirectory.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(Value.self, from: data)
    }

    private func readTrustedDeviceSummary() -> BridgeTrustedDeviceSummary? {
        guard let state: BridgeDeviceStateFile = readStateFile(named: "device-state.json") else {
            return nil
        }
        let trustedPhones = state.trustedPhones ?? [:]
        return BridgeTrustedDeviceSummary(
            macDeviceFingerprint: shortFingerprint(state.macDeviceId),
            trustedPhoneCount: trustedPhones.count,
            trustedPhoneFingerprint: shortFingerprint(trustedPhones.keys.sorted().first),
            lastSeenDeviceKind: state.lastSeenDeviceKind,
            lastSeenPhoneAppVersion: state.lastSeenPhoneAppVersion
        )
    }

    private func shortFingerprint(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return SHA256.hash(data: Data(value.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    private var bundledVersion: String {
        guard let data = try? Data(contentsOf: bridgeRootURL.appendingPathComponent("package.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["version"] as? String else {
            return Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        }
        return version
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
