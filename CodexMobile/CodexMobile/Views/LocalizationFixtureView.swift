#if DEBUG
import SwiftUI

/// 仅测试启动参数可达，使用实际页面；不连接 Relay，不审批或下载模型。
struct LocalizationFixtureView: View {
    @Environment(CodexService.self) private var codex
    @State private var draft = "User draft / 用户草稿"
    private var route: String { UserDefaults.standard.string(forKey: "FixtureRoute") ?? "settings" }
    private var device: CodexPairingQRPayload {
        CodexPairingQRPayload(v: 2, relay: "wss://fixture.invalid", sessionId: "", macDeviceId: "fixture-device", macIdentityPublicKey: Data(repeating: 7, count: 32).base64EncodedString(), expiresAt: Int64(Date().addingTimeInterval(300).timeIntervalSince1970 * 1000), displayName: "Fixture Device / 测试设备", platform: "windows")
    }
    var body: some View {
        NavigationStack {
            Group {
                switch route {
                case "onboarding": OnboardingWelcomePage()
                case "pairing": PairingConfirmationView(device: device, onConfirm: {}, onCancel: {})
                case "voice": VoiceModelSetupSheet()
                case "devices": MyDevicesSettingsSheet(isSwitchingMac: false, switchingDeviceId: nil, switchNotice: nil, onSelectDevice: { _ in }, onForgetDevice: { _ in }, onAddConnection: {}, onPairWithCode: {}, onCancelSwitch: {})
                case "chat": TurnTimelineRunningEmptyState()
                case "loading": TurnTimelineLoadingOverlay()
                case "approval": ApprovalBanner(request: .init(id: "fixture-approval", requestID: .string("fixture-request"), method: "item/commandExecution/requestApproval", command: "git status --short", reason: nil, threadId: "fixture", turnId: "fixture-turn", params: nil), isLoading: false, onApprove: {}, onDecline: {})
                case "questions": StructuredUserInputCardView(questions: [.init(id: "fixture-question", header: "User question", question: "Preserve original question / 保留问题原文", isOther: true, isSecret: false, options: [])], isSubmitting: false, hasSubmittedResponse: false, isInteractionLocked: false, onSelectOption: { _, _ in }, secondaryActionTitle: nil, onSecondaryAction: nil, onSubmit: { _ in })
                case "git": AssistantRevertSheet(state: .init(changeSet: .init(threadId: "fixture", turnId: "fixture-turn", source: .turnDiff), presentation: .init(title: L10n.string("Cannot undo"), isEnabled: false, helperText: nil, riskLevel: .blocked), preview: nil, isLoadingPreview: true, isApplying: false, errorMessage: nil), onClose: {}, onConfirm: {})
                case "errors": VStack(spacing: 20) {
                    Text(RelayAccessFailure(code: "device_offline", status: 409, requestID: nil).localizedDescription)
                    Text(RelayAccessFailure(code: "approval_pending", status: 409, requestID: nil).localizedDescription)
                    Text(RelayAccessFailure(code: "invitation_expired", status: 410, requestID: nil).localizedDescription)
                }
                default: SettingsView()
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack {
                    Text(verbatim: "TEST FIXTURE — NOT A LIVE CONNECTION").font(.caption2)
                    TextField("Draft", text: $draft).accessibilityIdentifier("fixture.draft")
                    Text(verbatim: String(describing: ObjectIdentifier(codex))).accessibilityIdentifier("fixture.service")
                }.padding(8).background(.regularMaterial)
            }
        }
        .preferredColorScheme(UserDefaults.standard.string(forKey: "FixtureTheme") == "dark" ? .dark : .light)
    }
}

struct TimelinePerformanceFixtureView: View {
    @Environment(CodexService.self) private var codex
    @State private var ready = false
    private let thread = CodexThread(id: "performance-fixture", title: "Timeline performance fixture")
    var body: some View {
        NavigationStack {
            if ready { TurnView(thread: thread, isWakingMacDisplayRecovery: false) }
            else { ProgressView() }
        }.task {
            guard !ready else { return }
            let count = max(1, UserDefaults.standard.integer(forKey: "CodexUITestsMessageCount"))
            codex.threads = [thread]
            codex.messagesByThread[thread.id] = (0..<count).map { index in
                CodexMessage(id: "fixture-\(index)", threadId: thread.id, role: index.isMultiple(of: 2) ? .user : .assistant, text: "Fixture message \(index)\n`let value = \(index)`", orderIndex: index)
            }
            codex.messageRevisionByThread[thread.id] = 1
            codex.refreshThreadTimelineState(for: thread.id)
            ready = true
            if ProcessInfo.processInfo.arguments.contains("-CodexUITestsAutoStream") {
                for index in 0..<120 {
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                    codex.appendMessage(CodexMessage(threadId: thread.id, role: .assistant, text: "Streaming fixture \(index)", isStreaming: true))
                }
            }
        }
    }
}
#endif
