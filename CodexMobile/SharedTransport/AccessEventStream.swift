import Foundation
import LDSwiftEventSource
import os.log

enum AccessStreamUpdate {
    case event(type: String, body: [String: Any], requestStartedAt: TimeInterval)
    case recovering(delay: TimeInterval)
    case blocked(code: String)
}

final class AccessEventStream: @unchecked Sendable {
    private let queue = DispatchQueue(label: "remodex.access.events")
    private let identity: AccessIdentity
    private let receive: (AccessStreamUpdate) -> Void
    private var source: EventSource?
    private var generation: UUID?
    private var retry: DispatchWorkItem?
    private var stopped = true
    private var failures = 0
    private var openedAt: TimeInterval?
    private var startedAt: TimeInterval = 0
    private let eventBudget = TransportBudget(bytes: 262_144, count: 16)

    init(identity: AccessIdentity, receive: @escaping (AccessStreamUpdate) -> Void) {
        self.identity = identity
        self.receive = receive
    }

    deinit { retry?.cancel(); source?.stop() }

    func start() {
        queue.async {
            guard self.stopped else { return }
            self.stopped = false
            self.failures = 0
            self.connect()
        }
    }

    func stop() {
        queue.async {
            self.stopped = true
            self.generation = nil
            self.retry?.cancel()
            self.retry = nil
            self.source?.stop()
            self.source = nil
        }
    }

    private func connect() {
        guard !stopped else { return }
        let generation = UUID()
        self.generation = generation
        startedAt = TransportClock.now
        openedAt = nil
        let handler = AccessEventHandler(owner: self, generation: generation)
        let path = "/v1/access/events"
        var config = EventSource.Config(handler: handler, url: identity.origin.appendingPathComponent(String(path.dropFirst())))
        config.logger = .disabled
        config.idleTimeout = 45
        config.reconnectTime = 1
        config.maxReconnectTime = 30
        config.headerTransform = { [identity, weak self] previous in
            do { return try previous.merging(identity.headers(method: "GET", path: path)) { _, signed in signed } }
            catch {
                self?.disconnected(generation, failure: AccessHTTPFailure(status: 400, code: "invalid_device_key", retryAfter: 0))
                return [:]
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AccessHTTPProtocol.self]
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        config.urlSessionConfiguration = configuration
        config.connectionErrorHandler = { [weak self] error in
            self?.disconnected(generation, failure: AccessHTTPFailure.from(error))
            return .shutdown
        }
        source = EventSource(config: config)
        source?.start()
    }

    fileprivate func disconnected(_ generation: UUID, failure: AccessHTTPFailure = AccessHTTPFailure(status: 0, code: "stream_closed", retryAfter: 0)) {
        queue.async {
            guard !self.stopped, self.generation == generation else { return }
            self.generation = nil
            self.source?.stop()
            self.source = nil
            if failure.terminal {
                self.stopped = true
                self.receive(.blocked(code: failure.code))
                return
            }
            if let openedAt = self.openedAt, TransportClock.now - openedAt >= 300 { self.failures = 0 }
            let delay = max(failure.retryAfter, min(30, pow(2, Double(min(self.failures, 5))) * Double.random(in: 1...1.2)))
            self.failures = min(6, self.failures + 1)
            self.receive(.recovering(delay: delay))
            self.scheduleRetry(after: delay)
        }
    }

    private func scheduleRetry(after delay: TimeInterval) {
        guard !stopped else { return }
        let interval = min(300, delay)
        let retry = DispatchWorkItem { [weak self] in
            guard let self, !self.stopped else { return }
            self.retry = nil
            if delay > interval { self.scheduleRetry(after: delay - interval) }
            else { self.connect() }
        }
        self.retry = retry
        queue.asyncAfter(deadline: .now() + interval, execute: retry)
    }

    fileprivate func opened(_ generation: UUID) {
        queue.async { if self.generation == generation { self.openedAt = TransportClock.now } }
    }

    fileprivate func message(_ generation: UUID, type: String, event: MessageEvent) {
        let size = event.data.utf8.count
        guard eventBudget.acquire(size) else {
            disconnected(generation, failure: AccessHTTPFailure(status: 400, code: "event_capacity", retryAfter: 0))
            return
        }
        queue.async {
            defer { self.eventBudget.release(size) }
            guard !self.stopped, self.generation == generation else { return }
            guard event.data.utf8.count <= 70_000, let bytes = event.data.data(using: .utf8),
                  let body = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
                self.disconnected(generation, failure: AccessHTTPFailure(status: 400, code: "invalid_event", retryAfter: 0))
                return
            }
            self.receive(.event(type: type, body: body, requestStartedAt: self.startedAt))
        }
    }
}

private final class AccessEventHandler: EventHandler {
    weak var owner: AccessEventStream?
    let generation: UUID
    init(owner: AccessEventStream, generation: UUID) { self.owner = owner; self.generation = generation }
    func onOpened() { owner?.opened(generation) }
    func onClosed() { owner?.disconnected(generation) }
    func onMessage(eventType: String, messageEvent: MessageEvent) { owner?.message(generation, type: eventType, event: messageEvent) }
    func onComment(comment: String) { }
    func onError(error: Error) { owner?.disconnected(generation, failure: AccessHTTPFailure.from(error)) }
}
