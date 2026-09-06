import Foundation
import WebRTC

final class CapabilityPeer: NSObject, RTCPeerConnectionDelegate, RTCDataChannelDelegate {
    let factory = RTCPeerConnectionFactory()
    var connection: RTCPeerConnection!
    var channel: RTCDataChannel?
    weak var remote: CapabilityPeer?
    private let lock = NSLock()
    private var receivedValue = false
    private var failureValue = false
    var received: Bool {
        get { lock.lock(); defer { lock.unlock() }; return receivedValue }
        set { lock.lock(); defer { lock.unlock() }; receivedValue = newValue }
    }
    var failure: Bool {
        get { lock.lock(); defer { lock.unlock() }; return failureValue }
        set { lock.lock(); defer { lock.unlock() }; failureValue = newValue }
    }
    let queue = DispatchQueue(label: "remodex.capability")
    var candidates: [RTCIceCandidate] = []

    init(iceServers: [RTCIceServer] = [], relayOnly: Bool = false) {
        super.init()
        let configuration = RTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        configuration.iceServers = iceServers
        configuration.iceTransportPolicy = relayOnly ? .relay : .all
        connection = factory.peerConnection(with: configuration, constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), delegate: self)
    }

    func start() {
        let configuration = RTCDataChannelConfiguration()
        configuration.isOrdered = true
        channel = connection.dataChannel(forLabel: "remodex.capability", configuration: configuration)
        channel?.delegate = self
        connection.offer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { description, error in
            guard let description, error == nil else { self.failure = true; return }
            self.connection.setLocalDescription(description) { error in
                guard error == nil else { self.failure = true; return }
                self.remote?.accept(description)
            }
        }
    }

    func accept(_ description: RTCSessionDescription) {
        queue.async { self.connection.setRemoteDescription(description) { error in
            guard error == nil else { self.failure = true; return }
            if description.type == .offer {
                self.connection.answer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { answer, error in
                    guard let answer, error == nil else { self.failure = true; return }
                    self.connection.setLocalDescription(answer) { error in
                        guard error == nil else { self.failure = true; return }
                        self.remote?.accept(answer)
                    }
                }
            }
        } }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) { }
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) { }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) { }
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) { }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) { }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) { }
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        guard let remote else { return }
        remote.queue.async {
            remote.connection.add(candidate) { error in if error != nil { remote.failure = true } }
        }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) { }
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        channel = dataChannel
        dataChannel.delegate = self
    }
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        if dataChannel.readyState == .open {
            queue.async {
                if !dataChannel.sendData(RTCDataBuffer(data: Data("remodex-capability".utf8), isBinary: true)) { self.failure = true }
            }
        }
    }
    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        received = buffer.data == Data("remodex-capability".utf8)
    }
}

@main
struct WebRTCCapabilityTest {
    static func main() {
        RTCInitializeSSL()
        let cycles = CommandLine.arguments.dropFirst().first.flatMap(Int.init) ?? 1
        precondition((1...1000).contains(cycles))
        for _ in 0..<cycles { autoreleasepool { exerciseConnection() } }
        print("native_webrtc_direct_datachannel_passed cycles=\(cycles)")
    }

    static func exerciseConnection() {
        let first = CapabilityPeer()
        let second = CapabilityPeer()
        first.remote = second
        second.remote = first
        first.start()
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline && !(first.received && second.received) && !first.failure && !second.failure {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        first.connection.close()
        second.connection.close()
        precondition(first.received && second.received && !first.failure && !second.failure, "原生 DataChannel 必须双向收发")
    }
}
