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

    private init() {}

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
            "REMODEX_KEEP_MAC_AWAKE": "0",
            "REMODEX_DESKTOP_IPC_LIVE_SYNC": "1",
            "REMODEX_DESKTOP_AUTO_FOLLOW": "1",
        ]) { _, appValue in appValue }
        process.standardInput = parentPipe
        process.standardOutput = stdout
        process.standardError = stderr
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.finishTerminatedProcess()
            }
        }

        do {
            try process.run()
            try parentPipe.fileHandleForWriting.write(contentsOf: activationBootstrap)
        } catch {
            try? stdout.close()
            try? stderr.close()
            throw error
        }

        _ = Darwin.setpgid(process.processIdentifier, process.processIdentifier)
        bridgeProcess = process
        self.parentPipe = parentPipe
        stdoutHandle = stdout
        stderrHandle = stderr
    }

    func stopBridge() async {
        guard let process = bridgeProcess else { return }
        try? parentPipe?.fileHandleForWriting.close()
        for _ in 0..<20 where process.isRunning {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if process.isRunning {
            Darwin.kill(-process.processIdentifier, SIGTERM)
        }
        for _ in 0..<10 where process.isRunning {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if process.isRunning {
            Darwin.kill(-process.processIdentifier, SIGKILL)
        }
        finishTerminatedProcess()
    }

    func restartBridge(relayOverride: String?) async throws {
        await stopBridge()
        try await startBridge(relayOverride: relayOverride)
    }

    func refreshPairing(relayOverride: String?) async throws {
        try await restartBridge(relayOverride: relayOverride)
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
            Darwin.kill(-process.processIdentifier, SIGTERM)
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
        return BridgeSnapshot(
            currentVersion: version,
            isRunning: isRunning,
            processID: bridgeProcess?.isRunning == true ? Int(bridgeProcess!.processIdentifier) : nil,
            runtimeAvailable: runtimeError == nil,
            runtimeError: runtimeError,
            daemonConfig: effectiveConfig,
            bridgeStatus: readStateFile(named: "bridge-status.json"),
            pairingSession: readStateFile(named: "pairing-session.json"),
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
            "Relay: \(snapshot.effectiveRelayURL)",
            "Connection: \(snapshot.bridgeStatus?.connectionStatus ?? "unknown")",
            "Codex: \(snapshot.codexStatusLabel)",
            "Trusted phones: \(snapshot.trustedDevice?.trustedPhoneCount ?? 0)",
            "Last sync: \(snapshot.bridgeStatus?.updatedAt ?? "unknown")",
            "Last error: \(snapshot.lastErrorMessage)",
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
