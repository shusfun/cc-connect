import AppKit
import Combine
import CryptoKit
import Security

@MainActor
final class DeviceAccessService: ObservableObject {
    static let shared = DeviceAccessService()
    @Published var status = "未登录"
    @Published var errorMessage = ""
    @Published var isActivated = false
    @Published var isActivating = false
    @Published var pendingPhones: [[String: String]] = []
    @Published var remark = ""
    private var stored: [String: Any] = [:]
    private var activationTask: Task<Void, Never>?
    private let service = "cn.syggu.remodex.device-access"

    private init() {
        do {
            var value: CFTypeRef?
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "identity", kSecReturnData as String: true]
            let result = SecItemCopyMatching(query as CFDictionary, &value)
            if result == errSecSuccess, let data = value as? Data {
                stored = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            } else if result != errSecItemNotFound { throw failure("无法读取设备 Keychain（\(result)）") }
            isActivated = stored["credential"] != nil
            status = isActivated ? "已登录并激活" : "未登录"
        } catch { errorMessage = error.localizedDescription }
    }
    private func failure(_ message: String) -> NSError { NSError(domain: "RemodexAccess", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    private func persist() throws {
        let data = try JSONSerialization.data(withJSONObject: stored, options: [.sortedKeys])
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "identity"]
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecItemNotFound {
            var insertion = query
            insertion[kSecValueData as String] = data
            insertion[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let result = SecItemAdd(insertion as CFDictionary, nil)
            if result != errSecSuccess { throw failure("无法保存设备 Keychain（\(result)）") }
        } else if update != errSecSuccess { throw failure("无法更新设备 Keychain（\(update)）") }
    }
    private func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func origin(_ relay: String) throws -> URL {
        guard var parts = URLComponents(string: relay), parts.scheme == "wss", parts.user == nil, parts.password == nil, parts.host != nil else { throw failure("请输入有效的 wss:// Relay 地址") }
        parts.scheme = "https"; parts.path = ""; parts.query = nil; parts.fragment = nil
        guard let url = parts.url else { throw failure("Relay 地址无效") }; return url
    }
    func request(_ path: String, body: [String: Any] = [:], token: String? = nil) async throws -> Any {
        guard let relay = stored["relay"] as? String, let raw = stored["privateKey"] as? String, let keyData = Data(base64Encoded: raw), let publicKey = stored["publicKey"] as? String else { throw failure("请先发起设备激活") }
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: keyData)
        let credential = stored["credential"] as? [String: Any]
        let accessToken = token ?? credential?["token"] as? String ?? ""
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
        let timestamp = String(Int64(Date().timeIntervalSince1970 * 1000))
        let nonce = UUID().uuidString + UUID().uuidString
        let transcript = ["remodex-access-v1", "POST", path, sha(data), timestamp, nonce, sha(Data(accessToken.utf8))].joined(separator: "\n")
        var request = URLRequest(url: try origin(relay).appendingPathComponent(String(path.dropFirst())))
        request.httpMethod = "POST"; request.httpBody = data; request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(publicKey, forHTTPHeaderField: "x-remodex-key")
        request.setValue(timestamp, forHTTPHeaderField: "x-remodex-time")
        request.setValue(nonce, forHTTPHeaderField: "x-remodex-nonce")
        request.setValue(try privateKey.signature(for: Data(transcript.utf8)).base64EncodedString(), forHTTPHeaderField: "x-remodex-signature")
        let (responseData, response) = try await URLSession.shared.data(for: request)
        let result = try JSONSerialization.jsonObject(with: responseData)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let code = (result as? [String: Any])?["code"] as? String ?? "request_failed"
            throw NSError(domain: "RemodexAccess", code: (response as? HTTPURLResponse)?.statusCode ?? 0, userInfo: [NSLocalizedDescriptionKey: "操作未完成：\(code)", "accessCode": code])
        }
        return result
    }
    func activate(relay: String) {
        guard !isActivating, !isActivated else { return }
        activationTask = Task {
            isActivating = true; errorMessage = ""
            defer { isActivating = false }
            do {
                _ = try origin(relay)
                if stored["privateKey"] == nil {
                    let key = Curve25519.Signing.PrivateKey()
                    stored["privateKey"] = key.rawRepresentation.base64EncodedString()
                    stored["publicKey"] = key.publicKey.rawRepresentation.base64EncodedString()
                }
                stored["relay"] = relay
                try persist()
                guard let key = stored["publicKey"] as? String,
                      let pending = try await request("/v1/access/activation/start", body: ["publicKey": key, "platform": "macos", "systemName": Host.current().localizedName ?? "macOS"], token: "") as? [String: Any],
                      let id = pending["id"] as? String, let token = pending["token"] as? String,
                      let link = pending["approvalURL"] as? String, let url = URL(string: link) else { throw failure("激活响应无效") }
                status = "请在浏览器核对：\(pending["code"] as? String ?? "")"
                NSWorkspace.shared.open(url)
                for _ in 0..<100 {
                    try Task.checkCancellation()
                    do {
                        let credential = try await request("/v1/access/activation/redeem", body: ["id": id, "token": token, "publicKey": key], token: token)
                        stored["credential"] = credential
                        try persist(); isActivated = true; status = "已登录并激活"
                        await refresh(); return
                    } catch let error as NSError where error.userInfo["accessCode"] as? String == "approval_pending" { }
                    try await Task.sleep(for: .seconds(3))
                }
                throw failure("激活请求已过期，请重新发起")
            } catch { errorMessage = error.localizedDescription }
        }
    }
    func bootstrap(relay: String) throws -> Data {
        guard isActivated, stored["relay"] as? String == relay else { throw failure("请先使用 GitHub 激活当前 Relay 的设备") }
        var data = try JSONSerialization.data(withJSONObject: stored, options: [.sortedKeys]); data.append(10); return data
    }
    func refresh() async {
        guard isActivated else { return }
        do {
            guard let result = try await request("/v1/access/device") as? [String: Any], let device = result["device"] as? [String: Any] else { throw failure("设备状态响应无效") }
            var credential = stored["credential"] as? [String: Any] ?? [:]; credential["device"] = device; stored["credential"] = credential
            remark = device["remark"] as? String ?? ""; try persist()
            let phones = try await request("/v1/access/pairing/pending") as? [[String: Any]] ?? []
            pendingPhones = phones.compactMap { row in guard let id = row["id"] as? String, let key = row["public_key"] as? String else { return nil }; return ["id": id, "key": key] }
        } catch { errorMessage = error.localizedDescription }
    }
    func approvePhone(id: String, replace: Bool) async {
        do {
            _ = try await request("/v1/access/pairing/approve", body: ["id": id, "replace": replace])
            if let relay = stored["relay"] as? String { try await BridgeControlService.shared.restartBridge(relayOverride: relay) }
            await refresh()
        }
        catch { errorMessage = error.localizedDescription }
    }
    func saveRemark(_ value: String) async {
        do {
            let credential = stored["credential"] as? [String: Any]; let device = credential?["device"] as? [String: Any]
            guard let revision = device?["revision"] as? Int else { throw failure("请先刷新设备状态") }
            _ = try await request("/v1/access/device/remark", body: ["remark": value, "revision": revision]); await refresh()
        } catch { errorMessage = error.localizedDescription }
    }
    func logout() async {
        activationTask?.cancel()
        await BridgeControlService.shared.stopBridge()
        let credential = stored["credential"] as? [String: Any]
        let revokeToken = credential?["revocationToken"] as? String
        stored.removeValue(forKey: "credential")
        isActivated = false; pendingPhones = []; status = "本机已退出"
        do {
            stored["pendingRevocation"] = revokeToken
            try persist()
            if let revokeToken { _ = try await request("/v1/access/revoke", body: ["revocationToken": revokeToken], token: "") }
            stored.removeValue(forKey: "pendingRevocation"); try persist()
        } catch { errorMessage = "本机已退出，远端撤销未完成。请在后台撤销设备。" }
    }
}
