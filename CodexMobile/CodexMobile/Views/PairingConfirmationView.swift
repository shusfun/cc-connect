import SwiftUI

struct PairingConfirmationView: View {
    @Environment(\.locale) private var locale
    let device: CodexPairingQRPayload
    let onConfirm: () -> Void
    let onCancel: () -> Void
    var body: some View {
        let _ = locale
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("确认配对设备").font(.title2)
                Text(device.displayName ?? L10n.string("开发设备")).font(.headline)
                Text(verbatim: device.platform == "windows" ? "Windows" : "macOS")
                Text(L10n.format("身份指纹：%@", RelayDeviceAccess.sha(Data(base64Encoded: device.macIdentityPublicKey) ?? Data())))
                    .font(.caption.monospaced()).textSelection(.enabled)
                Text("请核对电脑上的身份指纹。确认后仍需在电脑上批准手机配对。")
                Button("确认设备，申请配对", action: onConfirm).buttonStyle(.borderedProminent).frame(minHeight: 44)
                Button("取消，重新扫码", action: onCancel).frame(minHeight: 44)
            }.padding(28)
        }
        .accessibilityIdentifier("pairing.details")
        .foregroundStyle(.white).background(.black)
    }
}
