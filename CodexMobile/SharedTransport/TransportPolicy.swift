import Foundation

enum TransportClock {
    private static let origin = ContinuousClock.now
    static var now: TimeInterval {
        let elapsed = origin.duration(to: ContinuousClock.now).components
        return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1_000_000_000_000_000_000
    }
}

enum TransportFailure: Error, Equatable {
    case invalidLease
    case invalidFrame
    case messageTooLarge
    case messageExpired
    case unavailable
    case backpressure
    case cancelled
}

final class TransportBudget: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumBytes: Int
    private let maximumCount: Int
    private var bytes = 0
    private var count = 0

    init(bytes: Int, count: Int) { maximumBytes = bytes; maximumCount = count }

    func acquire(_ size: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard size >= 0, size <= maximumBytes - bytes, count < maximumCount else { return false }
        bytes += size
        count += 1
        return true
    }

    func release(_ size: Int) {
        lock.lock()
        defer { lock.unlock() }
        bytes -= size
        count -= 1
        precondition(bytes >= 0 && count >= 0)
    }
}

struct TransportLease {
    let generation: String
    private let serverTime: Double
    private let anchor: TimeInterval
    private(set) var sequence: UInt64 = 0
    private(set) var deadline: TimeInterval = 0

    init(generation: String, serverTime: Double, requestStartedAt: TimeInterval) {
        self.generation = generation
        self.serverTime = serverTime
        anchor = requestStartedAt
    }

    mutating func accept(generation: String, sequence: UInt64, expiresAt: Double, now: TimeInterval) throws {
        let remaining = (expiresAt - serverTime) / 1000 - (now - anchor)
        guard generation == self.generation, sequence > self.sequence,
              remaining.isFinite, remaining > 0, remaining <= 60, now >= anchor else {
            throw TransportFailure.invalidLease
        }
        self.sequence = sequence
        deadline = now + remaining
    }

    func isValid(at now: TimeInterval) -> Bool { sequence > 0 && now >= anchor && now < deadline }
    mutating func revoke() { deadline = 0 }
}

struct BridgeRecoveryPolicy {
    private var attempts: [TimeInterval] = []
    private var cooldownUntil: TimeInterval = 0
    private var healthySince: TimeInterval?
    private(set) var failures = 0

    mutating func delay(now: TimeInterval, retryAfter: TimeInterval = 0, jitter: Double = 0) -> TimeInterval {
        attempts.removeAll { now - $0 >= 300 }
        if now < cooldownUntil { return cooldownUntil - now }
        if attempts.count >= 5 {
            cooldownUntil = now + 300
            return 300
        }
        let base = min(30, pow(2, Double(min(failures, 5))))
        return max(retryAfter, min(30, base * (1 + min(1, max(0, jitter)) * 0.2)))
    }

    mutating func recordAttempt(at now: TimeInterval) {
        attempts.append(now)
        failures += 1
        healthySince = nil
    }

    mutating func observeHealthy(at now: TimeInterval) {
        if healthySince == nil { healthySince = now }
        if let healthySince, now - healthySince >= 300 { reset() }
    }

    mutating func reset() {
        attempts = []
        cooldownUntil = 0
        healthySince = nil
        failures = 0
    }
}

enum TransportFraming {
    static let maximumMessageBytes = 16 * 1024 * 1024
    static let maximumFrameBytes = 16 * 1024
    static let headerBytes = 16

    static func peerFrameLimit(sdp: String) throws -> Int {
        let attributes = sdp.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.hasPrefix("a=max-message-size:") }
        guard attributes.count <= 1 else { throw TransportFailure.invalidFrame }
        guard let attribute = attributes.first else { return maximumFrameBytes }
        guard let value = UInt64(attribute.dropFirst("a=max-message-size:".count)) else { throw TransportFailure.invalidFrame }
        let limit = value == 0 ? maximumFrameBytes : Int(min(UInt64(maximumFrameBytes), value))
        guard limit > headerBytes else { throw TransportFailure.invalidFrame }
        return limit
    }

    static func frame(_ message: Data, identifier: UInt32, offset: Int, negotiatedLimit: Int = maximumFrameBytes) throws -> Data {
        guard !message.isEmpty, message.count <= maximumMessageBytes else { throw TransportFailure.messageTooLarge }
        let payloadLimit = min(maximumFrameBytes, negotiatedLimit) - headerBytes
        guard payloadLimit > 0, offset >= 0, offset < message.count else { throw TransportFailure.invalidFrame }
        var frame = Data([82, 68, 88, 49])
        for value in [identifier, UInt32(message.count), UInt32(offset)] {
            var encoded = value.bigEndian
            withUnsafeBytes(of: &encoded) { frame.append(contentsOf: $0) }
        }
        frame.append(message.subdata(in: offset..<min(message.count, offset + payloadLimit)))
        return frame
    }

    static func frames(_ message: Data, identifier: UInt32, negotiatedLimit: Int = maximumFrameBytes) throws -> [Data] {
        guard !message.isEmpty, message.count <= maximumMessageBytes else { throw TransportFailure.messageTooLarge }
        let payloadLimit = min(maximumFrameBytes, negotiatedLimit) - headerBytes
        guard payloadLimit > 0 else { throw TransportFailure.invalidFrame }
        return try stride(from: 0, to: message.count, by: payloadLimit).map { offset in
            try frame(message, identifier: identifier, offset: offset, negotiatedLimit: negotiatedLimit)
        }
    }
}

struct TransportReassembler {
    private var identifier: UInt32?
    private var expectedBytes = 0
    private var buffer = Data()
    private var startedAt: TimeInterval = 0

    mutating func expire(at now: TimeInterval) throws {
        if identifier != nil, now < startedAt || now - startedAt >= 60 {
            reset()
            throw TransportFailure.messageExpired
        }
    }

    mutating func receive(_ frame: Data, now: TimeInterval) throws -> Data? {
        do {
            guard frame.count > TransportFraming.headerBytes,
                  frame.count <= TransportFraming.maximumFrameBytes else { throw TransportFailure.invalidFrame }
            let header = Array(frame.prefix(16))
            guard Array(header.prefix(4)) == [82, 68, 88, 49] else { throw TransportFailure.invalidFrame }
            func number(_ offset: Int) -> UInt32 {
                header[offset..<offset + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            }
            let incomingIdentifier = number(4)
            let total = Int(number(8))
            let offset = Int(number(12))
            guard total > 0, total <= TransportFraming.maximumMessageBytes else { throw TransportFailure.messageTooLarge }
            if identifier == nil {
                guard offset == 0 else { throw TransportFailure.invalidFrame }
                identifier = incomingIdentifier
                expectedBytes = total
                startedAt = now
            }
            guard now >= startedAt, now - startedAt < 60 else { throw TransportFailure.messageExpired }
            guard incomingIdentifier == identifier, total == expectedBytes, offset == buffer.count,
                  buffer.count + frame.count - 16 <= total else { throw TransportFailure.invalidFrame }
            buffer.append(frame.dropFirst(16))
            guard buffer.count == total else { return nil }
            let message = buffer
            reset()
            return message
        } catch {
            reset()
            throw error
        }
    }

    mutating func reset() {
        identifier = nil
        expectedBytes = 0
        buffer = Data()
        startedAt = 0
    }
}
