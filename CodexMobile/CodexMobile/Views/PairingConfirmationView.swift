import SwiftUI
import CryptoKit

struct PairingConfirmationView: View {
    @Environment(\.locale) private var locale
    let flow: PairingFlowModel
    let onConfirm: () -> Void
    let onCancel: () -> Void
    let onFinish: () -> Void
    let onStop: () -> Void
    var body: some View {
        let _ = locale
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("确认配对设备").font(.title2)
                Text("已在本地识别二维码").foregroundStyle(.green)
                    .accessibilityIdentifier("pairing.locally-recognized")
                if let draft = flow.draft {
                    Text(flow.diagnostics.origin ?? "").font(.callout.monospaced()).textSelection(.enabled)
                    Text(L10n.format("身份指纹：%@", SHA256.hash(data: Data(base64Encoded: draft.publicKey) ?? Data()).map { String(format: "%02x", $0) }.joined()))
                        .font(.caption.monospaced()).textSelection(.enabled)
                }
                if let device = flow.verified {
                    Text(device.displayName ?? L10n.string("开发设备")).font(.headline)
                    Text(verbatim: device.platform == "windows" ? "Windows" : "macOS")
                } else {
                    Text("设备名称与平台：等待服务端验证")
                }
                Text(statusMessage).accessibilityIdentifier("pairing.status")
                if let code = flow.failureCode {
                    Text(verbatim: code).font(.caption.monospaced()).foregroundStyle(.orange)
                }
                if flow.phase == .ready || flow.phase == .verifying {
                    Text("请核对电脑上的身份指纹。确认后仍需在电脑上批准手机配对。")
                    Button("确认设备，申请配对", action: onConfirm)
                        .disabled(flow.phase != .ready).buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("pairing.confirm")
                }
                if flow.mayRetryVerification {
                    Button("重试验证") { flow.verify() }.buttonStyle(.borderedProminent)
                }
                if flow.phase == .connecting {
                    Button("停止等待") { flow.stop(); onStop() }.buttonStyle(.bordered)
                } else if flow.phase == .completed {
                    Button("进入工作区", action: onFinish).buttonStyle(.borderedProminent)
                } else {
                    Button("取消，重新扫码", action: onCancel).buttonStyle(.bordered)
                }
                PairingDiagnosticsView(diagnostics: flow.diagnostics)
            }.padding(24)
        }
        .accessibilityIdentifier("pairing.details")
        .foregroundStyle(.white).background(.black)
    }

    private var statusMessage: String {
        switch flow.phase {
        case .scanning: return L10n.string("等待二维码")
        case .verifying: return L10n.string("本地识别已完成；正在验证邀请，每次请求最多等待 15 秒。")
        case .ready: return L10n.string("设备身份已验证，等待你确认。")
        case .connecting:
            return flow.diagnostics.stage == .approval
                ? L10n.string("请在电脑批准配对。每 3 秒检查一次，最多检查 100 次；单次请求上限 15 秒。")
                : flow.diagnostics.stage.title
        case .stopped: return flow.submitted ? L10n.string("已停止客户端等待；不代表服务端申请已撤销，请检查电脑端。") : L10n.string("已停止验证，可以重新扫码。")
        case .completed: return L10n.string("设备已授权，加密连接与协议初始化已完成。")
        case .failed:
            if flow.failureCode == "submission_uncertain" { return L10n.string("申请结果不确定。不会自动再次提交，请检查电脑端或刷新配对码。") }
            if !flow.mayRetryVerification { return L10n.string("无法继续此配对，请检查电脑端并刷新二维码。") }
            return L10n.string("本地识别已完成，但服务端验证失败。请查看诊断后重试。")
        }
    }
}

struct PairingDiagnosticsView: View {
    let diagnostics: PairingDiagnostics
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("开发者诊断").font(.headline)
                Spacer()
                Button(copied ? L10n.string("已复制脱敏诊断") : L10n.string("复制脱敏诊断")) {
                    UIPasteboard.general.setItems([["public.utf8-plain-text": diagnostics.exportJSON()]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(300)])
                    copied = true
                }.font(.caption)
            }
            Text(verbatim: "operationId: \(diagnostics.operationId.uuidString)").textSelection(.enabled)
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(verbatim: "\(diagnostics.stage.title) · \(diagnostics.stageMilliseconds) ms / \(diagnostics.elapsedMilliseconds) ms")
            }
            Text(verbatim: diagnostics.environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " · "))
            Text(verbatim: "connectionAttempts=\(diagnostics.connectionAttempts)")
            Text(verbatim: "camera=\(diagnostics.camera.selectedType) running=\(diagnostics.camera.running) QR=\(diagnostics.camera.qrEnabled) fullFrame=\(diagnostics.camera.fullFrame) callbacks=\(diagnostics.camera.metadataCallbacks) qrCount=\(diagnostics.camera.qrCount) recoveries=\(diagnostics.camera.recoveryCount)")
            ForEach(diagnostics.events) { event in
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "\(event.elapsedMilliseconds) ms · \(event.stage.title) · \(event.outcome) · \(event.durationMilliseconds.map { "\($0) ms" } ?? "…")")
                    if let route = event.route {
                        Text(verbatim: "POST \(route.rawValue) · HTTP \(event.status.map(String.init) ?? "—") · count=\(event.count)")
                        Text(verbatim: "code=\(event.code ?? "—") requestId=\(event.requestId?.uuidString ?? "—") network=\(event.networkError.map(String.init) ?? "—")")
                        if event.outcome == "in_progress" { Text("请求已发出，等待响应（上限 15 秒）") }
                        else if event.status == nil { Text("无服务端响应／无 requestId") }
                    } else if let code = event.code { Text(verbatim: code) }
                }.textSelection(.enabled)
            }
        }
        .font(.caption2.monospaced())
        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("pairing.diagnostics")
    }
}
