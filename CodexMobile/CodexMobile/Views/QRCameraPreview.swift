import AVFoundation
import SwiftUI
import UIKit

struct QRCameraPreview: UIViewRepresentable {
    let torch: Bool
    let onError: (String) -> Void
    let onRecovery: () -> Void
    let onSnapshot: (PairingCameraSnapshot) -> Void
    let onScan: (String, @escaping () -> Void) -> Void

    func makeUIView(context: Context) -> QRCameraUIView {
        let view = QRCameraUIView()
        view.onError = onError
        view.onRecovery = onRecovery
        view.onSnapshot = onSnapshot
        view.onScan = { [weak view] code in onScan(code) { view?.resetScanLock() } }
        view.start()
        return view
    }

    func updateUIView(_ uiView: QRCameraUIView, context: Context) { uiView.setTorch(torch) }
    static func dismantleUIView(_ uiView: QRCameraUIView, coordinator: ()) { uiView.stop() }
}

final class QRCameraUIView: UIView {
    var onError: ((String) -> Void)?
    var onRecovery: (() -> Void)?
    var onSnapshot: ((PairingCameraSnapshot) -> Void)?
    var onScan: ((String) -> Void)?
    private var preview: AVCaptureVideoPreviewLayer?
    private var stopped = false
    private lazy var engine = QRCameraEngine()

    func start() {
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(focus(_:))))
        let reportSnapshot = onSnapshot
        engine.start(ready: { [weak self] session in
            guard let self, !self.stopped else { return }
            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.videoGravity = .resizeAspectFill
            self.layer.addSublayer(preview)
            self.preview = preview
            self.setNeedsLayout()
        }, snapshot: { [weak self] value in
            if value.running && self?.stopped != false { return }
            reportSnapshot?(value)
        }, error: { [weak self] code, recover in
            guard let self, !self.stopped else { return }
            self.onError?(code)
            if recover { self.onRecovery?() }
        }, scanned: { [weak self] code in
            guard let self, !self.stopped else { return }
            self.onScan?(code)
        })
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        preview?.frame = bounds
        if let orientation = window?.windowScene?.effectiveGeometry.interfaceOrientation, let connection = preview?.connection {
            let angle: CGFloat = orientation == .landscapeRight ? 0 : orientation == .landscapeLeft ? 180 : orientation == .portraitUpsideDown ? 270 : 90
            if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
        }
    }

    @objc private func focus(_ gesture: UITapGestureRecognizer) {
        guard let preview else { return }
        engine.focus(preview.captureDevicePointConverted(fromLayerPoint: gesture.location(in: self)))
    }

    func setTorch(_ value: Bool) { engine.torch(value) }
    func resetScanLock() { engine.resetScanLock() }
    func stop() {
        guard !stopped else { return }
        stopped = true
        onScan = nil; onError = nil; onRecovery = nil; onSnapshot = nil
        preview?.session = nil
        preview?.removeFromSuperlayer()
        preview = nil
        engine.stop()
    }
}

nonisolated private final class QRCameraEngine: NSObject, AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
    private static let queue = DispatchQueue(label: "cn.syggu.remodex.camera.owner")
    private static weak var active: QRCameraEngine?
    private let session = AVCaptureSession()
    private var device: AVCaptureDevice?
    private var stopped = false
    private var scanned = false
    private var torchValue: Bool?
    private var observers: [NSObjectProtocol] = []
    private var state = PairingCameraSnapshot()
    private var onSnapshot: (@MainActor @Sendable (PairingCameraSnapshot) -> Void)?
    private var onError: (@MainActor @Sendable (String, Bool) -> Void)?
    private var onScan: (@MainActor @Sendable (String) -> Void)?

    func start(ready: @escaping @MainActor @Sendable (AVCaptureSession) -> Void,
               snapshot: @escaping @MainActor @Sendable (PairingCameraSnapshot) -> Void,
               error: @escaping @MainActor @Sendable (String, Bool) -> Void,
               scanned: @escaping @MainActor @Sendable (String) -> Void) {
        Self.queue.async { [self] in
            guard !stopped else { return }
            if let previous = Self.active, previous !== self { previous.stopOnQueue() }
            Self.active = self
            onSnapshot = snapshot; onError = error; onScan = scanned
            do {
                guard let selected = QRScannerCapturePolicy.cameraTypes.lazy.compactMap({
                    AVCaptureDevice.default($0, for: .video, position: .back)
                }).first else { throw CameraFailure.unavailable }
                let input = try AVCaptureDeviceInput(device: selected)
                let output = AVCaptureMetadataOutput()
                session.beginConfiguration()
                do {
                    if session.canSetSessionPreset(.hd1920x1080) { session.sessionPreset = .hd1920x1080 }
                    guard session.canAddInput(input) else { throw CameraFailure.unavailable }
                    session.addInput(input)
                    guard session.canAddOutput(output) else { throw CameraFailure.unavailable }
                    session.addOutput(output)
                    guard output.availableMetadataObjectTypes.contains(.qr) else { throw CameraFailure.unavailable }
                    output.metadataObjectTypes = [.qr]
                    output.rectOfInterest = QRScannerCapturePolicy.detectionRegion
                    output.setMetadataObjectsDelegate(self, queue: Self.queue)
                    session.commitConfiguration()
                } catch {
                    session.commitConfiguration()
                    throw error
                }
                device = selected
                try selected.lockForConfiguration()
                if selected.isFocusModeSupported(.continuousAutoFocus) { selected.focusMode = .continuousAutoFocus }
                if selected.isExposureModeSupported(.continuousAutoExposure) { selected.exposureMode = .continuousAutoExposure }
                selected.isSubjectAreaChangeMonitoringEnabled = true
                selected.unlockForConfiguration()
                state.selectedType = selected.deviceType.rawValue
                state.qrEnabled = output.metadataObjectTypes == [.qr]
                state.fullFrame = output.rectOfInterest == QRScannerCapturePolicy.detectionRegion
                for name in [AVCaptureSession.runtimeErrorNotification, AVCaptureSession.wasInterruptedNotification, AVCaptureSession.interruptionEndedNotification] {
                    observers.append(NotificationCenter.default.addObserver(forName: name, object: session, queue: nil) { [weak self] notification in
                        let recovery = notification.name != AVCaptureSession.wasInterruptedNotification
                        Self.queue.async { [weak self] in
                            guard let self, !self.stopped else { return }
                            self.state.running = self.session.isRunning
                            self.publish()
                            self.report("camera_interrupted", recover: recovery)
                        }
                    })
                }
                DispatchQueue.main.async { [session] in ready(session) }
                session.startRunning()
                state.running = session.isRunning
                publish()
                if !session.isRunning { report("camera_unavailable", recover: true) }
            } catch {
                report("camera_configuration_failed", recover: false)
            }
        }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !stopped else { return }
        state.metadataCallbacks += 1
        let codes = metadataObjects.compactMap { object -> String? in
            guard let value = object as? AVMetadataMachineReadableCodeObject, value.type == .qr else { return nil }
            return value.stringValue
        }
        state.qrCount += codes.count
        publish()
        guard !scanned, let code = QRScannerCapturePolicy.preferredCode(in: codes), let onScan else { return }
        scanned = true
        DispatchQueue.main.async { onScan(code) }
    }

    func resetScanLock() { Self.queue.async { [self] in if !stopped { scanned = false } } }

    func focus(_ point: CGPoint) {
        Self.queue.async { [self] in
            guard !stopped, let device else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = point }
                if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
                if device.isExposurePointOfInterestSupported { device.exposurePointOfInterest = point }
            } catch { report("camera_focus_failed", recover: false) }
        }
    }

    func torch(_ value: Bool) {
        Self.queue.async { [self] in
            guard !stopped, torchValue != value, let device, device.hasTorch, device.isTorchAvailable else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                device.torchMode = value ? .on : .off
                torchValue = value
            } catch { report("camera_torch_failed", recover: false) }
        }
    }

    func stop() { Self.queue.async { [self] in stopOnQueue() } }

    private func stopOnQueue() {
        guard !stopped else { return }
        stopped = true
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        if let device, device.hasTorch, (try? device.lockForConfiguration()) != nil {
            device.torchMode = .off
            device.unlockForConfiguration()
        }
        if session.isRunning { session.stopRunning() }
        session.beginConfiguration()
        for output in session.outputs {
            (output as? AVCaptureMetadataOutput)?.setMetadataObjectsDelegate(nil, queue: nil)
            session.removeOutput(output)
        }
        for input in session.inputs { session.removeInput(input) }
        session.commitConfiguration()
        device = nil
        state.running = false
        publish()
        onSnapshot = nil; onError = nil; onScan = nil
        if Self.active === self { Self.active = nil }
    }

    private func publish() {
        guard let onSnapshot else { return }
        let snapshot = state
        DispatchQueue.main.async { onSnapshot(snapshot) }
    }

    private func report(_ code: String, recover: Bool) {
        guard let onError else { return }
        DispatchQueue.main.async { onError(code, recover) }
    }

    private enum CameraFailure: Error { case unavailable }
}
