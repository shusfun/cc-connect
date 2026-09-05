import Foundation

/// 服务端错误只保留稳定错误码与经过校验的诊断 ID，不展示原始响应正文。
nonisolated struct RelayAccessFailure: LocalizedError, CustomNSError {
    let code: String
    let status: Int
    let requestID: UUID?
    static var errorDomain: String { "RemodexAccess" }
    var errorCode: Int { status }
    var errorUserInfo: [String: Any] { ["accessCode": code, NSLocalizedDescriptionKey: errorDescription ?? ""] }
    var errorDescription: String? {
        let key: String
        switch code {
        case "approval_pending": key = "Waiting for device approval"
        case "device_offline": key = "Device offline. Open the desktop app and reconnect."
        case "invitation_expired", "invitation_consumed", "request_expired", "request_consumed": key = "配对码已过期或已使用，请在电脑上刷新。"
        case "credential_invalid", "access_revoked", "device_revoked", "pairing_revoked": key = "Access was revoked. Activate and pair the device again."
        case "account_pending": key = "Your account is awaiting administrator approval."
        case "account_disabled", "account_rejected": key = "Your account is disabled. Contact the administrator."
        case "device_limit": key = "Device limit reached. Remove a device or contact the administrator."
        case "account_mismatch", "device_owned": key = "This device belongs to a different account."
        case "rate_limited": key = "请求过于频繁，请稍后重试。"
        case "maintenance": key = "The service is updating. Try again shortly."
        default: key = "The authorization request failed. Check your connection and retry."
        }
        let message = L10n.string(key)
        guard let requestID else { return message }
        return message + "\n" + L10n.format("Diagnostic reference: %@", requestID.uuidString)
    }
}
