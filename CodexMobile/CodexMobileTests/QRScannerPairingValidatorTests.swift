import XCTest
import AVFoundation
import CryptoKit
@testable import CodexMobile

final class QRScannerPairingValidatorTests: XCTestCase {
    private let key = Data(repeating: 7, count: 32).base64EncodedString()
    private let invitation = String(repeating: "A", count: 43)
    private func code(relay: String = "wss://cc.syggu.cn", key: String? = nil, invitation: String? = nil) -> String {
        let data = try! JSONEncoder().encode([relay, invitation ?? self.invitation, key ?? self.key])
        return "RDX2:" + String(decoding: data, as: UTF8.self)
    }
    func testCompactCodePreservesFullIdentityAndInvitation() {
        guard case .compact(let payload) = validatePairingQRCode(code()) else { return XCTFail("应接受紧凑配对码") }
        XCTAssertEqual(payload.publicKey, key); XCTAssertEqual(payload.invitation, invitation)
        XCTAssertEqual(payload.relay, "wss://cc.syggu.cn")
    }
    func testOldFormatsAlwaysRequireUpdate() {
        for value in ["{\"v\":2,\"relay\":\"wss://example.test\"}", "RMX1:abc", "ABCDEFGHJK", "RDX3:[]"] {
            guard case .bridgeUpdateRequired(let prompt) = validatePairingQRCode(value) else { XCTFail("不再支持旧格式"); continue }
            XCTAssertNil(prompt.command)
            XCTAssertEqual(prompt.message, L10n.string("该配对码来自旧版或不兼容的应用，请更新电脑和 iPhone 应用后重新扫码。"))
        }
    }
    func testRejectsUnsafeAddressAndTruncatedIdentity() {
        for value in [code(relay: "ws://example.test"), code(relay: "wss://user:pass@example.test"), code(relay: "wss://example.test/relay"), code(relay: "wss://example.test?invitation=secret"), code(key: "short"), code(invitation: "short"), "RDX2:[]", "RDX2:[1,2,3]"] {
            guard case .scanError = validatePairingQRCode(value) else { XCTFail("必须拒绝无效码"); continue }
        }
    }
    func testUnrelatedQRCodeIsNotAPairing() {
        guard case .scanError = validatePairingQRCode("https://example.test") else { return XCTFail("必须拒绝无关二维码") }
    }

    func testCameraDetectionCoversTheEntireImage() {
        XCTAssertEqual(QRScannerCapturePolicy.detectionRegion, CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    func testCameraSelectionPrefersSystemLensSwitching() {
        XCTAssertEqual(QRScannerCapturePolicy.cameraTypes, [
            .builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera
        ])
    }

    func testPairingCodeIsNotHiddenByAnotherVisibleQRCode() {
        let pairing = code()
        XCTAssertEqual(QRScannerCapturePolicy.preferredCode(in: ["https://example.test", pairing]), pairing)
        XCTAssertEqual(QRScannerCapturePolicy.preferredCode(in: ["", " \n", pairing]), pairing)
    }

    func testUnrelatedCodeStillProducesValidationFeedback() {
        XCTAssertEqual(QRScannerCapturePolicy.preferredCode(in: ["https://example.test"]), "https://example.test")
        XCTAssertNil(QRScannerCapturePolicy.preferredCode(in: ["", " \n"]))
    }
}

@MainActor
final class PairingFlowTests: XCTestCase {
    private func code(_ seed: UInt8 = 7) -> CompactPairingCode {
        CompactPairingCode(relay: "wss://fixture.invalid", invitation: String(repeating: "A", count: 43), publicKey: Data(repeating: seed, count: 32).base64EncodedString())
    }

    private func payload(_ code: CompactPairingCode) -> CodexPairingQRPayload {
        CodexPairingQRPayload(v: 2, relay: code.relay, sessionId: "", macDeviceId: "fixture-device", macIdentityPublicKey: code.publicKey, expiresAt: Int64(Date().addingTimeInterval(300).timeIntervalSince1970 * 1000), invitation: code.invitation, accountId: "fixture-account", instanceId: UUID().uuidString, platform: "macos")
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("状态未在测试期限内出现")
    }

    func testLocalPageAppearsBeforePreviewRequestCompletes() async throws {
        var continuation: CheckedContinuation<CodexPairingQRPayload, Error>?
        let model = PairingFlowModel { _, _ in
            try await withCheckedThrowingContinuation { continuation = $0 }
        }
        let scanned = code()
        model.recognize(scanned)
        XCTAssertTrue(model.showsDetails)
        XCTAssertEqual(model.phase, .verifying)
        XCTAssertEqual(model.draft, scanned)
        XCTAssertNil(model.verified)
        try await waitUntil { continuation != nil }
        continuation?.resume(returning: payload(scanned))
        try await waitUntil { model.phase == .ready }
        XCTAssertEqual(model.diagnostics.stage, .confirmation)
        model.stop()
    }

    func testTimeoutKeepsDraftAndAllowsVerificationRetry() async throws {
        let scanned = code()
        let valid = payload(scanned)
        var attempts = 0
        let model = PairingFlowModel { _, _ in
            attempts += 1
            if attempts == 1 { throw URLError(.timedOut) }
            return valid
        }
        model.recognize(scanned)
        try await waitUntil { model.phase == .failed }
        XCTAssertTrue(model.showsDetails)
        XCTAssertEqual(model.failureCode, "network_timeout")
        XCTAssertTrue(model.mayRetryVerification)
        XCTAssertEqual(model.draft, scanned)
        model.verify()
        try await waitUntil { model.phase == .ready }
        XCTAssertEqual(attempts, 2)
        model.stop()
    }

    func testCancelledOldResponseCannotReplaceNewQRCode() async throws {
        var pending: [CheckedContinuation<CodexPairingQRPayload, Error>] = []
        let model = PairingFlowModel { _, _ in try await withCheckedThrowingContinuation { pending.append($0) } }
        let oldCode = code(), newCode = code(9)
        model.recognize(oldCode)
        try await waitUntil { pending.count == 1 }
        let oldOperation = model.diagnostics.operationId
        model.rescan()
        model.recognize(newCode)
        try await waitUntil { pending.count == 2 }
        pending[1].resume(returning: payload(newCode))
        try await waitUntil { model.phase == .ready }
        pending[0].resume(returning: payload(oldCode))
        await Task.yield()
        XCTAssertEqual(model.verified?.macIdentityPublicKey, newCode.publicKey)
        XCTAssertNotEqual(model.diagnostics.operationId, oldOperation)
        model.stop()
    }

    func testIdentityMismatchNeverEnablesConfirmation() async throws {
        let wrong = payload(code(9))
        let model = PairingFlowModel { _, _ in wrong }
        model.recognize(code())
        try await waitUntil { model.phase == .failed }
        XCTAssertEqual(model.failureCode, "identity_mismatch")
        XCTAssertNil(model.verified)
        XCTAssertFalse(model.mayRetryVerification)
        var submissions = 0
        model.confirm { _, _ in submissions += 1 }
        XCTAssertEqual(submissions, 0)
    }

    func testDuplicateRecognitionAndConfirmDoNotSubmitTwice() async throws {
        let scanned = code(), valid = payload(code())
        var previews = 0, submissions = 0
        var continuation: CheckedContinuation<Void, Error>?
        let model = PairingFlowModel { _, _ in previews += 1; return valid }
        model.recognize(scanned)
        model.recognize(scanned)
        try await waitUntil { model.phase == .ready }
        let connect: @MainActor (CodexPairingQRPayload, PairingRequestContext) async throws -> Void = { _, context in
            context.transition(.submission)
            submissions += 1
            try await withCheckedThrowingContinuation { continuation = $0 }
        }
        model.confirm(connect: connect)
        model.confirm(connect: connect)
        try await waitUntil { continuation != nil }
        XCTAssertEqual(previews, 1)
        XCTAssertEqual(submissions, 1)
        XCTAssertTrue(model.showsDetails)
        model.stop()
        continuation?.resume()
        await Task.yield()
        XCTAssertEqual(model.phase, .stopped)
        XCTAssertTrue(model.submitted)
    }

    func testRescanVerifiesImmediatelyButWaitsForOldConnectionCleanup() async throws {
        var oldConnection: CheckedContinuation<Void, Never>?
        var submissions = 0
        let model = PairingFlowModel { scanned, _ in self.payload(scanned) }
        model.recognize(code())
        try await waitUntil { model.phase == .ready }
        model.confirm { _, _ in
            submissions += 1
            await withCheckedContinuation { oldConnection = $0 }
        }
        try await waitUntil { oldConnection != nil }
        model.rescan()
        model.recognize(code(9))
        try await waitUntil { model.phase == .ready }
        model.confirm { _, _ in submissions += 1 }
        await Task.yield()
        XCTAssertEqual(submissions, 1)
        oldConnection?.resume()
        try await waitUntil { model.phase == .completed }
        XCTAssertEqual(submissions, 2)
        XCTAssertEqual(model.verified?.macIdentityPublicKey, code(9).publicKey)
    }

    func testPreviewUsesExistingOperationHeaderAndRejectsIdentityMismatch() async throws {
        let trace = PairingDiagnostics()
        trace.identified(relay: code().relay)
        trace.transition(.verification)
        let reference = UUID()
        let context = PairingRequestContext(trace, transport: { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-remodex-operation-id"), trace.operationId.uuidString)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.timeoutInterval, 15)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["x-remodex-request-id": reference.uuidString])!
            let body: [String: Any] = ["device": ["id": "fixture", "public_key": Data(repeating: 9, count: 32).base64EncodedString()], "accountId": "fixture", "instanceId": "fixture", "expiresAt": 2, "serverTime": 1]
            return (try JSONSerialization.data(withJSONObject: body), response)
        })
        do { _ = try await RelayDeviceAccess.preview(code(), context: context); XCTFail("必须拒绝身份变化") }
        catch { XCTAssertEqual(error as? PairingFlowFailure, .identityMismatch) }
        XCTAssertEqual(trace.events.last?.requestId, reference)
        XCTAssertEqual(trace.events.last?.status, 200)
    }

    func testClaimTimeoutIsUncertainAndNotAutomaticallyReplayed() async throws {
        let trace = PairingDiagnostics()
        var requests = 0
        let context = PairingRequestContext(trace, transport: { request in
            XCTAssertEqual(request.url?.path, PairingRoute.claim.rawValue)
            requests += 1
            throw URLError(.timedOut)
        })
        let privateKey = Curve25519.Signing.PrivateKey()
        let identity = CodexPhoneIdentityState(phoneDeviceId: UUID().uuidString, phoneIdentityPrivateKey: privateKey.rawRepresentation.base64EncodedString(), phoneIdentityPublicKey: privateKey.publicKey.rawRepresentation.base64EncodedString())
        do { _ = try await RelayDeviceAccess.pair(payload(code()), identity: identity, context: context); XCTFail("超时不能冒充成功") }
        catch { XCTAssertEqual(error as? PairingFlowFailure, .submissionUncertain) }
        XCTAssertEqual(requests, 1)
        XCTAssertTrue(context.submitted)
    }

    func testServiceFailuresPreserveStatusCodeAndDiagnosticReference() async throws {
        for (status, code) in [(410, "invitation_expired"), (404, "device_offline"), (403, "credential_invalid"), (503, "maintenance"), (429, "rate_limited"), (401, "invalid_device_proof"), (403, "phone_account_conflict"), (401, "credential_revoked")] {
            let trace = PairingDiagnostics()
            trace.transition(.verification)
            let reference = UUID()
            let context = PairingRequestContext(trace, transport: { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["x-remodex-request-id": reference.uuidString])!
                return (try JSONSerialization.data(withJSONObject: ["code": code, "detail": "SENSITIVE_SERVER_BODY"]), response)
            })
            do { _ = try await RelayDeviceAccess.preview(self.code(), context: context); XCTFail("服务端拒绝不能通过验证") }
            catch let error as RelayAccessFailure {
                XCTAssertEqual(error.status, status)
                XCTAssertEqual(error.code, code)
                XCTAssertEqual(error.requestID, reference)
            }
            XCTAssertEqual(trace.events.last?.status, status)
            XCTAssertEqual(trace.events.last?.code, code)
            XCTAssertFalse(trace.exportJSON().contains("SENSITIVE_SERVER_BODY"))
        }
    }

    func testExpiredSuccessfulPreviewIsNotReportedAsIdentityMismatch() async throws {
        let scanned = code()
        let trace = PairingDiagnostics()
        let model = PairingFlowModel { _, context in
            let transportContext = PairingRequestContext(trace, transport: { request in
                let body: [String: Any] = ["device": ["id": "fixture", "public_key": scanned.publicKey], "accountId": "fixture", "instanceId": "fixture", "expiresAt": 1, "serverTime": 2]
                return (try JSONSerialization.data(withJSONObject: body), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })
            try context.checkCancellation()
            return try await RelayDeviceAccess.preview(scanned, context: transportContext)
        }
        model.recognize(scanned)
        try await waitUntil { model.phase == .failed }
        XCTAssertEqual(model.failureCode, "invitation_expired")
        XCTAssertFalse(model.mayRetryVerification)
        XCTAssertNil(model.verified)
        XCTAssertEqual(trace.events.last?.status, 200)
    }

    func testZeroMetadataCallbacksAreNotACameraFailure() {
        let trace = PairingDiagnostics()
        trace.cameraUpdate(PairingCameraSnapshot(running: true, qrEnabled: true, fullFrame: true))
        XCTAssertEqual(trace.stage, .scanning)
        XCTAssertEqual(trace.camera.metadataCallbacks, 0)
        XCTAssertFalse(trace.events.contains { $0.outcome == "failed" })
        trace.cameraFailure(code: "camera_unavailable")
        XCTAssertEqual(trace.events.last?.code, "camera_unavailable")
        XCTAssertEqual(trace.events.last?.outcome, "failed")
    }

    func testDiagnosticExportIsBoundedAndRedacted() throws {
        let trace = PairingDiagnostics()
        let sentinel = "SENSITIVE_TOKEN_COOKIE_INVITATION_PRIVATE_KEY"
        trace.identified(relay: "wss://user:pass@fixture.invalid/relay/session?token=\(sentinel)")
        for _ in 0..<500 {
            trace.recordHTTP(route: .preview, duration: 15, status: 500, code: sentinel, requestId: UUID(), networkError: nil)
        }
        XCTAssertLessThanOrEqual(trace.events.count, 200)
        XCTAssertLessThanOrEqual(trace.exportedByteCount, 65_536)
        trace.transition(.connection)
        trace.finish("failed", code: "submission_uncertain")
        XCTAssertLessThanOrEqual(trace.exportedByteCount, 65_536)
        let report = trace.exportJSON()
        XCTAssertFalse(report.contains(sentinel))
        XCTAssertFalse(report.contains("user:pass"))
        XCTAssertFalse(report.contains("/relay/session"))
        XCTAssertFalse(report.contains("token="))
        XCTAssertEqual(trace.origin, "https://fixture.invalid")
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(report.utf8)) as? [String: Any])
    }

    func testApprovalPollingCoalescesAndPreservesLatestRequestID() {
        let trace = PairingDiagnostics()
        let reference = UUID()
        for _ in 0..<100 {
            trace.beginHTTP(route: .redeem)
            trace.recordHTTP(route: .redeem, duration: 5, status: 409, code: "approval_pending", requestId: reference, networkError: nil)
        }
        let requests = trace.events.filter { $0.route == .redeem }
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.count, 100)
        XCTAssertEqual(requests.first?.requestId, reference)
        XCTAssertEqual(requests.first?.outcome, "waiting")
    }

    func testCancelledContextCannotAddLateDiagnostics() throws {
        let trace = PairingDiagnostics()
        let context = PairingRequestContext(trace)
        context.requestStarted(route: .preview)
        context.cancel()
        let count = trace.events.count
        context.transition(.authorization)
        context.response(route: .preview, started: .now, response: nil, code: nil, error: URLError(.timedOut))
        XCTAssertEqual(trace.events.count, count)
        XCTAssertThrowsError(try context.checkCancellation())
    }

    func testStoppingClosesPendingDiagnosticSpans() {
        let trace = PairingDiagnostics()
        trace.transition(.verification)
        trace.beginHTTP(route: .preview)
        trace.cancelOutstanding()
        XCTAssertFalse(trace.events.contains { $0.outcome == "in_progress" })
        XCTAssertEqual(trace.events.last?.outcome, "cancelled")
        XCTAssertNil(trace.events.last?.status)
        XCTAssertNil(trace.events.last?.requestId)
    }
}
