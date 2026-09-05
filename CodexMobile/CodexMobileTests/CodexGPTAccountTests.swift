// FILE: CodexGPTAccountTests.swift
// Purpose: Verifies bridge-owned ChatGPT account state, login notifications, and local voice validation.
// Layer: Unit Test
// Exports: CodexGPTAccountTests
// Depends on: XCTest, CodexMobile

import Foundation
import XCTest
@testable import CodexMobile

@MainActor
final class CodexGPTAccountTests: XCTestCase {
    private static var retainedServices: [CodexService] = []

    func testKnownWindowsBridgeDoesNotUseLegacyMacDisplayWakeFallback() {
        let service = makeService()
        let macDeviceID = "host-\(UUID().uuidString)"

        service.lastTrustedMacDeviceId = macDeviceID
        service.trustedMacRegistry.records[macDeviceID] = CodexTrustedMacRecord(
            macDeviceId: macDeviceID,
            macIdentityPublicKey: Data(repeating: 7, count: 32).base64EncodedString(),
            lastPairedAt: Date()
        )
        service.gptAccountSnapshot.hostPlatform = .windows
        service.gptAccountSnapshot.hostCapabilities = nil

        XCTAssertEqual(service.bridgeHostPlatform, .windows)
        XCTAssertFalse(service.supportsDisplayWake)
        XCTAssertFalse(service.supportsDesktopAppHandoff)
    }

    func testKnownMacBridgeKeepsLegacyDisplayWakeFallback() {
        let service = makeService()
        let macDeviceID = "mac-\(UUID().uuidString)"

        service.lastTrustedMacDeviceId = macDeviceID
        service.trustedMacRegistry.records[macDeviceID] = CodexTrustedMacRecord(
            macDeviceId: macDeviceID,
            macIdentityPublicKey: Data(repeating: 8, count: 32).base64EncodedString(),
            lastPairedAt: Date()
        )
        service.gptAccountSnapshot.hostPlatform = .macOS
        service.gptAccountSnapshot.hostCapabilities = nil

        XCTAssertTrue(service.supportsDisplayWake)
        XCTAssertTrue(service.supportsDesktopAppHandoff)
    }

    func testRefreshGPTAccountStateDecodesSanitizedBridgeStatus() async {
        let service = makeService()
        service.isConnected = true

        service.requestTransportOverride = { method, params in
            XCTAssertEqual(method, "account/status/read")
            XCTAssertNil(params)
            return RPCMessage(
                id: .string(UUID().uuidString),
                    result: .object([
                        "status": .string("authenticated"),
                        "authMethod": .string("chatgpt"),
                        "email": .string("user@example.com"),
                        "planType": .string("plus"),
                        "loginInFlight": .bool(false),
                        "needsReauth": .bool(false),
                        "tokenReady": .bool(true),
                    ]),
                    includeJSONRPC: false
                )
            }

        await service.refreshGPTAccountState()

        XCTAssertEqual(service.gptAccountSnapshot.status, .authenticated)
        XCTAssertEqual(service.gptAccountSnapshot.authMethod, .chatgpt)
        XCTAssertEqual(service.gptAccountSnapshot.email, "user@example.com")
        XCTAssertEqual(service.gptAccountSnapshot.planType, "plus")
        XCTAssertFalse(service.gptAccountSnapshot.loginInFlight)
        XCTAssertTrue(service.gptAccountSnapshot.isVoiceTokenReady)
        XCTAssertNil(service.gptAccountErrorMessage)
    }

    func testRefreshGPTAccountStateFallsBackToLegacyGetAuthStatusPayload() async {
        let service = makeService()
        service.isConnected = true
        var observedMethods: [String] = []

        service.requestTransportOverride = { method, params in
            observedMethods.append(method)

            switch method {
            case "account/status/read":
                XCTAssertNil(params)
                throw CodexServiceError.invalidInput("method not found")
            case "getAuthStatus":
                XCTAssertNil(params)
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "authMethod": .string("chatgptAuthTokens"),
                        "authToken": .string("legacy-token"),
                        "requiresOpenaiAuth": .bool(false),
                    ]),
                    includeJSONRPC: false
                )
            default:
                XCTFail("Unexpected method \(method)")
                throw CodexServiceError.disconnected
            }
        }

        await service.refreshGPTAccountState()

        XCTAssertEqual(observedMethods, ["account/status/read", "getAuthStatus"])
        XCTAssertEqual(service.gptAccountSnapshot.status, .authenticated)
        XCTAssertEqual(service.gptAccountSnapshot.authMethod, .chatgpt)
        XCTAssertTrue(service.gptAccountSnapshot.isVoiceTokenReady)
    }

    func testRefreshBridgeVersionStatePresentsOptionalBridgeUpdateWhenLatestIsNewer() async {
        let service = makeService()
        service.isConnected = true

        service.requestTransportOverride = { method, params in
            XCTAssertEqual(method, "account/status/read")
            XCTAssertNil(params)
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "status": .string("authenticated"),
                    "authMethod": .string("chatgpt"),
                    "loginInFlight": .bool(false),
                    "needsReauth": .bool(false),
                    "tokenReady": .bool(true),
                    "bridgeVersion": .string("3.2.0"),
                    "bridgeLatestVersion": .string("3.2.1"),
                ]),
                includeJSONRPC: false
            )
        }

        await service.refreshBridgeVersionState(allowAvailableBridgeUpdatePrompt: true)

        XCTAssertEqual(service.bridgeInstalledVersion, "3.2.0")
        XCTAssertEqual(service.latestBridgePackageVersion, "3.2.1")
        XCTAssertEqual(
            service.bridgeUpdatePrompt?.title,
            L10n.string("Mac 上有较新的 Remodex.app 可用")
        )
        XCTAssertNil(service.bridgeUpdatePrompt?.command)
        XCTAssertEqual(service.gptAccountSnapshot.status, .unknown)
    }

    func testRefreshBridgeVersionStateRequiresBridgeThreeTwoForAppThreeTwo() async {
        let service = makeService()
        service.isConnected = true

        service.requestTransportOverride = { method, params in
            XCTAssertEqual(method, "account/status/read")
            XCTAssertNil(params)
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "status": .string("authenticated"),
                    "authMethod": .string("chatgpt"),
                    "loginInFlight": .bool(false),
                    "needsReauth": .bool(false),
                    "tokenReady": .bool(true),
                    "bridgeVersion": .string("3.1.0"),
                    "bridgeLatestVersion": .string("3.1.0"),
                ]),
                includeJSONRPC: false
            )
        }

        await service.refreshBridgeVersionState()

        XCTAssertEqual(
            service.bridgeUpdatePrompt?.message,
            L10n.format("Mac 上的 Remodex.app 内置 Bridge 版本为 %@，iPhone 端要求 %@ 或更高版本。请更新 Mac App 后重新连接。", "3.1.0", "3.2.0")
        )
        XCTAssertNil(service.bridgeUpdatePrompt?.command)
    }

    func testRefreshBridgeVersionStateDoesNotPresentOptionalBridgeUpdateWithoutForegroundFlag() async {
        let service = makeService()
        service.isConnected = true

        service.requestTransportOverride = { method, params in
            XCTAssertEqual(method, "account/status/read")
            XCTAssertNil(params)
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "status": .string("authenticated"),
                    "authMethod": .string("chatgpt"),
                    "loginInFlight": .bool(false),
                    "needsReauth": .bool(false),
                    "tokenReady": .bool(true),
                    "bridgeVersion": .string("3.2.0"),
                    "bridgeLatestVersion": .string("3.2.1"),
                ]),
                includeJSONRPC: false
            )
        }

        await service.refreshBridgeVersionState()

        XCTAssertNil(service.bridgeUpdatePrompt)
    }

    func testRefreshBridgeVersionStateDoesNotRepeatOptionalBridgeUpdateForSameLatestVersion() async {
        let service = makeService()
        service.isConnected = true

        service.requestTransportOverride = { method, params in
            XCTAssertEqual(method, "account/status/read")
            XCTAssertNil(params)
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "status": .string("authenticated"),
                    "authMethod": .string("chatgpt"),
                    "loginInFlight": .bool(false),
                    "needsReauth": .bool(false),
                    "tokenReady": .bool(true),
                    "bridgeVersion": .string("3.2.0"),
                    "bridgeLatestVersion": .string("3.2.1"),
                ]),
                includeJSONRPC: false
            )
        }

        await service.refreshBridgeVersionState(allowAvailableBridgeUpdatePrompt: true)
        let firstPrompt = service.bridgeUpdatePrompt

        service.bridgeUpdatePrompt = nil
        await service.refreshBridgeVersionState(allowAvailableBridgeUpdatePrompt: true)

        XCTAssertNotNil(firstPrompt)
        XCTAssertNil(service.bridgeUpdatePrompt)
    }

    func testForegroundReturnRefreshesBridgeVersionAndPresentsOptionalUpdatePrompt() async {
        let service = makeService()
        service.isConnected = true
        service.isInitialized = true
        service.syncRealtimeEnabled = false
        service.isAppInForeground = false

        service.requestTransportOverride = { method, params in
            XCTAssertEqual(method, "account/status/read")
            XCTAssertNil(params)
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "status": .string("authenticated"),
                    "authMethod": .string("chatgpt"),
                    "loginInFlight": .bool(false),
                    "needsReauth": .bool(false),
                    "tokenReady": .bool(true),
                    "bridgeVersion": .string("3.2.0"),
                    "bridgeLatestVersion": .string("3.2.1"),
                ]),
                includeJSONRPC: false
            )
        }

        service.setForegroundState(true)
        await yieldMainActor(times: 3)

        XCTAssertEqual(service.bridgeInstalledVersion, "3.2.0")
        XCTAssertEqual(service.latestBridgePackageVersion, "3.2.1")
        XCTAssertEqual(
            service.bridgeUpdatePrompt?.title,
            L10n.string("Mac 上有较新的 Remodex.app 可用")
        )
    }

    func testStartOrResumeGPTLoginUsesChatGPTVariantAndCachesPendingURL() async throws {
        let service = makeService()
        service.isConnected = true
        var capturedParams: JSONValue?

        service.requestTransportOverride = { method, params in
            XCTAssertEqual(method, "account/login/start")
            capturedParams = params
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "type": .string("chatgpt"),
                    "loginId": .string("login-123"),
                    "authUrl": .string("https://example.com/login"),
                ]),
                includeJSONRPC: false
            )
        }

        let loginResult = try await service.startOrResumeGPTLogin()

        XCTAssertEqual(capturedParams?.objectValue?["type"]?.stringValue, "chatgpt")
        XCTAssertEqual(loginResult.loginId, "login-123")
        XCTAssertEqual(loginResult.authURL.absoluteString, "https://example.com/login")
        XCTAssertEqual(service.gptAccountSnapshot.status, .loginPending)
    }

    func testStartOrResumeGPTLoginOnMacOpensPendingBrowserOnBridge() async throws {
        let service = makeService()
        service.isConnected = true
        var observedMethods: [String] = []
        var capturedOpenParams: IncomingParamsObject?

        service.requestTransportOverride = { method, params in
            observedMethods.append(method)

            switch method {
            case "account/login/start":
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "type": .string("chatgpt"),
                        "loginId": .string("login-123"),
                        "authUrl": .string("https://example.com/login"),
                    ]),
                    includeJSONRPC: false
                )
            case "account/login/openOnMac":
                capturedOpenParams = params?.objectValue
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "success": .bool(true),
                        "openedOnMac": .bool(true),
                    ]),
                    includeJSONRPC: false
                )
            default:
                XCTFail("Unexpected method \(method)")
                throw CodexServiceError.disconnected
            }
        }

        try await service.startOrResumeGPTLoginOnMac()

        XCTAssertEqual(observedMethods, ["account/login/start", "account/login/openOnMac"])
        XCTAssertEqual(capturedOpenParams?["authUrl"]?.stringValue, "https://example.com/login")
        XCTAssertEqual(service.gptAccountSnapshot.status, .loginPending)
    }

    func testStartOrResumeGPTLoginOnPhoneReturnsAuthURLWithoutMacOpenRequest() async throws {
        let service = makeService()
        service.isConnected = true
        var observedMethods: [String] = []

        service.requestTransportOverride = { method, params in
            observedMethods.append(method)

            switch method {
            case "account/login/start":
                XCTAssertEqual(params?.objectValue?["type"]?.stringValue, "chatgpt")
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "type": .string("chatgpt"),
                        "loginId": .string("login-123"),
                        "authUrl": .string("https://example.com/login"),
                    ]),
                    includeJSONRPC: false
                )
            default:
                XCTFail("Unexpected method \(method)")
                throw CodexServiceError.disconnected
            }
        }

        let authURL = try await service.startOrResumeGPTLoginOnPhone()

        XCTAssertEqual(observedMethods, ["account/login/start"])
        XCTAssertEqual(authURL.absoluteString, "https://example.com/login")
        XCTAssertEqual(service.gptAccountSnapshot.status, .loginPending)
    }

    func testLoginCompletedNotificationRefreshesAuthenticatedSnapshot() async throws {
        let service = makeService()
        service.isConnected = true
        var observedMethods: [String] = []

        service.requestTransportOverride = { method, params in
            observedMethods.append(method)

            switch method {
            case "account/login/start":
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "type": .string("chatgpt"),
                        "loginId": .string("login-123"),
                        "authUrl": .string("https://example.com/login"),
                    ]),
                    includeJSONRPC: false
                )
            case "account/status/read":
                XCTAssertNil(params)
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "status": .string("authenticated"),
                        "authMethod": .string("chatgpt"),
                        "email": .string("signedin@example.com"),
                        "planType": .string("plus"),
                        "loginInFlight": .bool(false),
                        "needsReauth": .bool(false),
                        "tokenReady": .bool(true),
                    ]),
                    includeJSONRPC: false
                )
            default:
                XCTFail("Unexpected method \(method)")
                throw CodexServiceError.disconnected
            }
        }

        _ = try await service.startOrResumeGPTLogin()
        service.handleIncomingRPCMessage(
            RPCMessage(
                method: "account/login/completed",
                params: .object([
                    "loginId": .string("login-123"),
                    "success": .bool(true),
                    "error": .null,
                ])
            )
        )

        await yieldMainActor(times: 3)

        XCTAssertEqual(service.gptAccountSnapshot.status, .authenticated)
        XCTAssertEqual(service.gptAccountSnapshot.email, "signedin@example.com")
        XCTAssertTrue(observedMethods.contains("account/status/read"))
    }

    func testAuthenticatedSnapshotWithoutTokenReadyKeepsVoiceDisabled() async {
        let service = makeService()
        service.isConnected = true

        service.requestTransportOverride = { method, params in
            XCTAssertEqual(method, "account/status/read")
            XCTAssertNil(params)
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "status": .string("authenticated"),
                    "authMethod": .string("chatgpt"),
                    "email": .string("user@example.com"),
                    "loginInFlight": .bool(false),
                    "needsReauth": .bool(false),
                    "tokenReady": .bool(false),
                ]),
                includeJSONRPC: false
            )
        }

        await service.refreshGPTAccountState()

        XCTAssertEqual(service.gptAccountSnapshot.status, .authenticated)
        XCTAssertFalse(service.gptAccountSnapshot.isVoiceTokenReady)
    }

    func testRefreshGPTAccountStateClearsStalePendingLoginWhenBridgeIsAuthenticated() async throws {
        let service = makeService()
        service.isConnected = true

        service.requestTransportOverride = { method, params in
            switch method {
            case "account/login/start":
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "type": .string("chatgpt"),
                        "loginId": .string("login-123"),
                        "authUrl": .string("https://example.com/login"),
                    ]),
                    includeJSONRPC: false
                )
            case "account/status/read":
                XCTAssertNil(params)
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "status": .string("authenticated"),
                        "authMethod": .string("chatgpt"),
                        "email": .string("signedin@example.com"),
                        "loginInFlight": .bool(false),
                        "needsReauth": .bool(false),
                        "tokenReady": .bool(true),
                    ]),
                    includeJSONRPC: false
                )
            default:
                XCTFail("Unexpected method \(method)")
                throw CodexServiceError.disconnected
            }
        }

        _ = try await service.startOrResumeGPTLogin()
        XCTAssertNotNil(service.currentPendingGPTLogin())

        await service.refreshGPTAccountState()

        XCTAssertEqual(service.gptAccountSnapshot.status, .authenticated)
        XCTAssertFalse(service.gptAccountSnapshot.loginInFlight)
        XCTAssertNil(service.currentPendingGPTLogin())
    }

    func testAuthenticatedSnapshotWithoutTokenReadyEventuallyNeedsReauth() {
        let service = makeService()
        service.gptAccountSnapshot = CodexGPTAccountSnapshot(
            status: .authenticated,
            authMethod: .chatgpt,
            email: "user@example.com",
            displayName: nil,
            planType: nil,
            loginInFlight: false,
            needsReauth: false,
            expiresAt: nil,
            tokenReady: false,
            tokenUnavailableSince: Date().addingTimeInterval(-90),
            updatedAt: .now
        )

        let snapshot = service.decodeBridgeGPTAccountSnapshot(from: [
            "status": .string("authenticated"),
            "authMethod": .string("chatgpt"),
            "email": .string("user@example.com"),
            "loginInFlight": .bool(false),
            "needsReauth": .bool(false),
            "tokenReady": .bool(false),
        ])

        XCTAssertEqual(snapshot.status, .authenticated)
        XCTAssertTrue(snapshot.needsReauth)
        XCTAssertFalse(snapshot.isVoiceTokenReady)
        XCTAssertTrue(snapshot.canLogout)
    }

    func testHandleGPTLoginCallbackCompletesPendingLoginThroughBridge() async throws {
        let service = makeService()
        service.isConnected = true
        var observedMethods: [String] = []
        var capturedCompleteParams: IncomingParamsObject?

        service.requestTransportOverride = { method, params in
            observedMethods.append(method)

            switch method {
            case "account/login/start":
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "type": .string("chatgpt"),
                        "loginId": .string("login-123"),
                        "authUrl": .string("https://example.com/login"),
                    ]),
                    includeJSONRPC: false
                )
            case "account/login/complete":
                capturedCompleteParams = params?.objectValue
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "ok": .bool(true),
                    ]),
                    includeJSONRPC: false
                )
            default:
                XCTFail("Unexpected method \(method)")
                throw CodexServiceError.disconnected
            }
        }

        _ = try await service.startOrResumeGPTLogin()
        await service.handleGPTLoginCallbackURL(URL(string: "phodex://auth/gpt/callback?code=abc")!)

        XCTAssertTrue(observedMethods.contains("account/login/complete"))
        XCTAssertEqual(capturedCompleteParams?["loginId"]?.stringValue, "login-123")
        XCTAssertEqual(
            capturedCompleteParams?["callbackUrl"]?.stringValue,
            "phodex://auth/gpt/callback?code=abc"
        )
    }

    func testPersistedGPTAccountSnapshotRestoresOnInit() throws {
        let defaults = makeDefaults()
        let encoder = JSONEncoder()
        let snapshot = CodexGPTAccountSnapshot(
            status: .authenticated,
            authMethod: .chatgpt,
            email: "persisted@example.com",
            displayName: nil,
            planType: "plus",
            loginInFlight: false,
            needsReauth: false,
            expiresAt: Date(timeIntervalSince1970: 1_742_000_000),
            updatedAt: .now
        )
        defaults.set(try encoder.encode(snapshot), forKey: "codex.gpt.accountSnapshot")

        let service = CodexService(defaults: defaults)

        XCTAssertEqual(service.gptAccountSnapshot.status, .authenticated)
        XCTAssertEqual(service.gptAccountSnapshot.email, "persisted@example.com")
        XCTAssertEqual(service.gptAccountSnapshot.planType, "plus")
    }

    func testVoiceTranscriptionPreflightRejectsOversizedClips() {
        let preflight = CodexVoiceTranscriptionPreflight(
            byteCount: CodexVoiceTranscriptionPreflight.maxByteCount + 1,
            durationSeconds: 30
        )

        XCTAssertThrowsError(try preflight.validate()) { error in
            XCTAssertEqual(error.localizedDescription, L10n.string("语音录音不能超过 10 MB。"))
        }
    }

    func testVoiceTranscriptionPreflightRejectsClipsLongerThan150Seconds() {
        let preflight = CodexVoiceTranscriptionPreflight(
            byteCount: 2_048,
            durationSeconds: 150.5
        )

        XCTAssertThrowsError(try preflight.validate()) { error in
            XCTAssertEqual(error.localizedDescription, L10n.format("语音录音不能超过 %@ 秒。", "150"))
        }
    }

    func testVoiceTranscriptionPreflightRejectsEmptyDuration() {
        let preflight = CodexVoiceTranscriptionPreflight(
            byteCount: 2_048,
            durationSeconds: 0
        )

        XCTAssertThrowsError(try preflight.validate()) { error in
            XCTAssertEqual(error.localizedDescription, L10n.string("语音录音中没有可识别的音频。"))
        }
    }

    func testVoiceFailureClassificationOnlyUsesLocalRecorderState() {
        let service = makeService()

        XCTAssertEqual(
            service.classifyVoiceFailure(VoiceRecordingError.microphonePermissionDenied),
            .microphonePermissionRequired
        )
        XCTAssertEqual(
            service.classifyVoiceFailure(VoiceRecordingError.missingMicrophoneInput),
            .microphoneUnavailable
        )
        XCTAssertEqual(
            service.classifyVoiceFailure(VoiceRecordingError.unableToPrepareAudioEngine),
            .recorderUnavailable
        )
    }

    func testVoiceFailureDoesNotTurnBridgeErrorsIntoLoginRecovery() {
        let service = makeService()
        let error = CodexServiceError.disconnected

        XCTAssertEqual(
            service.classifyVoiceFailure(error),
            .generic(error.localizedDescription)
        )
    }


    func testSuccessfulLoginKeepsPollingUntilVoiceTokenIsReady() async throws {
        let service = makeService()
        service.isConnected = true
        var accountStatusReadCount = 0

        service.requestTransportOverride = { method, params in
            switch method {
            case "account/login/start":
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "type": .string("chatgpt"),
                        "loginId": .string("login-123"),
                        "authUrl": .string("https://example.com/login"),
                    ]),
                    includeJSONRPC: false
                )
            case "account/status/read":
                XCTAssertNil(params)
                accountStatusReadCount += 1
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "status": .string("authenticated"),
                        "authMethod": .string("chatgpt"),
                        "email": .string("voice@example.com"),
                        "planType": .string("pro"),
                        "loginInFlight": .bool(false),
                        "needsReauth": .bool(false),
                        "tokenReady": .bool(accountStatusReadCount >= 2),
                    ]),
                    includeJSONRPC: false
                )
            default:
                XCTFail("Unexpected method \(method)")
                throw CodexServiceError.disconnected
            }
        }

        _ = try await service.startOrResumeGPTLogin()
        service.handleIncomingRPCMessage(
            RPCMessage(
                method: "account/login/completed",
                params: .object([
                    "loginId": .string("login-123"),
                    "success": .bool(true),
                    "error": .null,
                ])
            )
        )

        await yieldMainActor(times: 3)

        XCTAssertEqual(service.gptAccountSnapshot.status, .authenticated)
        XCTAssertEqual(service.gptAccountSnapshot.tokenReady, false)
        XCTAssertFalse(service.gptAccountSnapshot.needsReauth)
        XCTAssertNotNil(service.currentPendingGPTLogin())

        await service.refreshGPTAccountState()

        XCTAssertEqual(service.gptAccountSnapshot.status, .authenticated)
        XCTAssertEqual(service.gptAccountSnapshot.tokenReady, true)
        XCTAssertFalse(service.gptAccountSnapshot.needsReauth)
        XCTAssertNil(service.currentPendingGPTLogin())
    }

    private func makeService() -> CodexService {
        let service = CodexService(defaults: makeDefaults())
        Self.retainedServices.append(service)
        return service
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "CodexGPTAccountTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func yieldMainActor(times: Int) async {
        for _ in 0..<times {
            await Task.yield()
        }
    }

    private func makeTemporaryVoiceClipURL(wavData: Data? = nil) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        try (wavData ?? makeTestWavData()).write(to: url)
        return url
    }

    private func makeTestWavData(includeJunkChunk: Bool = false) -> Data {
        let sampleRate = 24_000
        let sampleCount = sampleRate / 4
        let pcmData = Data(repeating: 0, count: sampleCount * 2)
        let dataSize = UInt32(pcmData.count)

        var chunks = Data()
        if includeJunkChunk {
            chunks.append(contentsOf: "JUNK".utf8)
            chunks.appendLE(UInt32(4))
            chunks.append(contentsOf: [1, 2, 3, 4])
        }
        chunks.append(contentsOf: "fmt ".utf8)
        chunks.appendLE(UInt32(16))
        chunks.appendLE(UInt16(1))
        chunks.appendLE(UInt16(1))
        chunks.appendLE(UInt32(sampleRate))
        chunks.appendLE(UInt32(sampleRate * 2))
        chunks.appendLE(UInt16(2))
        chunks.appendLE(UInt16(16))
        chunks.append(contentsOf: "data".utf8)
        chunks.appendLE(dataSize)
        chunks.append(pcmData)

        var wav = Data()
        wav.append(contentsOf: "RIFF".utf8)
        wav.appendLE(UInt32(4 + chunks.count))
        wav.append(contentsOf: "WAVE".utf8)
        wav.append(chunks)
        return wav
    }

    private func XCTAssertThrowsErrorAsync<T>(
        _ expression: () async throws -> T,
        _ errorHandler: (Error) -> Void
    ) async {
        do {
            _ = try await expression()
            XCTFail("Expected expression to throw")
        } catch {
            errorHandler(error)
        }
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { rawBuffer in
            append(contentsOf: rawBuffer.bindMemory(to: UInt8.self))
        }
    }
}
