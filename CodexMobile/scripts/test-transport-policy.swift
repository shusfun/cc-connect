import Foundation

@main
struct TransportPolicyTests {
    static func main() throws {
        var lease = TransportLease(generation: "current", serverTime: 100_000, requestStartedAt: 10)
        try lease.accept(generation: "current", sequence: 1, expiresAt: 160_000, now: 12)
        precondition(lease.isValid(at: 69) && !lease.isValid(at: 70))
        expectFailure { try lease.accept(generation: "current", sequence: 1, expiresAt: 160_000, now: 20) }
        expectFailure { try lease.accept(generation: "old", sequence: 2, expiresAt: 170_000, now: 20) }
        expectFailure { try lease.accept(generation: "current", sequence: 2, expiresAt: 999_000, now: 20) }
        lease.revoke()
        precondition(!lease.isValid(at: 21))
        var delayedLease = TransportLease(generation: "current", serverTime: 100_000, requestStartedAt: 10)
        expectFailure { try delayedLease.accept(generation: "current", sequence: 1, expiresAt: 160_000, now: 71) }
        let budget = TransportBudget(bytes: 100, count: 2)
        precondition(budget.acquire(80) && !budget.acquire(21) && budget.acquire(20) && !budget.acquire(0))
        budget.release(80)
        precondition(budget.acquire(80))
        budget.release(20); budget.release(80)
        let peerLimit = try TransportFraming.peerFrameLimit(sdp: "v=0\r\na=max-message-size:512\r\n")
        precondition(peerLimit == 512)
        expectFailure { _ = try TransportFraming.peerFrameLimit(sdp: "a=max-message-size:16") }
        let narrow = try TransportFraming.frames(Data(repeating: 1, count: 1000), identifier: 8, negotiatedLimit: peerLimit)
        precondition(narrow.allSatisfy { $0.count <= 512 })

        var recovery = BridgeRecoveryPolicy()
        for index in 0..<5 { recovery.recordAttempt(at: Double(index)) }
        precondition(recovery.delay(now: 5) == 300)
        precondition(recovery.delay(now: 100) == 205)
        precondition(recovery.delay(now: 306) <= 30)
        recovery.observeHealthy(at: 310)
        recovery.observeHealthy(at: 610)
        precondition(recovery.failures == 0)

        for size in [1, 16_368, 16_369, 1_048_576, TransportFraming.maximumMessageBytes] {
            let original = Data(repeating: 173, count: size)
            let frames = try TransportFraming.frames(original, identifier: 42)
            var assembler = TransportReassembler()
            var result: Data?
            for frame in frames { result = try assembler.receive(frame, now: 1) }
            precondition(result == original)
        }
        var assembler = TransportReassembler()
        let frames = try TransportFraming.frames(Data(repeating: 1, count: 30_000), identifier: 1)
        expectFailure { _ = try assembler.receive(frames[1], now: 0) }
        _ = try assembler.receive(frames[0], now: 0)
        expectFailure { _ = try assembler.receive(frames[1], now: 60) }
        _ = try assembler.receive(frames[0], now: 100)
        expectFailure { try assembler.expire(at: 160) }
        _ = try assembler.receive(frames[0], now: 161)
        let recovered = try assembler.receive(frames[1], now: 161)
        precondition(recovered != nil)
        expectFailure { _ = try TransportFraming.frames(Data(repeating: 1, count: TransportFraming.maximumMessageBytes + 1), identifier: 1) }
        print("transport_lease_replay_expiry_recovery_and_framing_passed")
    }

    static func expectFailure(_ operation: () throws -> Void) {
        do { try operation(); preconditionFailure("操作必须被拒绝") } catch { }
    }
}
