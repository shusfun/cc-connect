import Foundation
import WebRTC

enum PeerSignal {
    case description(type: RTCSdpType, sdp: String)
    case candidate(sdp: String, index: Int32, mid: String?)
}

struct PeerPath {
    let relayed: Bool
    let bytesSent: UInt64
    let bytesReceived: UInt64
}

final class PeerDataChannel: NSObject, RTCPeerConnectionDelegate, RTCDataChannelDelegate, @unchecked Sendable {
    private static let initialized: Void = { RTCInitializeSSL() }()
    private let queue = DispatchQueue(label: "remodex.transport.peer")
    private let factory: RTCPeerConnectionFactory
    private var connection: RTCPeerConnection?
    private var channel: RTCDataChannel?
    private var timer: DispatchSourceTimer?
    private var closed = false
    private var opened = false
    private var remoteReady = false
    private var applyingDescription = false
    private var candidates: [RTCIceCandidate] = []
    private var receiver = TransportReassembler()
    private var pending: [PendingMessage] = []
    private var queuedBytes = 0
    private var nextIdentifier: UInt32 = 0
    private var peerFrameLimit = TransportFraming.maximumFrameBytes
    private let outboundBudget = TransportBudget(bytes: TransportFraming.maximumMessageBytes, count: 8)
    private let inboundBudget = TransportBudget(bytes: 1_048_576, count: 64)
    private let signalBudget = TransportBudget(bytes: 262_144, count: 256)
    private let onSignal: (PeerSignal) -> Void
    private let onMessage: (Data) -> Void
    private let onOpen: () -> Void
    private let onClose: (TransportFailure) -> Void

    private struct PendingMessage {
        let identifier: UInt32
        let data: Data
        var offset: Int
        let deadline: TimeInterval
        let completion: (Result<Void, Error>) -> Void
    }

    init(iceServers: [RTCIceServer], relayOnly: Bool = false, onSignal: @escaping (PeerSignal) -> Void,
         onMessage: @escaping (Data) -> Void, onOpen: @escaping () -> Void, onClose: @escaping (TransportFailure) -> Void) {
        _ = Self.initialized
        factory = RTCPeerConnectionFactory()
        self.onSignal = onSignal
        self.onMessage = onMessage
        self.onOpen = onOpen
        self.onClose = onClose
        super.init()
        let configuration = RTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        configuration.iceServers = iceServers
        configuration.iceTransportPolicy = relayOnly ? .relay : .all
        configuration.bundlePolicy = .maxBundle
        connection = factory.peerConnection(with: configuration, constraints: Self.constraints, delegate: self)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [weak self] in
            guard let self, !self.closed else { return }
            do { try self.receiver.expire(at: TransportClock.now) }
            catch { self.finish(.messageExpired); return }
            self.drain()
        }
        self.timer = timer
        timer.resume()
    }

    deinit {
        timer?.cancel()
        channel?.delegate = nil
        connection?.delegate = nil
        connection?.close()
    }

    private static var constraints: RTCMediaConstraints { RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil) }

    func startOffer() {
        queue.async {
            guard !self.closed, self.channel == nil, let connection = self.connection else { return }
            let configuration = RTCDataChannelConfiguration()
            configuration.isOrdered = true
            configuration.protocol = "remodex.wire.v1"
            guard let channel = connection.dataChannel(forLabel: "remodex", configuration: configuration) else { self.finish(.unavailable); return }
            self.bind(channel)
            connection.offer(for: Self.constraints) { [weak self] description, error in
                self?.publish(description, error: error)
            }
        }
    }

    func accept(_ signal: PeerSignal) {
        let size: Int
        switch signal {
        case .description(_, let sdp): size = sdp.utf8.count
        case .candidate(let sdp, _, let mid): size = sdp.utf8.count + (mid?.utf8.count ?? 0)
        }
        guard signalBudget.acquire(size) else { close(.backpressure); return }
        queue.async {
            defer { self.signalBudget.release(size) }
            guard !self.closed, let connection = self.connection else { return }
            switch signal {
            case .candidate(let sdp, let index, let mid):
                guard sdp.utf8.count <= 8192, index >= 0, self.candidates.count < 256 else { self.finish(.invalidFrame); return }
                let candidate = RTCIceCandidate(sdp: sdp, sdpMLineIndex: index, sdpMid: mid)
                if self.remoteReady { self.add(candidate) } else { self.candidates.append(candidate) }
            case .description(let type, let sdp):
                guard sdp.utf8.count <= 65_536, !self.remoteReady, !self.applyingDescription,
                      (type == .offer && self.channel == nil) || (type == .answer && self.channel != nil) else { self.finish(.invalidFrame); return }
                do { self.peerFrameLimit = try TransportFraming.peerFrameLimit(sdp: sdp) }
                catch { self.finish(.invalidFrame); return }
                self.applyingDescription = true
                connection.setRemoteDescription(RTCSessionDescription(type: type, sdp: sdp)) { [weak self] error in
                    self?.queue.async { [weak self] in
                        guard let self, !self.closed else { return }
                        guard error == nil else { self.finish(.invalidFrame); return }
                        self.remoteReady = true
                        self.applyingDescription = false
                        for candidate in self.candidates { self.add(candidate) }
                        self.candidates.removeAll()
                        if type == .offer {
                            self.connection?.answer(for: Self.constraints) { [weak self] answer, error in self?.publish(answer, error: error) }
                        }
                    }
                }
            }
        }
    }

    private func publish(_ description: RTCSessionDescription?, error: Error?) {
        queue.async {
            guard !self.closed else { return }
            guard let description, error == nil else { self.finish(.unavailable); return }
            self.connection?.setLocalDescription(description) { [weak self] error in
                self?.queue.async { [weak self] in
                    guard let self, !self.closed else { return }
                    guard error == nil else { self.finish(.unavailable); return }
                    self.onSignal(.description(type: description.type, sdp: description.sdp))
                }
            }
        }
    }

    private func add(_ candidate: RTCIceCandidate) {
        connection?.add(candidate) { [weak self] error in
            if error != nil { self?.close(.invalidFrame) }
        }
    }

    func send(_ data: Data, completion: @escaping (Result<Void, Error>) -> Void) {
        guard !data.isEmpty, data.count <= TransportFraming.maximumMessageBytes else { completion(.failure(TransportFailure.messageTooLarge)); return }
        guard outboundBudget.acquire(data.count) else { completion(.failure(TransportFailure.backpressure)); return }
        let complete: (Result<Void, Error>) -> Void = { [outboundBudget] result in
            outboundBudget.release(data.count)
            completion(result)
        }
        queue.async {
            guard !self.closed, self.opened else { complete(.failure(TransportFailure.unavailable)); return }
            self.nextIdentifier &+= 1
            self.pending.append(PendingMessage(identifier: self.nextIdentifier, data: data, offset: 0,
                                               deadline: TransportClock.now + 60, completion: complete))
            self.queuedBytes += data.count
            self.drain()
        }
    }

    private func drain() {
        guard !closed, let channel, channel.readyState == .open else { return }
        if let first = pending.first, TransportClock.now >= first.deadline { finish(.messageExpired); return }
        for _ in 0..<32 {
            guard !pending.isEmpty, channel.bufferedAmount < 262_144 else { return }
            do {
                let first = pending[0]
                let frame = try TransportFraming.frame(first.data, identifier: first.identifier, offset: first.offset, negotiatedLimit: peerFrameLimit)
                guard channel.sendData(RTCDataBuffer(data: frame, isBinary: true)) else { return }
                pending[0].offset += frame.count - TransportFraming.headerBytes
                if pending[0].offset == first.data.count {
                    pending.removeFirst()
                    queuedBytes -= first.data.count
                    first.completion(.success(()))
                }
            } catch { finish(.invalidFrame); return }
        }
    }

    func close(_ reason: TransportFailure = .cancelled) { queue.async { self.finish(reason) } }

    private func finish(_ reason: TransportFailure) {
        guard !closed else { return }
        closed = true
        timer?.cancel()
        timer = nil
        channel?.delegate = nil
        channel?.close()
        connection?.delegate = nil
        connection?.close()
        channel = nil
        connection = nil
        candidates.removeAll()
        receiver.reset()
        let cancelled = pending
        pending.removeAll()
        queuedBytes = 0
        for message in cancelled { message.completion(.failure(reason)) }
        onClose(reason)
    }

    func selectedPath(_ completion: @escaping (PeerPath?) -> Void) {
        queue.async {
            guard !self.closed, let connection = self.connection else { completion(nil); return }
            connection.statistics { [weak self] report in
                self?.queue.async { [weak self] in
                    guard let self, !self.closed else { completion(nil); return }
                    let pairID = report.statistics.values.first(where: { $0.type == "transport" })?.values["selectedCandidatePairId"] as? String
                    guard let pairID, let pair = report.statistics[pairID],
                          let localID = pair.values["localCandidateId"] as? String, let remoteID = pair.values["remoteCandidateId"] as? String,
                          let local = report.statistics[localID], let remote = report.statistics[remoteID] else { completion(nil); return }
                    completion(PeerPath(relayed: local.values["candidateType"] as? String == "relay" || remote.values["candidateType"] as? String == "relay",
                                        bytesSent: (pair.values["bytesSent"] as? NSNumber)?.uint64Value ?? 0,
                                        bytesReceived: (pair.values["bytesReceived"] as? NSNumber)?.uint64Value ?? 0))
                }
            }
        }
    }

    private func bind(_ channel: RTCDataChannel) {
        guard self.channel == nil, channel.label == "remodex", channel.protocol == "remodex.wire.v1", channel.isOrdered,
              channel.maxPacketLifeTime == UInt16.max, channel.maxRetransmits == UInt16.max else { finish(.invalidFrame); return }
        self.channel = channel
        channel.delegate = self
        channelState(channel)
    }

    private func channelState(_ channel: RTCDataChannel) {
        guard !closed, self.channel === channel else { return }
        if channel.readyState == .open, !opened { opened = true; onOpen(); drain() }
        if channel.readyState == .closed { finish(.unavailable) }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) { }
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) { close(.invalidFrame) }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) { }
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) { }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        if newState == .failed || newState == .closed { close(.unavailable) }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) { }
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        queue.async { if !self.closed { self.onSignal(.candidate(sdp: candidate.sdp, index: candidate.sdpMLineIndex, mid: candidate.sdpMid)) } }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) { }
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) { queue.async { if !self.closed { self.bind(dataChannel) } } }
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) { queue.async { self.channelState(dataChannel) } }
    func dataChannel(_ dataChannel: RTCDataChannel, didChangeBufferedAmount amount: UInt64) { queue.async { self.drain() } }
    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard inboundBudget.acquire(buffer.data.count) else { close(.backpressure); return }
        queue.async {
            defer { self.inboundBudget.release(buffer.data.count) }
            guard !self.closed, self.channel === dataChannel else { return }
            guard buffer.isBinary else { self.finish(.invalidFrame); return }
            do { if let message = try self.receiver.receive(buffer.data, now: TransportClock.now) { self.onMessage(message) } }
            catch { self.finish(.invalidFrame) }
        }
    }
}
