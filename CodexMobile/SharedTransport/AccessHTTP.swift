import CryptoKit
import Foundation

struct AccessIdentity {
    let origin: URL
    let token: String
    private let key: Curve25519.Signing.PrivateKey

    init(origin: URL, token: String, privateKey: Data, allowLoopbackForTesting: Bool = false) throws {
        guard let parts = URLComponents(url: origin, resolvingAgainstBaseURL: false),
              parts.scheme == "https" || (allowLoopbackForTesting && parts.scheme == "http" && parts.host == "127.0.0.1"),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/", parts.host != nil, !token.isEmpty else { throw TransportFailure.unavailable }
        self.origin = origin
        self.token = token
        key = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKey)
    }

    func headers(method: String, path: String, body: Data = Data()) throws -> [String: String] {
        func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        let timestamp = String(Int64(Date().timeIntervalSince1970 * 1000))
        let nonce = UUID().uuidString + UUID().uuidString
        let transcript = ["remodex-access-v1", method, path, hash(body), timestamp, nonce, hash(Data(token.utf8))].joined(separator: "\n")
        return ["Authorization": "Bearer \(token)", "x-remodex-key": key.publicKey.rawRepresentation.base64EncodedString(),
                "x-remodex-time": timestamp, "x-remodex-nonce": nonce,
                "x-remodex-signature": try key.signature(for: Data(transcript.utf8)).base64EncodedString()]
    }
}

struct AccessHTTPFailure: Error {
    let status: Int
    let code: String
    let retryAfter: TimeInterval

    var terminal: Bool { [400, 401, 403, 404, 410, 426].contains(status) }
    static let domain = "Remodex.AccessHTTP"

    static func retryAfter(_ raw: String?, now: Date = Date()) -> TimeInterval {
        guard let raw else { return 0 }
        if let seconds = Double(raw), seconds.isFinite { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        return max(0, formatter.date(from: raw)?.timeIntervalSince(now) ?? 0)
    }

    static func from(_ error: Error) -> AccessHTTPFailure {
        let native = error as NSError
        if native.domain == domain {
            return AccessHTTPFailure(status: native.code, code: native.userInfo["code"] as? String ?? "access_failed",
                                     retryAfter: native.userInfo["retryAfter"] as? Double ?? 0)
        }
        return AccessHTTPFailure(status: 0, code: "network_unavailable", retryAfter: 0)
    }
}

final class AccessHTTP: @unchecked Sendable {
    private let identity: AccessIdentity
    private let session: URLSession

    init(identity: AccessIdentity) {
        self.identity = identity
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AccessHTTPProtocol.self]
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    deinit { session.invalidateAndCancel() }
    func cancel() { session.invalidateAndCancel() }

    func post(_ endpoint: String, body: [String: Any]) async throws -> [String: Any] {
        guard ["presence", "connect", "signal", "session"].contains(endpoint) else { throw TransportFailure.invalidFrame }
        let path = "/v1/access/\(endpoint)"
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
        guard data.count <= 70_000 else { throw TransportFailure.messageTooLarge }
        var request = URLRequest(url: identity.origin.appendingPathComponent(String(path.dropFirst())))
        request.httpMethod = "POST"
        request.httpBody = data
        request.timeoutInterval = 15
        request.allHTTPHeaderFields = try identity.headers(method: "POST", path: path, body: data)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let bytes: Data
        do { (bytes, _) = try await session.data(for: request) }
        catch { if Task.isCancelled { throw CancellationError() }; throw AccessHTTPFailure.from(error) }
        guard let result = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw TransportFailure.invalidFrame }
        return result
    }
}

final class AccessHTTPProtocol: URLProtocol, URLSessionDataDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "remodex.access.http")
    private var session: URLSession?
    private var upstreamTask: URLSessionDataTask?
    private var stopped = false
    private var eventBytes = 0
    private var lineBytes = 0
    private var isStream = false
    private var failedResponse: (status: Int, retryAfter: TimeInterval)?
    private var failedBody = Data()

    override class func canInit(with request: URLRequest) -> Bool { ["http", "https"].contains(request.url?.scheme ?? "") }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        queue.async {
            guard !self.stopped else { return }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = []
            configuration.httpShouldSetCookies = false
            configuration.urlCache = nil
            let delegates = OperationQueue()
            delegates.maxConcurrentOperationCount = 1
            delegates.underlyingQueue = self.queue
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegates)
            self.session = session
            self.upstreamTask = session.dataTask(with: self.request)
            self.upstreamTask?.resume()
        }
    }

    override func stopLoading() {
        queue.async { self.finish() }
    }

    private func finish() {
        guard !stopped else { return }
        stopped = true
        upstreamTask?.cancel()
        upstreamTask = nil
        session?.invalidateAndCancel()
        session = nil
    }

    private func fail(status: Int, code: String, retryAfter: TimeInterval = 0) {
        guard !stopped else { return }
        client?.urlProtocol(self, didFailWithError: NSError(domain: AccessHTTPFailure.domain, code: status,
                                                          userInfo: ["code": code, "retryAfter": retryAfter]))
        finish()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
        fail(status: 400, code: "redirect_rejected")
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard !stopped, let http = response as? HTTPURLResponse else { completionHandler(.cancel); return }
        guard http.statusCode == 200 else {
            failedResponse = (http.statusCode, AccessHTTPFailure.retryAfter(http.value(forHTTPHeaderField: "Retry-After")))
            completionHandler(.allow)
            return
        }
        isStream = request.url?.path == "/v1/access/events"
        let mime = http.mimeType?.lowercased()
        guard mime == (isStream ? "text/event-stream" : "application/json") else {
            completionHandler(.cancel)
            fail(status: 400, code: "invalid_content_type")
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !stopped else { return }
        if let failedResponse {
            guard failedBody.count + data.count <= 8192 else {
                fail(status: failedResponse.status, code: "access_failed", retryAfter: failedResponse.retryAfter)
                return
            }
            failedBody.append(data)
            return
        }
        for byte in data {
            eventBytes += 1
            if eventBytes > 70_000 { fail(status: 400, code: "event_too_large"); return }
            if isStream, byte == 10 {
                if lineBytes == 0 { eventBytes = 0 }
                lineBytes = 0
            } else if byte != 13 { lineBytes += 1 }
        }
        client?.urlProtocol(self, didLoad: data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !stopped else { return }
        if let failedResponse {
            let body = (try? JSONSerialization.jsonObject(with: failedBody)) as? [String: Any]
            let candidate = body?["code"] as? String ?? "access_failed"
            let code = candidate.range(of: "^[a-z][a-z0-9_]{0,79}$", options: .regularExpression) == nil ? "access_failed" : candidate
            fail(status: failedResponse.status, code: code, retryAfter: failedResponse.retryAfter)
            return
        }
        if let error { client?.urlProtocol(self, didFailWithError: error) }
        else { client?.urlProtocolDidFinishLoading(self) }
        finish()
    }
}
