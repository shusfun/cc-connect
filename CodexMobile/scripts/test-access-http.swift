import CryptoKit
import Foundation

@MainActor
final class AccessProbeState {
    var retryDelay: TimeInterval?
    var received = false
    var blocked: String?
}

@main
struct AccessHTTPTests {
    @MainActor
    static func main() async throws {
        let config = try JSONSerialization.jsonObject(with: Data(readLine()!.utf8)) as! [String: String]
        let origin = URL(string: config["origin"]!)!
        let key = Data(base64Encoded: config["privateKey"]!)!
        do { _ = try AccessIdentity(origin: origin, token: config["token"]!, privateKey: key); preconditionFailure("生产凭据不得发往 HTTP") }
        catch TransportFailure.unavailable { }
        let identity = try AccessIdentity(origin: origin, token: config["token"]!, privateKey: key, allowLoopbackForTesting: true)
        let access = AccessHTTP(identity: identity)
        defer { access.cancel() }
        for (mode, status, code) in [("redirect", 400, "redirect_rejected"), ("revoke", 401, "credential_revoked"),
                                      ("oversized", 400, "event_too_large"), ("wrong-mime", 400, "invalid_content_type")] {
            do { _ = try await access.post("presence", body: ["mode": mode]); preconditionFailure("异常 HTTP 不能成功") }
            catch let failure as AccessHTTPFailure { precondition(failure.status == status && failure.code == code) }
        }
        do { _ = try await access.post("presence", body: ["mode": "retry-date"]); preconditionFailure("429 不得成功") }
        catch let failure as AccessHTTPFailure { precondition(failure.status == 429 && failure.retryAfter > 0 && failure.retryAfter <= 3) }
        let state = AccessProbeState()
        let stream = AccessEventStream(identity: identity) { update in
            Task { @MainActor in
                switch update {
                case .recovering(let delay): state.retryDelay = delay
                case .event(let type, _, _): if type == "snapshot" { state.received = true }
                case .blocked(let code): state.blocked = code
                }
            }
        }
        stream.start()
        try await wait { state.received || state.blocked != nil }
        precondition(state.received && state.blocked == nil && (state.retryDelay ?? 0) >= 2)
        stream.stop()
        _ = try await access.post("signal", body: ["mode": "oversized-stream"])
        let oversized = AccessEventStream(identity: identity) { update in
            if case .blocked(let code) = update { Task { @MainActor in state.blocked = code } }
        }
        oversized.start()
        try await wait { state.blocked != nil }
        precondition(state.blocked == "event_too_large")
        oversized.stop()
        try await Task.sleep(for: .milliseconds(200))
        print("native_access_signature_retry_after_redirect_size_and_cancel_passed")
    }

    @MainActor
    static func wait(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        precondition(predicate())
    }
}
