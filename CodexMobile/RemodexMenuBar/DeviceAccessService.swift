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
    @Published var isLoggingOut = false
    @Published var pendingPhones: [[String: String]] = []
    @Published var remark = ""
    private var stored: [String: Any] = [:]
    private var activationTask: Task<Void, Never>?
    private var activationOperation: UUID?
    private var identityEpoch = UUID()
    private var refreshing = false
    private let service = "cn.syggu.remodex.device-access"

    private init() {
        do {
            var value: CFTypeRef?
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "identity", kSecReturnData as String: true]
            let result = SecItemCopyMatching(query as CFDictionary, &value)
            if result == errSecSuccess, let data = value as? Data {
                stored = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            } else if result != errSecItemNotFound { throw failure("无法读取设备 Keychain（\(result)）") }
            isActivated = (stored["credential"] as? [String: Any])?["token"] as? String != nil
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
    func request(_ path: String, body: [String: Any] = [:], token: String? = nil, operation: UUID? = nil) async throws -> Any {
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
        if let operation { request.setValue(operation.uuidString, forHTTPHeaderField: "x-remodex-operation-id") }
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(publicKey, forHTTPHeaderField: "x-remodex-key")
        request.setValue(timestamp, forHTTPHeaderField: "x-remodex-time")
        request.setValue(nonce, forHTTPHeaderField: "x-remodex-nonce")
        request.setValue(try privateKey.signature(for: Data(transcript.utf8)).base64EncodedString(), forHTTPHeaderField: "x-remodex-signature")
        let started = Date()
        let (responseData, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        let requestID = http?.value(forHTTPHeaderField: "x-remodex-request-id").flatMap(UUID.init(uuidString:))
        let result = try JSONSerialization.jsonObject(with: responseData)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let code = (result as? [String: Any])?["code"] as? String ?? "request_failed"
            if code != "approval_pending" && code != "rate_limited" {
                BridgeControlService.shared.record("access_request_failed", operation: operation, stage: "http", code: code, requestID: requestID, httpStatus: http?.statusCode, durationMs: Int(Date().timeIntervalSince(started) * 1000))
            }
            let messages = ["request_expired": "激活申请已过期，请重新发起", "request_consumed": "凭据已兑换，若本机未保存成功，请重新发起激活", "device_limit_reached": "设备数量已达上限，请联系管理员", "account_not_enabled": "账号尚未启用，请等待审核", "device_owned_by_other_account": "设备属于其他账号，请先由原账号释放"]
            throw NSError(domain: "RemodexAccess", code: http?.statusCode ?? 0, userInfo: [NSLocalizedDescriptionKey: (messages[code] ?? "操作未完成：\(code)") + (requestID.map { "（诊断编号：\($0.uuidString)）" } ?? ""), "accessCode": code, "retryAfter": Double(http?.value(forHTTPHeaderField: "retry-after") ?? "") ?? 3])
        }
        if let operation { BridgeControlService.shared.record("access_request_completed", operation: operation, stage: "http", requestID: requestID, httpStatus: http?.statusCode, durationMs: Int(Date().timeIntervalSince(started) * 1000)) }
        return result
    }
    func activate(relay: String) {
        guard !isActivating, !isActivated, !isLoggingOut else { return }
        identityEpoch = UUID()
        let epoch = identityEpoch
        let operation = UUID()
        activationOperation = operation
        isActivating = true
        BridgeControlService.shared.record("activation_started", operation: operation, stage: "creating")
        activationTask = Task {
            isActivating = true; errorMessage = ""
            defer { if identityEpoch == epoch { isActivating = false } }
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
                      let pending = try await request("/v1/access/activation/start", body: ["publicKey": key, "platform": "macos", "systemName": Host.current().localizedName ?? "macOS"], token: "", operation: operation) as? [String: Any],
                      let id = pending["id"] as? String, let token = pending["token"] as? String,
                      let expiresAt = pending["expiresAt"] as? Double, let serverTime = pending["serverTime"] as? Double,
                      let link = pending["approvalURL"] as? String, let url = URL(string: link) else { throw failure("激活响应无效") }
                guard identityEpoch == epoch else { return }
                let deadline = ActivationPolicy.deadline(expiresAt: expiresAt, serverTime: serverTime, now: Date())
                BridgeControlService.shared.record("activation_created", operation: operation, stage: "browser")
                status = "请在浏览器核对：\(pending["code"] as? String ?? "")"
                guard NSWorkspace.shared.open(url) else { throw failure("无法打开浏览器，请检查默认浏览器设置") }
                BridgeControlService.shared.record("activation_browser_opened", operation: operation, stage: "waiting")
                while Date() < deadline {
                    try Task.checkCancellation()
                    var retryAfter: Double?
                    do {
                        guard let credential = try await request("/v1/access/activation/redeem", body: ["id": id, "token": token, "publicKey": key], token: token, operation: operation) as? [String: Any],
                              let credentialToken = credential["token"] as? String, !credentialToken.isEmpty, credential["kind"] as? String == "host" else { throw failure("设备凭据响应无效，请重新发起激活") }
                        guard identityEpoch == epoch else { return }
                        BridgeControlService.shared.record("activation_redeemed", operation: operation, stage: "keychain")
                        stored["credential"] = credential
                        do {
                            try ActivationPolicy.commit(save: { try self.persist() }, publish: {
                                BridgeControlService.shared.record("activation_keychain_saved", operation: operation, stage: "publishing")
                                self.isActivated = true; self.status = "已登录并激活"; self.errorMessage = ""
                            })
                        } catch {
                            stored.removeValue(forKey: "credential")
                            BridgeControlService.shared.record("activation_keychain_failed", operation: operation, stage: "keychain", code: "keychain_save_failed")
                            throw failure("设备已批准，但凭据未能保存到 Keychain。请重新发起激活。")
                        }
                        BridgeControlService.shared.record("activation_published", operation: operation, stage: "complete")
                        await refresh(); return
                    } catch let error as NSError where ["approval_pending", "rate_limited"].contains(error.userInfo["accessCode"] as? String ?? "") {
                        if error.userInfo["accessCode"] as? String == "rate_limited" { retryAfter = error.userInfo["retryAfter"] as? Double }
                    }
                    try await Task.sleep(for: .seconds(ActivationPolicy.delay(retryAfter: retryAfter, remaining: deadline.timeIntervalSinceNow)))
                }
                BridgeControlService.shared.record("activation_timed_out", operation: operation, stage: "waiting", code: "request_expired")
                throw failure("激活请求已过期，请重新发起")
            } catch is CancellationError { BridgeControlService.shared.record("activation_cancelled", operation: operation, stage: "cancelled") }
            catch { if identityEpoch == epoch { errorMessage = error.localizedDescription; status = "激活未完成"; BridgeControlService.shared.record("activation_failed", operation: operation, stage: "failed", code: (error as NSError).userInfo["accessCode"] as? String ?? "activation_failed") } }
        }
    }
    func cancelActivation() {
        BridgeControlService.shared.record("activation_cancelled", operation: activationOperation, stage: "cancelled")
        activationTask?.cancel(); identityEpoch = UUID(); isActivating = false; status = "已取消激活"; errorMessage = ""
    }
    func bootstrap(relay: String) throws -> Data {
        guard isActivated, stored["relay"] as? String == relay else { throw failure("请先使用 GitHub 激活当前 Relay 的设备") }
        var data = try JSONSerialization.data(withJSONObject: stored, options: [.sortedKeys]); data.append(10); return data
    }
    func refresh() async {
        guard isActivated, !refreshing else { return }
        refreshing = true
        let epoch = identityEpoch
        defer { refreshing = false }
        do {
            guard let result = try await request("/v1/access/device") as? [String: Any], let device = result["device"] as? [String: Any] else { throw failure("设备状态响应无效") }
            guard identityEpoch == epoch, isActivated else { return }
            var credential = stored["credential"] as? [String: Any] ?? [:]; credential["device"] = device; stored["credential"] = credential
            remark = device["remark"] as? String ?? ""; try persist()
            let phones = try await request("/v1/access/pairing/pending") as? [[String: Any]] ?? []
            guard identityEpoch == epoch, isActivated else { return }
            pendingPhones = phones.compactMap { row in guard let id = row["id"] as? String, let key = row["public_key"] as? String else { return nil }; return ["id": id, "key": key] }
        } catch { if identityEpoch == epoch { errorMessage = error.localizedDescription } }
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
        guard !isLoggingOut else { return }
        isLoggingOut = true
        defer { isLoggingOut = false }
        identityEpoch = UUID()
        let epoch = identityEpoch
        activationTask?.cancel()
        isActivating = false
        let credential = stored["credential"] as? [String: Any]
        let revokeToken = credential?["revocationToken"] as? String
        stored.removeValue(forKey: "credential")
        isActivated = false; pendingPhones = []; status = "本机已退出"
        await BridgeControlService.shared.stopBridge()
        do {
            stored["pendingRevocation"] = revokeToken
            try persist()
            if let revokeToken { _ = try await request("/v1/access/revoke", body: ["revocationToken": revokeToken], token: "") }
            guard identityEpoch == epoch else { return }
            stored.removeValue(forKey: "pendingRevocation"); try persist()
        } catch { errorMessage = "本机已退出，远端撤销未完成。请在后台撤销设备。" }
    }
}
