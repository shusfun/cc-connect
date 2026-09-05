import Foundation

/// 二维码只携带会合入口、一次性邀请和不可替换的电脑公钥。
struct CompactPairingCode: Equatable, Sendable {
    let relay: String
    let invitation: String
    let publicKey: String
    enum ParseError: Error { case updateRequired, unrelated, malformed }

    static func parse(_ value: String) throws -> Self {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("RDX2:") else {
            if text.hasPrefix("{") || text.hasPrefix("RMX1:") || text.hasPrefix("RDX") || text.range(of: "^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789 -]{8,16}$", options: [.regularExpression, .caseInsensitive]) != nil { throw ParseError.updateRequired }
            throw ParseError.unrelated
        }
        guard text.utf8.count <= 2048,
              let data = String(text.dropFirst(5)).data(using: .utf8),
              let fields = try? JSONDecoder().decode([String].self, from: data), fields.count == 3,
              let url = URLComponents(string: fields[0]), url.scheme == "wss", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil, ["", "/"].contains(url.path),
              fields[1].range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil,
              let key = Data(base64Encoded: fields[2]), key.count == 32, key.base64EncodedString() == fields[2]
        else { throw ParseError.malformed }
        return Self(relay: fields[0], invitation: fields[1], publicKey: fields[2])
    }
}
