// FILE: QRScannerView.swift
// Purpose: AVFoundation pairing screen dedicated to camera-based QR scans.
// Layer: View
// Exports: QRScannerView
// Depends on: SwiftUI, AVFoundation

import AVFoundation
import SwiftUI
import UIKit
import CryptoKit

struct QRScannerView: View {
    @Environment(\.locale) private var _localizationLocale

    let onBack: (() -> Void)?
    let onScan: (CodexPairingQRPayload) -> Void
    let initialCode: String?
    @State private var preview: CodexPairingQRPayload?
    @State private var previewTask: Task<Void, Never>?
    @State private var previewEpoch = UUID()
    @State private var isFetchingPreview = false
    @State private var torch = false

    @State private var scannerError: String?
    @State private var bridgeUpdatePrompt: CodexBridgeUpdatePrompt?
    @State private var didCopyBridgeUpdateCommand = false
    @State private var hasCameraPermission = false
    @State private var isCheckingPermission = true

    init(
        initialBridgeUpdatePrompt: CodexBridgeUpdatePrompt? = nil,
        initialHasCameraPermission: Bool = false,
        initialIsCheckingPermission: Bool = true,
        initialCode: String? = nil,
        onBack: (() -> Void)? = nil,
        onScan: @escaping (CodexPairingQRPayload) -> Void
    ) {
        self.onBack = onBack
        self.onScan = onScan
        self.initialCode = initialCode
        _bridgeUpdatePrompt = State(initialValue: initialBridgeUpdatePrompt)
        _hasCameraPermission = State(initialValue: initialHasCameraPermission)
        _isCheckingPermission = State(initialValue: initialIsCheckingPermission)
    }

    var body: some View {
        let _ = _localizationLocale
        ZStack {
            Color.black.ignoresSafeArea()

            if isFetchingPreview {
                ProgressView("已识别，正在获取设备详情…").tint(.white).foregroundStyle(.white)
            } else if let preview {
                PairingConfirmationView(device: preview, onConfirm: {
                    self.preview = nil; onScan(preview)
                }, onCancel: {
                    self.preview = nil; Task { await checkCameraPermission() }
                })
            } else if isCheckingPermission {
                ProgressView()
                    .tint(.white)
            } else if let bridgeUpdatePrompt {
                bridgeUpdateView(prompt: bridgeUpdatePrompt)
            } else if hasCameraPermission {
                QRCameraPreview(torch: torch, onError: { scannerError = $0 }) { code, resetScanLock in
                    handleScanResult(code, resetScanLock: resetScanLock)
                }
                .ignoresSafeArea()

                scannerOverlay
            } else {
                cameraPermissionView
            }

        }
        .safeAreaInset(edge: .top) {
            if let onBack {
                HStack {
                    backButton(action: onBack)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
            }
        }
        .task {
            if let initialCode { handleScanResult(initialCode, resetScanLock: {}); isCheckingPermission = false }
            else { await checkCameraPermission() }
        }
        .onDisappear { previewEpoch = UUID(); previewTask?.cancel(); torch = false }
        .safeAreaInset(edge: .bottom) {
            if let scannerError {
                VStack { Text(scannerError); Button("重试") { self.scannerError = nil; Task { await checkCameraPermission() } } }
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
        isCheckingPermission = false
    }

    private func handleScanResult(_ code: String, resetScanLock: @escaping () -> Void) {
        switch validatePairingQRCode(code) {
        case .compact(let code):
            guard !isFetchingPreview else { return }
            scannerError = nil; isFetchingPreview = true
            let epoch = UUID(); previewEpoch = epoch
            previewTask?.cancel()
            previewTask = Task { @MainActor in
                do {
                    let result = try await RelayDeviceAccess.preview(code)
                    guard !Task.isCancelled, previewEpoch == epoch else { return }
                    preview = result; isFetchingPreview = false
                    HapticFeedback.shared.triggerImpactFeedback(style: .light)
                } catch {
                    guard !Task.isCancelled, previewEpoch == epoch else { return }
                    scannerError = error.localizedDescription; isFetchingPreview = false; resetScanLock()
                }
            }
        case .scanError(let message):
            scannerError = message
            Task { @MainActor in try? await Task.sleep(for: .seconds(2)); resetScanLock() }
        case .bridgeUpdateRequired(let prompt):
            didCopyBridgeUpdateCommand = false
            bridgeUpdatePrompt = prompt
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
    ) { _ in }
}

// MARK: - Camera Preview UIViewRepresentable

private struct QRCameraPreview: UIViewRepresentable {
    let torch: Bool
    let onError: (String) -> Void
    let onScan: (String, _ resetScanLock: @escaping () -> Void) -> Void

    func makeUIView(context: Context) -> QRCameraUIView {
        let view = QRCameraUIView()
        view.onError = onError
        view.onScan = { [weak view] code in
            onScan(code) {
                view?.resetScanLock()
            }
        }
        return view
    }

    func updateUIView(_ uiView: QRCameraUIView, context: Context) { uiView.setTorch(torch) }

    // Tears down the camera before UIKit deallocates the preview layer.
    static func dismantleUIView(_ uiView: QRCameraUIView, coordinator: ()) {
        uiView.stopCamera()
    }
}

// Serializes camera session handoff so a fast reopen cannot start before the previous stop completes.
private final class QRCameraLifecycleCoordinator {
    static let shared = QRCameraLifecycleCoordinator()
    private typealias DeferredStart = () -> Void

    private let queue = DispatchQueue(label: "com.phodex.qr-camera.lifecycle")
    private let lock = NSLock()
    private var isStopInFlight = false
    private var deferredStarts: [DeferredStart] = []

    // Starts immediately unless a previous stop still owns the camera handoff.
    func start(session: AVCaptureSession, canStart: @escaping () -> Bool) {
        let startWork: DeferredStart = { [queue] in
            queue.async {
                guard canStart(), !session.isRunning else {
                    return
                }
                session.startRunning()
            }
        }

        guard !deferStartIfNeeded(startWork) else {
            return
        }

        startWork()
    }

    // Holds new starts until stopRunning completes, then replays any deferred opens.
    func stop(session: AVCaptureSession) {
        lock.lock()
        isStopInFlight = true
        lock.unlock()

        queue.async { [weak self] in
            guard session.isRunning else {
                self?.finishStopAndReplayDeferredStarts()
                return
            }

            session.stopRunning()
            self?.finishStopAndReplayDeferredStarts()
        }
    }

    // Reopens queued scanners only after the previous session fully releases the camera.
    private func finishStopAndReplayDeferredStarts() {
        lock.lock()
        let startsToReplay = deferredStarts
        deferredStarts.removeAll()
        isStopInFlight = false
        lock.unlock()

        startsToReplay.forEach { start in
            start()
        }
    }

    // Converts overlapping reopen attempts into deferred starts while teardown is active.
    private func deferStartIfNeeded(_ startWork: @escaping DeferredStart) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard isStopInFlight else {
            return false
        }

        deferredStarts.append(startWork)
        return true
    }
}

// Owns the AVFoundation session lifecycle for the SwiftUI scanner host view.
private class QRCameraUIView: UIView, AVCaptureMetadataOutputObjectsDelegate {
    var onScan: ((String) -> Void)?
    var onError: ((String) -> Void)?
    private let configurationQueue = DispatchQueue(label: "cn.syggu.remodex.camera.configuration")
    private var captureDevice: AVCaptureDevice?
    private var metadata: AVCaptureMetadataOutput?
    private var observers: [NSObjectProtocol] = []

    private let captureSession = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var hasScanned = false
    private let stateLock = NSLock()
    private var stoppingCamera = false
    private var isStoppingCamera: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return stoppingCamera }
        set { stateLock.lock(); stoppingCamera = newValue; stateLock.unlock() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupCamera()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupCamera()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer?.frame = bounds
        if let orientation = window?.windowScene?.interfaceOrientation, let connection = previewLayer?.connection {
            let angle: CGFloat = orientation == .landscapeRight ? 0 : orientation == .landscapeLeft ? 180 : orientation == .portraitUpsideDown ? 270 : 90
            if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
        }
        if let layer = previewLayer, let metadata, bounds.width > 0 {
            let side: CGFloat = 250
            let scan = CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
            let region = layer.metadataOutputRectConverted(fromLayerRect: scan)
            configurationQueue.async { metadata.rectOfInterest = region }
        }
    }

    // Configures the metadata session once and starts it off the main thread.
    private func setupCamera() {
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(focus(_:))))
        for name in [AVCaptureSession.runtimeErrorNotification, AVCaptureSession.wasInterruptedNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: captureSession, queue: .main) { [weak self] _ in
                self?.onError?("相机被中断或不可用，请返回后重新打开扫码。")
            })
        }
        configurationQueue.async { [weak self] in
            guard let self else { return }
            do {
                guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else { throw CameraError.unavailable }
                let input = try AVCaptureDeviceInput(device: device)
                self.captureSession.beginConfiguration()
                defer { self.captureSession.commitConfiguration() }
                if self.captureSession.canSetSessionPreset(.hd1920x1080) { self.captureSession.sessionPreset = .hd1920x1080 }
                let output = AVCaptureMetadataOutput()
                guard self.captureSession.canAddInput(input) else { throw CameraError.unavailable }
                self.captureSession.addInput(input)
                guard self.captureSession.canAddOutput(output) else { throw CameraError.unavailable }
                self.captureSession.addOutput(output)
                guard output.availableMetadataObjectTypes.contains(.qr) else { throw CameraError.unavailable }
                output.setMetadataObjectsDelegate(self, queue: .main); output.metadataObjectTypes = [.qr]
                try device.lockForConfiguration()
                if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
                if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
                device.isSubjectAreaChangeMonitoringEnabled = true
                device.unlockForConfiguration()
                self.captureDevice = device
                // 下一项才发布预览，确保 commitConfiguration 已结束。
                self.configurationQueue.async { DispatchQueue.main.async { [weak self] in
                    guard let self, !self.isStoppingCamera else { return }
                    let layer = AVCaptureVideoPreviewLayer(session: self.captureSession)
                    layer.videoGravity = .resizeAspectFill; self.layer.addSublayer(layer)
                    self.previewLayer = layer; self.metadata = output; self.setNeedsLayout()
                    QRCameraLifecycleCoordinator.shared.start(session: self.captureSession) { [weak self] in self?.isStoppingCamera == false }
                } }
            } catch {
                DispatchQueue.main.async { [weak self] in self?.onError?("无法启动相机，请检查权限或关闭正在使用相机的应用。") }
            }
        }
    }
    private enum CameraError: Error { case unavailable }
    @objc private func focus(_ gesture: UITapGestureRecognizer) {
        guard let layer = previewLayer else { return }
        let point = layer.captureDevicePointConverted(fromLayerPoint: gesture.location(in: self))
        configurationQueue.async { [weak self] in
            guard let device = self?.captureDevice else { return }
            do { try device.lockForConfiguration(); defer { device.unlockForConfiguration() }
                if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = point }
                if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
                if device.isExposurePointOfInterestSupported { device.exposurePointOfInterest = point }
            } catch { DispatchQueue.main.async { [weak self] in self?.onError?("暂时无法调整对焦，请稍后重试。") } }
        }
    }
    func setTorch(_ enabled: Bool) {
        configurationQueue.async { [weak self] in
            guard let device = self?.captureDevice, device.hasTorch, device.isTorchAvailable else { return }
            do { try device.lockForConfiguration(); defer { device.unlockForConfiguration() }; device.torchMode = enabled ? .on : .off }
            catch { DispatchQueue.main.async { [weak self] in self?.onError?("手电筒暂时不可用。") } }
        }
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !hasScanned,
              let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              object.type == .qr,
              let code = object.stringValue else {
            return
        }

        hasScanned = true
        onScan?(code)
    }

    func resetScanLock() {
        hasScanned = false
    }

    // Detaches the preview layer first so AVFoundation teardown stays serialized.
    func stopCamera() {
        guard !isStoppingCamera else {
            return
        }

        isStoppingCamera = true
        onScan = nil
        onError = nil
        observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
        setTorch(false)

        let layerToRemove = previewLayer
        previewLayer = nil
        layerToRemove?.session = nil
        layerToRemove?.removeFromSuperlayer()

        QRCameraLifecycleCoordinator.shared.stop(session: captureSession)
    }

    deinit {
        stopCamera()
    }
}
