// FILE: QRScannerView.swift
// Purpose: AVFoundation pairing screen dedicated to camera-based QR scans.
// Layer: View
// Exports: QRScannerView
// Depends on: SwiftUI, AVFoundation

import AVFoundation
import SwiftUI
import UIKit
import CryptoKit

@MainActor struct QRScannerView: View {
    @Environment(\.locale) private var _localizationLocale
    @Environment(\.scenePhase) private var scenePhase

    let onBack: (() -> Void)?
    let flow: PairingFlowModel
    let onScan: (CodexPairingQRPayload, PairingRequestContext) async throws -> Void
    let onFinish: () -> Void
    let onStop: () -> Void
    let initialCode: String?
    @State private var torch = false
    @State private var cameraGeneration = UUID()
    @State private var cameraRecoveryCount = 0
    @State private var invalidCodeResetTask: Task<Void, Never>?

    @State private var scannerError: String?
    @State private var cameraErrorCode: String?
    @State private var bridgeUpdatePrompt: CodexBridgeUpdatePrompt?
    @State private var didCopyBridgeUpdateCommand = false
    @State private var hasCameraPermission = false
    @State private var isCheckingPermission = true

    init(
        initialBridgeUpdatePrompt: CodexBridgeUpdatePrompt? = nil,
        initialHasCameraPermission: Bool = false,
        initialIsCheckingPermission: Bool = true,
        initialCode: String? = nil,
        flow: PairingFlowModel? = nil,
        onBack: (() -> Void)? = nil,
        onFinish: @escaping () -> Void = {},
        onStop: @escaping () -> Void = {},
        onScan: @escaping (CodexPairingQRPayload, PairingRequestContext) async throws -> Void
    ) {
        self.onBack = onBack
        self.onScan = onScan
        self.flow = flow ?? PairingFlowModel()
        self.onFinish = onFinish
        self.onStop = onStop
        self.initialCode = initialCode
        _bridgeUpdatePrompt = State(initialValue: initialBridgeUpdatePrompt)
        _hasCameraPermission = State(initialValue: initialHasCameraPermission)
        _isCheckingPermission = State(initialValue: initialIsCheckingPermission)
    }

    var body: some View {
        let _ = _localizationLocale
        let generation = cameraGeneration
        ZStack {
            Color.black.ignoresSafeArea()

            if flow.showsDetails {
                PairingConfirmationView(flow: flow, onConfirm: {
                    flow.confirm(connect: onScan)
                }, onCancel: {
                    flow.rescan(); scannerError = nil; cameraGeneration = UUID()
                    Task { await checkCameraPermission() }
                }, onFinish: onFinish, onStop: onStop)
            } else if isCheckingPermission {
                ProgressView()
                    .tint(.white)
            } else if let bridgeUpdatePrompt {
                bridgeUpdateView(prompt: bridgeUpdatePrompt)
            } else if hasCameraPermission && scenePhase == .active {
                QRCameraPreview(torch: torch, onError: { code in
                    guard generation == cameraGeneration else { return }
                    scannerError = L10n.string("相机暂不可用，请查看诊断或重试相机。")
                    cameraErrorCode = code
                    flow.diagnostics.cameraFailure(code: code)
                }, onRecovery: {
                    guard generation == cameraGeneration, cameraRecoveryCount < 1, !flow.showsDetails, scenePhase == .active else { return }
                    cameraRecoveryCount += 1
                    cameraGeneration = UUID()
                    flow.diagnostics.transition(.camera)
                }, onSnapshot: { snapshot in
                    guard generation == cameraGeneration else { return }
                    var snapshot = snapshot
                    snapshot.recoveryCount = cameraRecoveryCount
                    flow.cameraUpdate(snapshot)
                    if snapshot.running, ["camera_interrupted", "camera_unavailable", "camera_configuration_failed"].contains(cameraErrorCode ?? "") {
                        scannerError = nil
                        cameraErrorCode = nil
                    }
                }) { code, resetScanLock in
                    handleScanResult(code, resetScanLock: resetScanLock)
                }
                .id(cameraGeneration)
                .ignoresSafeArea()

                scannerOverlay
            } else {
                cameraPermissionView
            }

        }
        .safeAreaInset(edge: .top) {
            if let onBack, flow.phase != .connecting {
                HStack {
                    backButton(action: { flow.rescan(); onBack() })
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
            }
        }
        .task {
            var machine = utsname()
            uname(&machine)
            let model = withUnsafePointer(to: &machine.machine) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
            }
            flow.diagnostics.setEnvironment(model: model, system: UIDevice.current.systemVersion)
            if let initialCode { handleScanResult(initialCode, resetScanLock: {}); isCheckingPermission = false }
            else { await checkCameraPermission() }
        }
        .onDisappear { torch = false; invalidCodeResetTask?.cancel() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && !flow.showsDetails {
                cameraRecoveryCount = 0; cameraGeneration = UUID()
                flow.diagnostics.transition(.camera)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !flow.showsDetails {
                ScrollView { PairingDiagnosticsView(diagnostics: flow.diagnostics) }
                    .frame(maxHeight: 210).foregroundStyle(.white).background(.black.opacity(0.9))
            }
            if let scannerError, !flow.showsDetails {
                VStack { Text(scannerError); Button("重试") {
                    self.scannerError = nil
                    cameraErrorCode = nil
                    cameraGeneration = UUID()
                    cameraRecoveryCount = 0
                    flow.diagnostics.transition(.camera)
                    Task { await checkCameraPermission() }
                } }
                    .padding().foregroundStyle(.white).background(.black.opacity(0.85))
            }
        }
    }

    // 不兼容时引导更新应用，不再提供全局 CLI 操作。
    private func bridgeUpdateView(prompt: CodexBridgeUpdatePrompt) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(prompt.title)
                        .font(AppFont.title3(weight: .semibold))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(prompt.message)
                        .font(AppFont.body())
                        .foregroundStyle(.white.opacity(0.82))
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 14) {
                    bridgeUpdateStep(number: "1", title: L10n.string("更新应用"), detail: L10n.string("在电脑和 iPhone 上安装配套版本的 Remodex。"))
                    bridgeUpdateStep(number: "2", title: L10n.string("重新生成二维码"), detail: L10n.string("打开电脑应用的连接与配对页，点击刷新配对码。"))
                    bridgeUpdateStep(number: "3", title: L10n.string("返回扫码"), detail: L10n.string("使用 iPhone 扫描新的二维码，并核对设备身份。"))
                }

                Button("已更新，重新扫码") {
                    bridgeUpdatePrompt = nil
                    didCopyBridgeUpdateCommand = false
                }
                .font(AppFont.body(weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .foregroundStyle(.black)
                .background(.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 96)
            .padding(.bottom, 36)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func bridgeUpdateStep(
        number: String,
        title: String,
        detail: String,
        showsCopyButton: Bool = false
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(AppFont.caption2(weight: .bold))
                .foregroundStyle(.black)
                .frame(width: 20, height: 20)
                .background(.white, in: Circle())
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(AppFont.subheadline(weight: .semibold))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)

                Text(detail)
                    .font(showsCopyButton ? AppFont.mono(.caption) : AppFont.caption())
                    .foregroundStyle(.white.opacity(0.82))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                    )

                if showsCopyButton {
                    Button(didCopyBridgeUpdateCommand ? L10n.string("已复制") : L10n.string("复制说明")) {
                        UIPasteboard.general.string = detail
                        HapticFeedback.shared.triggerImpactFeedback(style: .light)
                        withAnimation(.easeInOut(duration: 0.2)) {
                            didCopyBridgeUpdateCommand = true
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                didCopyBridgeUpdateCommand = false
                            }
                        }
                    }
                    .font(AppFont.caption(weight: .semibold))
                    .foregroundStyle(.white)
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // Keeps the first-run scanner escapable without turning reconnect recovery into onboarding.
    private func backButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            RemodexIcon.image(systemName: "chevron.left")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Color.white.opacity(0.12), in: Circle())
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("返回")
    }

    private var scannerOverlay: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.white.opacity(0.6), lineWidth: 2)
                .frame(width: 250, height: 250)
                .allowsHitTesting(false)
            VStack(spacing: 20) {
            Text("对准电脑上的 Remodex 二维码，保持适当距离")
                .font(AppFont.subheadline(weight: .medium))
                .foregroundStyle(.white)
            Button(torch ? L10n.string("关闭手电筒") : L10n.string("打开手电筒")) { torch.toggle() }.buttonStyle(.bordered).tint(.white)

            }.padding(.horizontal, 24).offset(y: 190)
        }
    }

    private var cameraPermissionView: some View {
        VStack(spacing: 20) {
            RemodexIcon.image(systemName: "camera.fill")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("需要相机权限")
                .font(AppFont.title3(weight: .semibold))
                .foregroundStyle(.white)

            Text("请在设置中允许相机访问，以扫描配对二维码。")
                .font(AppFont.subheadline())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Button("打开设置") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // Keeps permission-prompt teardown on the main actor so backing out mid-prompt
    // does not race a stale state write against SwiftUI dismissal.
    @MainActor
    private func checkCameraPermission() async {
        let hasPermission: Bool
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            hasPermission = true
        case .notDetermined:
            hasPermission = await AVCaptureDevice.requestAccess(for: .video)
        default:
            hasPermission = false
        }

        guard !Task.isCancelled else {
            return
        }

        hasCameraPermission = hasPermission
        if !hasPermission { flow.diagnostics.cameraFailure(code: "camera_permission_denied") }
        isCheckingPermission = false
    }

    private func handleScanResult(_ code: String, resetScanLock: @escaping () -> Void) {
        switch validatePairingQRCode(code) {
        case .compact(let code):
            guard flow.phase == .scanning else { return }
            invalidCodeResetTask?.cancel()
            scannerError = nil
            cameraErrorCode = nil
            HapticFeedback.shared.triggerImpactFeedback(style: .light)
            flow.recognize(code)
        case .scanError(let message):
            scannerError = message
            cameraErrorCode = nil
            flow.diagnostics.transition(.validation)
            flow.diagnostics.finish("failed", code: "invalid_qr")
            invalidCodeResetTask?.cancel()
            let epoch = flow.generation
            invalidCodeResetTask = Task { @MainActor in
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard flow.phase == .scanning, flow.generation == epoch else { return }
                resetScanLock()
                flow.diagnostics.transition(.scanning)
            }
        case .bridgeUpdateRequired(let prompt):
            didCopyBridgeUpdateCommand = false
            bridgeUpdatePrompt = prompt
            flow.diagnostics.transition(.validation)
            flow.diagnostics.finish("failed", code: "update_required")
            resetScanLock()
        }
    }
}

private extension CodexBridgeUpdatePrompt {
    static let previewScannerMismatch = CodexBridgeUpdatePrompt(
        title: L10n.string("扫码前请更新 Mac 上的 Remodex.app"),
        message: L10n.string("该二维码来自不兼容的 Mac App。更新后重新生成二维码。"),
        command: nil
    )
}

// MARK: - Preview

#Preview("Bridge Update Required") {
    QRScannerView(
        initialBridgeUpdatePrompt: .previewScannerMismatch,
        initialIsCheckingPermission: false,
        onBack: {}
    ) { _, _ in }
}

// MARK: - Camera Preview UIViewRepresentable

nonisolated enum QRScannerCapturePolicy {
    static let cameraTypes: [AVCaptureDevice.DeviceType] = [
        .builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera
    ]
    static let detectionRegion = CGRect(x: 0, y: 0, width: 1, height: 1)

    static func preferredCode(in codes: [String]) -> String? {
        let candidates = codes.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return candidates.first { $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("RDX2:") }
            ?? candidates.first
    }
}
