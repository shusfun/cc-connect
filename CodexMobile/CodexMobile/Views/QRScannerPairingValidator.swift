import Foundation

enum QRScannerPairingValidationResult {
    case compact(CompactPairingCode)
    case scanError(String)
    case bridgeUpdateRequired(CodexBridgeUpdatePrompt)
}

func validatePairingQRCode(_ code: String, now: Date = Date()) -> QRScannerPairingValidationResult {
    do { return .compact(try CompactPairingCode.parse(code)) }
    catch CompactPairingCode.ParseError.updateRequired {
        return .bridgeUpdateRequired(CodexBridgeUpdatePrompt(title: L10n.string("请更新设备上的 Remodex"), message: L10n.string("该配对码来自旧版或不兼容的应用，请更新电脑和 iPhone 应用后重新扫码。"), command: nil))
    } catch CompactPairingCode.ParseError.unrelated {
        return .scanError(L10n.string("这不是 Remodex 配对二维码，请对准电脑配对页上的二维码。"))
    } catch { return .scanError(L10n.string("二维码内容不完整或格式不正确，请在电脑上刷新后重试。")) }
}
