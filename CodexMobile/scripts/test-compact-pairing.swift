import Foundation

@main
struct CompactPairingTests {
    static func main() throws {
        let invitation = String(repeating: "A", count: 43), key = Data(repeating: 7, count: 32).base64EncodedString()
        func code(_ address: String = "wss://cc.syggu.cn", _ token: String? = nil, _ publicKey: String? = nil) throws -> String {
            "RDX2:" + String(decoding: try JSONEncoder().encode([address, token ?? invitation, publicKey ?? key]), as: UTF8.self)
        }
        let value = try CompactPairingCode.parse(code())
        precondition(value.publicKey == key && value.invitation == invitation)
        for _ in 0..<1000 { let parsed = try CompactPairingCode.parse(code()); precondition(parsed == value) }
        for invalid in [try code("ws://example.test"), try code("wss://user:pass@example.test"), try code("wss://example.test/relay"), try code("wss://example.test", "short"), try code("wss://example.test", nil, "short"), "RDX2:[]", "RMX1:abc", "RDX3:[]", "{\"v\":2}", "ABCDEFGHJK"] {
            do { _ = try CompactPairingCode.parse(invalid); preconditionFailure("必须拒绝无效或旧格式") } catch {}
        }
        print("compact_pairing_production_parser_passed: stable1000, identity, address, malformed, old_format")
    }
}
