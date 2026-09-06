import Foundation
import Observation

enum PairingStage: String, Codable, CaseIterable {
    case camera, scanning, decoded, validation, verification, confirmation, submission, approval, authorization, connection, completed

    var title: String {
        switch self {
        case .camera: return L10n.string("相机启动")
        case .scanning: return L10n.string("等待二维码")
        case .decoded: return L10n.string("本地解码")
        case .validation: return L10n.string("格式校验")
        case .verification: return L10n.string("VPS 验证")
        case .confirmation: return L10n.string("等待用户确认")
        case .submission: return L10n.string("提交配对申请")
        case .approval: return L10n.string("等待电脑批准")
        case .authorization: return L10n.string("获取授权")
        case .connection: return L10n.string("建立加密连接")
        case .completed: return L10n.string("配对连接完成")
        }
    }
}

enum PairingRoute: String, Codable {
    case preview = "/v1/access/pairing/preview"
    case claim = "/v1/access/pairing/claim"
    case redeem = "/v1/access/pairing/redeem"
    case session = "/v1/access/session"
}

enum PairingFlowFailure: String, Error {
    case identityMismatch = "identity_mismatch"
    case invalidResponse = "invalid_response"
    case submissionUncertain = "submission_uncertain"
    case connectionIncomplete = "connection_incomplete"
}

struct PairingDiagnosticEvent: Codable, Identifiable {
    var id = UUID()
    var stage: PairingStage
    var outcome: String
    var elapsedMilliseconds: Int
    var durationMilliseconds: Int?
    var route: PairingRoute?
    var method: String?
    var status: Int?
    var code: String?
    var requestId: UUID?
    var networkError: Int?
    var count = 1
}

nonisolated struct PairingCameraSnapshot: Codable, Sendable {
    var selectedType = "unavailable"
    var running = false
    var qrEnabled = false
    var fullFrame = false
    var metadataCallbacks = 0
    var qrCount = 0
    var recoveryCount = 0
}

@MainActor @Observable
final class PairingDiagnostics {
    private(set) var operationId = UUID()
    private(set) var events: [PairingDiagnosticEvent] = []
    private(set) var camera = PairingCameraSnapshot()
    private(set) var origin: String?
    private(set) var stage = PairingStage.camera
    private(set) var connectionAttempts = 0
    private(set) var stageStartedAt = ContinuousClock.now
    @ObservationIgnored private var startedAt = ContinuousClock.now
    @ObservationIgnored private var activeEventId: UUID?
    @ObservationIgnored private let clock: () -> ContinuousClock.Instant
    private(set) var environment: [String: String] = [:]

    init(clock: @escaping () -> ContinuousClock.Instant = { .now }) {
        self.clock = clock
        startedAt = clock()
        stageStartedAt = startedAt
        transition(.camera)
    }

    var elapsedMilliseconds: Int { milliseconds(startedAt.duration(to: clock())) }
    var stageMilliseconds: Int { milliseconds(stageStartedAt.duration(to: clock())) }
    var exportedByteCount: Int { exportData().count }

    func setEnvironment(model: String, system: String) {
        let info = Bundle.main.infoDictionary ?? [:]
        environment = ["version": safeVersion(info["CFBundleShortVersionString"] as? String),
                       "build": safeVersion(info["CFBundleVersion"] as? String),
                       "sourceSHA": safeVersion(info["RemodexSourceSHA"] as? String),
                       "model": safeVersion(model), "system": safeVersion(system)]
        trim()
    }

    func reset() {
        operationId = UUID()
        events = []
        activeEventId = nil
        trim()
        origin = nil
        camera = PairingCameraSnapshot()
        connectionAttempts = 0
        startedAt = clock()
        transition(.camera)
    }

    func identified(relay: String) {
        operationId = UUID()
        if var address = URLComponents(string: relay), let host = address.host {
            address = URLComponents()
            address.scheme = "https"
            address.host = host
            address.port = URLComponents(string: relay)?.port
            origin = address.string
        }
        transition(.decoded)
    }

    func transition(_ next: PairingStage) {
        finish("completed")
        stage = next
        stageStartedAt = clock()
        let event = PairingDiagnosticEvent(stage: next, outcome: "in_progress", elapsedMilliseconds: elapsedMilliseconds)
        activeEventId = event.id
        events.append(event)
        trim()
    }

    func finish(_ outcome: String, code: String? = nil) {
        if let index = events.firstIndex(where: { $0.id == activeEventId }) {
            events[index].outcome = outcome
            events[index].durationMilliseconds = stageMilliseconds
            events[index].code = Self.safeCode(code)
        }
        activeEventId = nil
    }

    func cancelOutstanding() {
        finish("cancelled", code: "cancelled")
        for index in events.indices where events[index].outcome == "in_progress" {
            events[index].outcome = "cancelled"
            events[index].code = "cancelled"
            events[index].durationMilliseconds = max(0, elapsedMilliseconds - events[index].elapsedMilliseconds)
        }
        trim()
    }

    func cameraUpdate(_ snapshot: PairingCameraSnapshot) {
        camera = snapshot
        let types: Set<String> = ["AVCaptureDeviceTypeBuiltInTripleCamera", "AVCaptureDeviceTypeBuiltInDualWideCamera", "AVCaptureDeviceTypeBuiltInDualCamera", "AVCaptureDeviceTypeBuiltInWideAngleCamera"]
        if !types.contains(camera.selectedType) { camera.selectedType = "unavailable" }
        if snapshot.running && stage == .camera { transition(.scanning) }
        trim()
    }

    func cameraFailure(code: String) { finish("failed", code: code) }
    func connectionAttempt(_ attempt: Int) { connectionAttempts = attempt }

    func beginHTTP(route: PairingRoute) {
        events.append(PairingDiagnosticEvent(stage: stage, outcome: "in_progress", elapsedMilliseconds: elapsedMilliseconds, route: route, method: "POST"))
        trim()
    }

    func recordHTTP(route: PairingRoute, duration: Int, status: Int?, code: String?, requestId: UUID?, networkError: Int?) {
        let safeCode = Self.safeCode(code)
        let outcome = code == "approval_pending" ? "waiting" : (status == 200 ? "completed" : "failed")
        if route == .redeem, code == "approval_pending",
           let index = events.lastIndex(where: { $0.route == route && $0.code == safeCode }) {
            events[index].count += 1
            events[index].durationMilliseconds = duration
            events[index].requestId = requestId
            events[index].elapsedMilliseconds = elapsedMilliseconds
            events.removeAll { $0.route == route && $0.outcome == "in_progress" }
        } else if let index = events.lastIndex(where: { $0.route == route && $0.outcome == "in_progress" }) {
            events[index].outcome = outcome
            events[index].durationMilliseconds = duration
            events[index].status = status
            events[index].code = safeCode
            events[index].requestId = requestId
            events[index].networkError = networkError
        } else {
            events.append(PairingDiagnosticEvent(stage: stage, outcome: outcome, elapsedMilliseconds: elapsedMilliseconds,
                durationMilliseconds: duration, route: route, method: "POST", status: status,
                code: safeCode, requestId: requestId, networkError: networkError))
        }
        trim()
    }

    func exportJSON() -> String { String(decoding: exportData(), as: UTF8.self) }

    static func failureCode(_ error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        if let failure = error as? PairingFlowFailure { return failure.rawValue }
        if let failure = error as? RelayAccessFailure { return safeCode(failure.code) ?? "request_failed" }
        if error is DecodingError { return "invalid_response" }
        if let failure = error as? CodexServiceError {
            switch failure {
            case .invalidServerURL: return "invalid_server_url"
            case .invalidInput: return "invalid_input"
            case .invalidResponse: return "invalid_response"
            case .encodingFailed: return "encoding_failed"
            case .disconnected: return "disconnected"
            case .noPendingApproval: return "no_pending_approval"
            case .rpcError: return "rpc_error"
            }
        }
        let network = error as NSError
        if network.domain == NSURLErrorDomain {
            switch network.code {
            case NSURLErrorTimedOut: return "network_timeout"
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost: return "network_unavailable"
            case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return "dns_failed"
            case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate: return "tls_failed"
            case NSURLErrorCancelled: return "cancelled"
            default: return "network_failed"
            }
        }
        return "connection_failed"
    }

    static func safeCode(_ value: String?) -> String? {
        guard let value else { return nil }
        let allowed: Set<String> = ["approval_pending", "device_offline", "invitation_expired", "invitation_consumed", "request_expired", "request_consumed", "credential_invalid", "access_revoked", "device_revoked", "pairing_revoked", "account_pending", "account_disabled", "account_rejected", "device_limit", "account_mismatch", "device_owned", "rate_limited", "maintenance", "identity_mismatch", "invalid_response", "submission_uncertain", "connection_incomplete", "network_timeout", "network_unavailable", "dns_failed", "tls_failed", "network_failed", "cancelled", "connection_failed", "invalid_qr", "update_required", "camera_unavailable", "camera_interrupted", "camera_configuration_failed", "camera_focus_failed", "camera_torch_failed", "camera_permission_denied", "request_failed"]
        return allowed.contains(value) || ["invalid_server_url", "invalid_input", "encoding_failed", "disconnected", "no_pending_approval", "rpc_error"].contains(value) ? value : "request_failed"
    }

    private func trim() {
        while events.count > 200 || (events.count > 1 && exportData().count > 65_536) {
            if let index = events.firstIndex(where: { $0.id != activeEventId }) { events.remove(at: index) }
            else { break }
        }
    }

    private func exportData() -> Data {
        struct Report: Encodable {
            let operationId: UUID
            let environment: [String: String]
            let origin: String?
            let camera: PairingCameraSnapshot
            let events: [PairingDiagnosticEvent]
            let connectionAttempts: Int
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return (try? encoder.encode(Report(operationId: operationId, environment: environment, origin: origin, camera: camera, events: events, connectionAttempts: connectionAttempts))) ?? Data()
    }

    private func safeVersion(_ value: String?) -> String {
        guard let value, value.utf8.count <= 80, value.range(of: "^[A-Za-z0-9., _-]+$", options: .regularExpression) != nil else { return "unavailable" }
        return value
    }

    private func milliseconds(_ duration: Duration) -> Int {
        let parts = duration.components
        return max(0, Int(parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000))
    }
}

@MainActor
final class PairingRequestContext {
    typealias Transport = @MainActor (URLRequest) async throws -> (Data, URLResponse)
    let operationId: UUID
    let transport: Transport?
    private weak var diagnostics: PairingDiagnostics?
    private(set) var cancelled = false
    private(set) var submitted = false

    init(_ diagnostics: PairingDiagnostics, transport: Transport? = nil) {
        self.diagnostics = diagnostics
        operationId = diagnostics.operationId
        self.transport = transport
    }

    func cancel() { cancelled = true }
    func connectionAttempt(_ attempt: Int) {
        guard !cancelled, diagnostics?.operationId == operationId else { return }
        diagnostics?.connectionAttempt(attempt)
    }
    func requestStarted(route: PairingRoute) {
        guard !cancelled, diagnostics?.operationId == operationId else { return }
        diagnostics?.beginHTTP(route: route)
    }
    func checkCancellation() throws {
        try Task.checkCancellation()
        if cancelled || diagnostics?.operationId != operationId { throw CancellationError() }
    }
    func transition(_ stage: PairingStage) {
        guard !cancelled, diagnostics?.operationId == operationId else { return }
        if stage == .submission { submitted = true }
        diagnostics?.transition(stage)
    }
    func response(route: PairingRoute, started: ContinuousClock.Instant, response: URLResponse?, code: String?, error: Error? = nil) {
        guard !cancelled, diagnostics?.operationId == operationId else { return }
        let duration = started.duration(to: .now).components
        let network = error as NSError?
        let http = response as? HTTPURLResponse
        diagnostics?.recordHTTP(route: route, duration: max(0, Int(duration.seconds * 1000 + duration.attoseconds / 1_000_000_000_000_000)),
            status: http?.statusCode, code: code ?? error.map(PairingDiagnostics.failureCode),
            requestId: http?.value(forHTTPHeaderField: "x-remodex-request-id").flatMap(UUID.init(uuidString:)),
            networkError: network?.domain == NSURLErrorDomain ? network?.code : nil)
    }
}
