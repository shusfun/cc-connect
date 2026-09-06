import Darwin
import Foundation

enum ControlProcessFailure: LocalizedError {
    case launch, timeout, cancelled
    case exited(Int32)

    var errorDescription: String? {
        switch self {
        case .launch: return "无法启动 Bridge 控制命令。"
        case .timeout: return "Bridge 控制命令超时，已清理本次命令。"
        case .cancelled: return "Bridge 控制命令已取消。"
        case .exited(let code): return "Bridge 控制命令失败（退出码：\(code)）。"
        }
    }
}

final class AsyncProcessRunner: @unchecked Sendable {
    private let lock = NSLock()
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private var continuation: CheckedContinuation<Void, Error>?
    private var stopReason: ControlProcessFailure?
    private var finished = false
    private var started = false
    private var deadline: DispatchWorkItem?

    init(executable: URL, arguments: [String], directory: URL? = nil, environment: [String: String]? = nil) {
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
    }

    func run(timeout: TimeInterval = 15, initialInput: Data = Data()) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    self.start(continuation, timeout: timeout, initialInput: initialInput)
                }
            }
        } onCancel: {
            self.stop(.cancelled)
        }
    }

    private func start(_ continuation: CheckedContinuation<Void, Error>, timeout: TimeInterval, initialInput: Data) {
        lock.lock()
        guard !started else {
            lock.unlock()
            continuation.resume(throwing: ControlProcessFailure.launch)
            return
        }
        started = true
        self.continuation = continuation
        if let reason = stopReason {
            lock.unlock()
            finish(.failure(reason))
            return
        }
        for pipe in [output, errors] {
            pipe.fileHandleForReading.readabilityHandler = { handle in
                if let data = try? handle.read(upToCount: 65_536), !data.isEmpty { return }
                handle.readabilityHandler = nil
            }
        }
        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            self.lock.lock()
            let reason = self.stopReason
            self.lock.unlock()
            self.finish(reason.map { .failure($0) } ?? (process.terminationStatus == 0 ? .success(()) : .failure(ControlProcessFailure.exited(process.terminationStatus))))
        }
        do {
            try process.run()
            let timer = DispatchWorkItem { [weak self] in self?.stop(.timeout) }
            deadline = timer
            DispatchQueue.global().asyncAfter(deadline: .now() + max(0.01, timeout), execute: timer)
        } catch {
            lock.unlock()
            finish(.failure(ControlProcessFailure.launch))
            return
        }
        lock.unlock()
        do { if !initialInput.isEmpty { try input.fileHandleForWriting.write(contentsOf: initialInput) } }
        catch { stop(.launch) }
    }

    private func stop(_ reason: ControlProcessFailure) {
        lock.lock()
        guard !finished, stopReason == nil else { lock.unlock(); return }
        stopReason = reason
        let running = process.isRunning
        lock.unlock()
        guard running else { return }
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [self] in
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        deadline?.cancel()
        deadline = nil
        let completion = continuation
        continuation = nil
        lock.unlock()
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        for handle in [input.fileHandleForWriting, input.fileHandleForReading, output.fileHandleForWriting, output.fileHandleForReading, errors.fileHandleForWriting, errors.fileHandleForReading] {
            try? handle.close()
        }
        completion?.resume(with: result)
    }
}

@MainActor
final class BridgeOperationQueue {
    private var tail: Task<Void, Never>?
    private var tasks: [UUID: Task<Void, Error>] = [:]
    private var latest: UUID?

    var isBusy: Bool { !tasks.isEmpty }

    func cancel() { for task in tasks.values { task.cancel() } }

    func perform(_ operation: @escaping @MainActor () async throws -> Void) async throws {
        guard tasks.count < 32 else { throw ControlProcessFailure.cancelled }
        let previous = tail
        let identifier = UUID()
        let task = Task { @MainActor in
            await previous?.value
            try Task.checkCancellation()
            try await operation()
        }
        tasks[identifier] = task
        latest = identifier
        tail = Task { _ = try? await task.value }
        defer {
            tasks.removeValue(forKey: identifier)
            if latest == identifier { tail = nil; latest = nil }
        }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}
