import Foundation
import WebRTC

@MainActor
final class SignalingPeerProbe {
    let name: String
    let access: AccessHTTP
    let identity: AccessIdentity
    let relayOnly: Bool
    var stream: AccessEventStream?
    var peer: PeerDataChannel?
    var connection: [String: Any]?
    var snapshots = 0
    var opened = false
    var lease: TransportLease?
    var pendingLease: [String: Any]?
    var signalSequence = 0
    var serverTime: Double = 0
    var requestStartedAt: TimeInterval = 0
    var submissions: Task<Void, Never>?

    init(name: String, identity: AccessIdentity, relayOnly: Bool) {
        self.name = name
        self.identity = identity
        self.relayOnly = relayOnly
        access = AccessHTTP(identity: identity)
    }

    static func emit(_ value: [String: Any]) {
        let bytes = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        FileHandle.standardOutput.write(bytes + Data([10]))
    }

    func start() async throws {
        if name == "host" { _ = try await access.post("presence", body: ["protocolVersion": 1, "generation": UUID().uuidString]) }
        stream = AccessEventStream(identity: identity) { [weak self] update in
            Task { @MainActor in self?.update(update) }
        }
        stream?.start()
    }

    func update(_ update: AccessStreamUpdate) {
        switch update {
        case .recovering: break
        case .blocked(let code): Self.emit(["event": "failed", "code": code])
        case .event(let type, let body, let startedAt):
            switch type {
            case "snapshot":
                snapshots += 1
                serverTime = body["serverTime"] as? Double ?? 0
                requestStartedAt = startedAt
                if snapshots > 1 { Self.emit(["event": "resubscribed", "peer": name]) }
            case "connect": configure(body)
            case "lease":
                pendingLease = body
                applyLease()
            case "signal":
                guard body["generation"] as? String == connection?["generation"] as? String,
                      let payload = body["payload"] as? [String: Any], let kind = body["kind"] as? String else { return }
                if kind == "candidate", let candidate = payload["candidate"] as? String, let index = payload["sdpMLineIndex"] as? Int32 {
                    peer?.accept(.candidate(sdp: candidate, index: index, mid: payload["sdpMid"] as? String))
                } else if let sdp = payload["sdp"] as? String, ["offer", "answer"].contains(kind) {
                    peer?.accept(.description(type: kind == "offer" ? .offer : .answer, sdp: sdp))
                } else { Self.emit(["event": "failed", "code": "invalid_signal"]) }
            case "connection.closed", "maintenance":
                lease?.revoke()
                peer?.close()
                Self.emit(["event": "revoked", "peer": name])
            default: break
            }
        }
    }

    func configure(_ body: [String: Any]) {
        guard peer == nil, let generation = body["generation"] as? String else { Self.emit(["event": "failed", "code": "duplicate_peer"]); return }
        connection = body
        lease = TransportLease(generation: generation, serverTime: serverTime, requestStartedAt: requestStartedAt)
        applyLease()
        let servers = (body["iceServers"] as? [[String: Any]] ?? []).map {
            RTCIceServer(urlStrings: $0["urls"] as? [String] ?? [], username: $0["username"] as? String, credential: $0["credential"] as? String)
        }
        peer = PeerDataChannel(iceServers: servers, relayOnly: relayOnly, onSignal: { [weak self] signal in
            Task { @MainActor in
                switch signal {
                case .description(let type, let sdp): self?.submit(kind: type == .offer ? "offer" : "answer", payload: ["sdp": sdp])
                case .candidate(let sdp, let index, let mid): self?.submit(kind: "candidate", payload: ["candidate": sdp, "sdpMLineIndex": index, "sdpMid": mid as Any])
                }
            }
        }, onMessage: { [weak self] bytes in
            Task { @MainActor in
                guard let self, self.lease?.isValid(at: TransportClock.now) == true else {
                    Self.emit(["event": "failed", "code": "wire_without_lease"]); return
                }
                Self.emit(["event": "wire", "peer": self.name, "wire": bytes.base64EncodedString()])
            }
        }, onOpen: { [weak self] in
            Task { @MainActor in self?.opened = true; self?.submit(kind: "connected", payload: [:]) }
        }, onClose: { [weak self] _ in
            Task { @MainActor in self?.opened = false }
        })
        if name == "phone" { peer?.startOffer() }
    }

    func applyLease() {
        guard let body = pendingLease, lease != nil else { return }
        guard let generation = body["generation"] as? String, let sequence = body["sequence"] as? UInt64,
              let expiresAt = body["expiresAt"] as? Double else { Self.emit(["event": "failed", "code": "invalid_lease"]); return }
        do { try lease?.accept(generation: generation, sequence: sequence, expiresAt: expiresAt, now: TransportClock.now) }
        catch { Self.emit(["event": "failed", "code": "lease_rejected"]) }
        pendingLease = nil
    }

    func submit(kind: String, payload: [String: Any]) {
        guard let connection else { return }
        signalSequence += 1
        let body: [String: Any] = ["connectionId": connection["connectionId"]!, "generation": connection["generation"]!,
                                   "sequence": signalSequence, "kind": kind, "payload": payload]
        let previous = submissions
        submissions = Task {
            await previous?.value
            do { _ = try await access.post("signal", body: body) }
            catch { Self.emit(["event": "failed", "code": "signal_failed"]) }
        }
    }

    func stop() { stream?.stop(); peer?.close(); access.cancel(); submissions?.cancel() }
}

@main
struct NativeSignalingProbe {
    @MainActor
    static func main() async throws {
        guard let line = readLine(), let bytes = line.data(using: .utf8), let bootstrap = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let origin = (bootstrap["origin"] as? String).flatMap(URL.init(string:)) else { fatalError("缺少本地测试配置") }
        let relayOnly = bootstrap["relayOnly"] as? Bool ?? false
        func identity(_ name: String) throws -> AccessIdentity {
            let value = bootstrap[name] as! [String: String]
            return try AccessIdentity(origin: origin, token: value["token"]!, privateKey: Data(base64Encoded: value["privateKey"]!)!, allowLoopbackForTesting: true)
        }
        let host = try SignalingPeerProbe(name: "host", identity: identity("host"), relayOnly: relayOnly)
        let phone = try SignalingPeerProbe(name: "phone", identity: identity("phone"), relayOnly: relayOnly)
        defer { host.stop(); phone.stop() }
        try await host.start(); try await phone.start()
        try await wait { host.snapshots > 0 && phone.snapshots > 0 }
        let result = try await phone.access.post("connect", body: ["protocolVersion": 1, "requestId": UUID().uuidString])
        phone.configure(result)
        try await wait { host.opened && phone.opened && host.lease?.isValid(at: TransportClock.now) == true && phone.lease?.isValid(at: TransportClock.now) == true }
        await host.submissions?.value
        await phone.submissions?.value
        var verifiedPath = false
        host.peer?.selectedPath { path in
            Task { @MainActor in
                guard let path, path.relayed == relayOnly else { SignalingPeerProbe.emit(["event": "failed", "code": "incorrect_path"]); return }
                verifiedPath = true
            }
        }
        try await wait { verifiedPath }
        SignalingPeerProbe.emit(["event": "ready", "sessionId": result["sessionId"]!, "relayed": relayOnly])
        for try await line in FileHandle.standardInput.bytes.lines {
            guard let bytes = line.data(using: .utf8), let message = try JSONSerialization.jsonObject(with: bytes) as? [String: String] else { fatalError("测试 IPC 消息无效") }
            if message["command"] == "stop" { break }
            guard let wire = message["wire"].flatMap({ Data(base64Encoded: $0) }) else { fatalError("缺少测试 wire 消息") }
            let peer = message["peer"] == "phone" ? phone : host
            guard peer.lease?.isValid(at: TransportClock.now) == true else { fatalError("过期租约不得发送") }
            peer.peer?.send(wire) { result in if case .failure = result { SignalingPeerProbe.emit(["event": "failed", "code": "send_failed"]) } }
        }
    }

    @MainActor
    static func wait(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        precondition(predicate(), "真实协商必须在期限内完成")
    }
}
