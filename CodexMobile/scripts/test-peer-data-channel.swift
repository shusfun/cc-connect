import Foundation
import WebRTC

final class PeerHarness {
    private let lock = NSLock()
    private var messages: [Data] = []
    private var failures: [TransportFailure] = []
    private var path: PeerPath?
    var peer: PeerDataChannel!
    weak var remote: PeerHarness?

    init() {
        peer = PeerDataChannel(iceServers: [], onSignal: { [weak self] signal in self?.remote?.peer.accept(signal) },
                               onMessage: { [weak self] data in self?.record(data) }, onOpen: {},
                               onClose: { [weak self] failure in self?.failed(failure) })
    }

    func record(_ data: Data) { lock.lock(); messages.append(data); lock.unlock() }
    func failed(_ error: TransportFailure) { lock.lock(); failures.append(error); lock.unlock() }
    func received(_ data: Data) -> Bool { lock.lock(); defer { lock.unlock() }; return messages.contains(data) }
    func checkPath() { peer.selectedPath { [weak self] path in self?.lock.lock(); self?.path = path; self?.lock.unlock() } }
    var direct: Bool { lock.lock(); defer { lock.unlock() }; return path?.relayed == false }
    var healthy: Bool { lock.lock(); defer { lock.unlock() }; return failures.isEmpty }
}

@main
struct PeerDataChannelTests {
    static func wait(_ predicate: () -> Bool) {
        let deadline = Date().addingTimeInterval(30)
        while !predicate(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        precondition(predicate(), "原生包装器在期限内完成")
    }

    static func main() {
        let first = PeerHarness(), second = PeerHarness()
        first.remote = second; second.remote = first
        first.peer.startOffer()
        wait { first.checkPath(); second.checkPath(); return first.direct && second.direct }
        let large = Data(repeating: 85, count: TransportFraming.maximumMessageBytes)
        let reply = Data("wire-reply".utf8)
        first.peer.send(large) { result in if case .failure = result { preconditionFailure("合法大消息必须发送") } }
        second.peer.send(reply) { result in if case .failure = result { preconditionFailure("反向消息必须发送") } }
        wait { second.received(large) && first.received(reply) }
        precondition(first.healthy && second.healthy)
        first.peer.send(Data()) { result in
            guard case .failure(let error) = result, error as? TransportFailure == .messageTooLarge else { preconditionFailure("空消息拒绝") }
        }
        first.peer.close(); second.peer.close()
        wait { !first.healthy && !second.healthy }
        print("peer_data_channel_real_sdk_large_message_bidirectional_direct_path_passed")
    }
}
