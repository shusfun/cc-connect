// FILE: BridgeControlModels.swift
// Purpose: Defines App-owned bridge runtime, pairing, device, Relay, and Codex status snapshots.
// Layer: Companion app model
// Exports: BridgeSnapshot and bridge status payloads
// Depends on: Foundation

import Foundation

struct BridgeSnapshot: Equatable {
    let currentVersion: String
    let isRunning: Bool
    let processID: Int?
    let runtimeAvailable: Bool
    let runtimeError: String?
    let daemonConfig: BridgeDaemonConfig?
    let bridgeStatus: BridgeRuntimeStatus?
    let pairingSession: BridgePairingSession?
    let trustedDevice: BridgeTrustedDeviceSummary?
    let stdoutLogPath: String
    let stderrLogPath: String

    var effectiveRelayURL: String {
        daemonConfig?.relayUrl?.nonEmptyTrimmed
            ?? pairingSession?.pairingPayload?.relay.nonEmptyTrimmed
            ?? ""
    }

    var statusHeadline: String {
        if !runtimeAvailable { return "Runtime Missing" }
        if let value = bridgeStatus?.connectionStatus?.nonEmptyTrimmed {
            return value.capitalized
        }
        return isRunning ? "Running" : "Stopped"
    }

    var statusFootnote: String {
        guard let date = bridgeStatus?.updatedDate else {
            return isRunning ? "App-owned process" : "Not running"
        }
        return Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    var codexStatusLabel: String {
        bridgeStatus?.codexLaunchState?.nonEmptyTrimmed?.capitalized ?? (isRunning ? "Starting" : "Stopped")
    }

    var connectionCount: Int {
        (bridgeStatus?.activeDevice ?? bridgeStatus?.activePhone)?.connected == true ? 1 : 0
    }

    var trustedPhoneStatusLabel: String {
        if let active = bridgeStatus?.activeDevice ?? bridgeStatus?.activePhone, active.connected {
            return active.phoneFingerprint?.nonEmptyTrimmed.map { "已连接 iPhone · \($0)" } ?? "已连接 iPhone"
        }
        guard let trustedDevice else { return "未配对" }
        return trustedDevice.trustedPhoneCount > 0
            ? "已信任 \(trustedDevice.trustedPhoneCount) 台手机"
            : "未配对"
    }

    var lastErrorMessage: String {
        bridgeStatus?.lastError?.nonEmptyTrimmed ?? runtimeError?.nonEmptyTrimmed ?? ""
    }

    var stateDirectoryPath: String {
        URL(fileURLWithPath: stderrLogPath).deletingLastPathComponent().deletingLastPathComponent().path
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()
}

struct BridgeDaemonConfig: Codable, Equatable {
    let relayUrl: String?
    let codexEndpoint: String?
    let refreshEnabled: Bool?
}

struct BridgeRuntimeStatus: Codable, Equatable {
    let state: String?
    let connectionStatus: String?
    let pid: Int?
    let lastError: String?
    let updatedAt: String?
    let codexLaunchState: String?
    let activeDevice: BridgeActivePhoneSummary?
    let activePhone: BridgeActivePhoneSummary?

    var updatedDate: Date? {
        updatedAt.flatMap(bridgeISO8601Formatter.date)
    }
}

struct BridgePairingSession: Codable, Equatable {
    let createdAt: String?
    let pairingPayload: BridgePairingPayload?
    let pairingCode: String?

    var createdDate: Date? {
        createdAt.flatMap(bridgeISO8601Formatter.date)
    }
}

struct BridgePairingPayload: Codable, Equatable {
    let v: Int
    let relay: String
    let sessionId: String
    let macDeviceId: String
    let macIdentityPublicKey: String
    let expiresAt: Int64

    var expiryDate: Date {
        Date(timeIntervalSince1970: TimeInterval(expiresAt) / 1_000)
    }
}

struct BridgeTrustedDeviceSummary: Equatable {
    let macDeviceFingerprint: String?
    let trustedPhoneCount: Int
    let trustedPhoneFingerprint: String?
    let lastSeenDeviceKind: String?
    let lastSeenPhoneAppVersion: String?
}

struct BridgeActivePhoneSummary: Codable, Equatable {
    let connected: Bool
    let phoneFingerprint: String?
    let deviceKind: String?
    let handshakeMode: String?
    let keyEpoch: Int?
    let updatedAt: String?
}

struct BridgeDeviceStateFile: Decodable {
    let macDeviceId: String?
    let trustedPhones: [String: String]?
    let lastSeenDeviceKind: String?
    let lastSeenPhoneAppVersion: String?
}

private let bridgeISO8601Formatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

extension String {
    var nonEmptyTrimmed: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            return nil
        }
        return value
    }
}
