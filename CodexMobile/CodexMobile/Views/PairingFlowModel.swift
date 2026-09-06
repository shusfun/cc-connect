import Foundation
import Observation

@MainActor @Observable
final class PairingFlowModel {
    enum Phase { case scanning, verifying, ready, connecting, failed, stopped, completed }
    typealias PreviewLoader = @MainActor (CompactPairingCode, PairingRequestContext) async throws -> CodexPairingQRPayload
    private(set) var phase = Phase.scanning
    private(set) var draft: CompactPairingCode?
    private(set) var verified: CodexPairingQRPayload?
    private(set) var failureCode: String?
    private(set) var generation = UUID()
    let diagnostics = PairingDiagnostics()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var connectionTask: Task<Void, Never>?
    @ObservationIgnored private var context: PairingRequestContext?
    @ObservationIgnored private let loader: PreviewLoader

    init(loader: @escaping PreviewLoader = { try await RelayDeviceAccess.preview($0, context: $1) }) {
        self.loader = loader
    }

    var showsDetails: Bool { phase != .scanning }
    var mayRetryVerification: Bool {
        phase == .failed && context?.submitted != true && !["identity_mismatch", "invitation_expired", "invitation_consumed", "request_expired", "request_consumed"].contains(failureCode ?? "")
    }
    var submitted: Bool { context?.submitted == true }

    func recognize(_ code: CompactPairingCode) {
        guard phase == .scanning else { return }
        draft = code
        diagnostics.identified(relay: code.relay)
        diagnostics.transition(.validation)
        verify()
    }

    func verify() {
        guard let draft, phase == .scanning || mayRetryVerification else { return }
        context?.cancel()
        task?.cancel()
        generation = UUID()
        let epoch = generation
        let requestContext = PairingRequestContext(diagnostics)
        context = requestContext
        phase = .verifying
        verified = nil
        failureCode = nil
        diagnostics.transition(.verification)
        task = Task { [weak self, loader] in
            do {
                let payload = try await loader(draft, requestContext)
                try requestContext.checkCancellation()
                guard let self, self.generation == epoch else { return }
                guard payload.macIdentityPublicKey == draft.publicKey, payload.invitation == draft.invitation, payload.relay == draft.relay else { throw PairingFlowFailure.identityMismatch }
                self.verified = payload
                self.phase = .ready
                self.diagnostics.transition(.confirmation)
            } catch {
                guard let self, self.generation == epoch else { return }
                self.fail(error)
            }
        }
    }

    func confirm(connect: @escaping @MainActor (CodexPairingQRPayload, PairingRequestContext) async throws -> Void) {
        guard phase == .ready, let verified, let context else { return }
        phase = .connecting
        let epoch = generation
        let previousConnection = connectionTask
        task = Task { [weak self] in
            do {
                await previousConnection?.value
                try context.checkCancellation()
                try await connect(verified, context)
                try context.checkCancellation()
                guard let self, self.generation == epoch else { return }
                self.phase = .completed
                self.diagnostics.transition(.completed)
                self.diagnostics.finish("completed")
            } catch {
                guard let self, self.generation == epoch else { return }
                self.fail(error)
            }
        }
        connectionTask = task
    }

    func stop() {
        generation = UUID()
        context?.cancel()
        task?.cancel()
        task = nil
        phase = .stopped
        diagnostics.cancelOutstanding()
    }

    func rescan() {
        stop()
        context = nil
        draft = nil
        verified = nil
        failureCode = nil
        phase = .scanning
        diagnostics.reset()
    }

    func cameraUpdate(_ snapshot: PairingCameraSnapshot) {
        guard phase == .scanning || !snapshot.running else { return }
        diagnostics.cameraUpdate(snapshot)
    }

    private func fail(_ error: Error) {
        failureCode = PairingDiagnostics.failureCode(error)
        phase = failureCode == "cancelled" ? .stopped : .failed
        diagnostics.finish(phase == .stopped ? "cancelled" : "failed", code: failureCode)
    }
}
