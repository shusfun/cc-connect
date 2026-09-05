import XCTest
@testable import CodexMobile

final class QRScannerPairingValidatorTests: XCTestCase {
    private let key = Data(repeating: 7, count: 32).base64EncodedString()
    private let invitation = String(repeating: "A", count: 43)
    private func code(relay: String = "wss://cc.syggu.cn", key: String? = nil, invitation: String? = nil) -> String {
        let data = try! JSONEncoder().encode([relay, invitation ?? self.invitation, key ?? self.key])
        return "RDX2:" + String(decoding: data, as: UTF8.self)
    }
    func testCompactCodePreservesFullIdentityAndInvitation() {
        guard case .compact(let payload) = validatePairingQRCode(code()) else { return XCTFail("应接受紧凑配对码") }
        XCTAssertEqual(payload.publicKey, key); XCTAssertEqual(payload.invitation, invitation)
        XCTAssertEqual(payload.relay, "wss://cc.syggu.cn")
    }
    func testOldFormatsAlwaysRequireUpdate() {
        for value in ["{\"v\":2,\"relay\":\"wss://example.test\"}", "RMX1:abc", "ABCDEFGHJK", "RDX3:[]"] {
            guard case .bridgeUpdateRequired(let prompt) = validatePairingQRCode(value) else { XCTFail("不再支持旧格式"); continue }
            XCTAssertNil(prompt.command)
            XCTAssertEqual(prompt.message, L10n.string("该配对码来自旧版或不兼容的应用，请更新电脑和 iPhone 应用后重新扫码。"))
        }
    }
    func testRejectsUnsafeAddressAndTruncatedIdentity() {
        for value in [code(relay: "ws://example.test"), code(relay: "wss://user:pass@example.test"), code(relay: "wss://example.test/relay"), code(relay: "wss://example.test?invitation=secret"), code(key: "short"), code(invitation: "short"), "RDX2:[]", "RDX2:[1,2,3]"] {
            guard case .scanError = validatePairingQRCode(value) else { XCTFail("必须拒绝无效码"); continue }
        }
    }
    func testUnrelatedQRCodeIsNotAPairing() {
        guard case .scanError = validatePairingQRCode("https://example.test") else { return XCTFail("必须拒绝无关二维码") }
    }
}
