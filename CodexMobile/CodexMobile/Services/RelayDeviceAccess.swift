import CryptoKit
import Foundation
import Security

@MainActor
enum RelayDeviceAccess {
    private static let session = URLSession(configuration: .ephemeral, delegate: NoRelayRedirects(), delegateQueue: nil)
    struct Credential: Codable {
        let token: String
        let revocationToken: String
        let deviceId: String
        let phoneId: String
        let accountId: String
        let instanceId: String
    }
    static func origin(_ relay: String) throws -> URL {
        guard var parts = URLComponents(string: relay), ["https", "wss"].contains(parts.scheme), parts.host != nil, parts.user == nil, parts.password == nil else { throw CodexServiceError.invalidInput(L10n.string("需要有效的 HTTPS/WSS 服务地址")) }
        parts.scheme = "https"; parts.path = ""; parts.query = nil; parts.fragment = nil
        guard let result = parts.url else { throw CodexServiceError.invalidInput(L10n.string("服务地址无效")) }; return result
    }
    static func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func sessionURL(relay: String, sessionId: String) throws -> String {
        guard sessionId.range(of: "^[a-zA-Z0-9-]{1,100}$", options: .regularExpression) != nil else { throw CodexServiceError.invalidResponse(L10n.string("设备会话无效")) }
        var url = URLComponents(url: try origin(relay), resolvingAgainstBaseURL: false)!
        url.scheme = "wss"; url.path = "/relay/\(sessionId)"
        return url.url!.absoluteString
    }
    static func preview(_ code: CompactPairingCode) async throws -> CodexPairingQRPayload {
        let url = try origin(code.relay).appendingPathComponent("v1/access/pairing/preview")
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["invitation": code.invitation])
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw accessFailure(data: data, response: response)
        }
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let device = value["device"] as? [String: Any], device["public_key"] as? String == code.publicKey,
              let id = device["id"] as? String, let account = value["accountId"] as? String, let instance = value["instanceId"] as? String,
              let expires = value["expiresAt"] as? Int64, let serverTime = value["serverTime"] as? Int64, expires > serverTime
        else { throw CodexServiceError.invalidResponse(L10n.string("设备身份不匹配，已阻止配对。请重新核对电脑二维码。")) }
        // 预览尚无会话权限；sessionId 只在授权完成后从 session 接口取得。
        return CodexPairingQRPayload(v: codexPairingQRVersion, relay: code.relay, sessionId: "", macDeviceId: id, macIdentityPublicKey: code.publicKey, expiresAt: expires, displayName: device["remark"] as? String, invitation: code.invitation, accountId: account, instanceId: instance, platform: device["platform"] as? String)
    }
    static func key(_ relay: String, _ deviceId: String) throws -> String { "remodex.access.v1." + sha(Data("\(try origin(relay).absoluteString)|\(deviceId)".utf8)) }
    static func credential(relay: String, deviceId: String) throws -> Credential {
        guard let value: Credential = SecureStore.readCodable(Credential.self, for: try key(relay, deviceId)) else { throw CodexServiceError.invalidInput(L10n.string("请重新扫描设备二维码完成授权")) }; return value
    }
    static func save(_ credential: Credential, relay: String) throws {
        let storageKey = try key(relay, credential.deviceId)
        let data = try JSONEncoder().encode(credential)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Bundle.main.bundleIdentifier ?? "cn.syggu.remodex", kSecAttrAccount as String: storageKey]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var values = query; values[kSecValueData as String] = data; values[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(values as CFDictionary, nil) == errSecSuccess else { throw CodexServiceError.invalidResponse(L10n.string("无法保存手机授权")) }
        } else if status != errSecSuccess { throw CodexServiceError.invalidResponse(L10n.string("无法更新手机授权")) }
    }
    static func headers(url: URL, method: String, data: Data = Data(), token: String, identity: CodexPhoneIdentityState) throws -> [String: String] {
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(base64EncodedOrEmpty: identity.phoneIdentityPrivateKey))
        let timestamp = String(Int64(Date().timeIntervalSince1970 * 1000)); let nonce = UUID().uuidString + UUID().uuidString
        let transcript = ["remodex-access-v1", method, url.path, sha(data), timestamp, nonce, sha(Data(token.utf8))].joined(separator: "\n")
        return [L10n.string("Authorization"): "Bearer \(token)", "x-remodex-key": identity.phoneIdentityPublicKey, "x-remodex-time": timestamp, "x-remodex-nonce": nonce, "x-remodex-signature": try privateKey.signature(for: Data(transcript.utf8)).base64EncodedString()]
    }
    static func request(relay: String, path: String, body: [String: Any] = [:], token: String, identity: CodexPhoneIdentityState) async throws -> Data {
        let url = try origin(relay).appendingPathComponent(String(path.dropFirst()))
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.httpBody = data; request.timeoutInterval = 15
        for (key, value) in try headers(url: url, method: "POST", data: data, token: token, identity: identity) { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (responseData, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw accessFailure(data: responseData, response: response)
        }
        return responseData
    }
    private static func accessFailure(data: Data, response: URLResponse) -> RelayAccessFailure {
        let http = response as? HTTPURLResponse
        let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let rawCode = body?["code"] as? String ?? "request_failed"
        let code = rawCode.range(of: "^[a-z_]{1,64}$", options: .regularExpression) == nil ? "request_failed" : rawCode
        return RelayAccessFailure(code: code, status: http?.statusCode ?? 0, requestID: http?.value(forHTTPHeaderField: "x-remodex-request-id").flatMap(UUID.init(uuidString:)))
    }
    static func pair(_ payload: CodexPairingQRPayload, identity: CodexPhoneIdentityState) async throws -> Credential {
        guard let invitation = payload.invitation, let account = payload.accountId, let instance = payload.instanceId else { throw CodexServiceError.invalidInput(L10n.string("二维码版本不兼容，请更新桌面应用并重新生成")) }
        let accountKey = "remodex.phone.account." + sha(Data(instance.utf8))
        if let existing = SecureStore.readString(for: accountKey), existing != account { throw CodexServiceError.invalidInput(L10n.string("手机已绑定其他账号，请先解除全部配对")) }
        let data = try await request(relay: payload.relay, path: "/v1/access/pairing/claim", body: ["invitation": invitation, "publicKey": identity.phoneIdentityPublicKey], token: "", identity: identity)
        guard let claim = try JSONSerialization.jsonObject(with: data) as? [String: Any], let id = claim["id"] as? String, let token = claim["token"] as? String,
              claim["accountId"] as? String == account, claim["instanceId"] as? String == instance,
              let device = claim["device"] as? [String: Any], device["public_key"] as? String == payload.macIdentityPublicKey,
              device["id"] as? String == payload.macDeviceId else { throw CodexServiceError.invalidResponse(L10n.string("设备身份不匹配")) }
        for _ in 0..<100 {
            try Task.checkCancellation()
            do {
                let response = try await request(relay: payload.relay, path: "/v1/access/pairing/redeem", body: ["id": id, "token": token, "publicKey": identity.phoneIdentityPublicKey], token: token, identity: identity)
                let credential = try JSONDecoder().decode(Credential.self, from: response)
                guard credential.accountId == account, credential.instanceId == instance, credential.deviceId == payload.macDeviceId else { throw CodexServiceError.invalidResponse(L10n.string("设备授权范围不匹配")) }
                try save(credential, relay: payload.relay)
                SecureStore.writeString(account, for: accountKey)
                return credential
            } catch let error as NSError where error.userInfo["accessCode"] as? String == "approval_pending" { }
            try await Task.sleep(for: .seconds(3))
        }
        throw CodexServiceError.invalidInput(L10n.string("配对申请已过期，请重新扫码"))
    }
}

private final class NoRelayRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

extension CodexService {
    func relayAuthorizationHeaders(url: URL) throws -> [String: String] {
        guard let id = normalizedRelayMacDeviceId else { throw CodexServiceError.invalidInput(L10n.string("尚未选择授权设备")) }
        let access = try RelayDeviceAccess.credential(relay: url.absoluteString, deviceId: id)
        return try RelayDeviceAccess.headers(url: url, method: "GET", token: access.token, identity: phoneIdentityState)
    }
    func resolveAuthorizedSession(deviceId: String, relay: String) async throws -> CodexTrustedSessionResolveResponse {
        let access = try RelayDeviceAccess.credential(relay: relay, deviceId: deviceId)
        let data = try await RelayDeviceAccess.request(relay: relay, path: "/v1/access/session", token: access.token, identity: phoneIdentityState)
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any], let session = result["sessionId"] as? String, let device = result["device"] as? [String: Any], let publicKey = device["public_key"] as? String,
              device["id"] as? String == deviceId, result["accountId"] as? String == access.accountId, result["instanceId"] as? String == access.instanceId else { throw CodexServiceError.invalidResponse(L10n.string("设备会话响应无效")) }
        return CodexTrustedSessionResolveResponse(ok: true, macDeviceId: deviceId, macIdentityPublicKey: publicKey, displayName: device["remark"] as? String, sessionId: session)
    }
}
