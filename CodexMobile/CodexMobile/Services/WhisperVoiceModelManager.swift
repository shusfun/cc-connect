// FILE: WhisperVoiceModelManager.swift
// Purpose: Owns the on-device WhisperKit small model, download lifecycle, and encrypted retry clips.
// Layer: Service
// Exports: WhisperVoiceModelManager, WhisperVoiceModelState, WhisperVoiceRetryStore
// Depends on: CryptoKit, Foundation, Network, WhisperKit

import Combine
import CryptoKit
import Foundation
import Network
import WhisperKit

enum WhisperVoiceModelState: Equatable {
    case missing
    case checking
    case downloading
    case paused
    case loading
    case ready
    case failed(String)
}

enum WhisperVoiceError: LocalizedError {
    case modelRequired
    case cellularConfirmationRequired
    case insufficientStorage(requiredBytes: Int64, availableBytes: Int64)
    case emptyTranscript
    case retryClipUnavailable

    var errorDescription: String? {
        switch self {
        case .modelRequired:
            return L10n.string("请先下载设备端 Whisper small 多语言模型。")
        case .cellularConfirmationRequired:
            return L10n.string("当前使用蜂窝网络，需要确认后才能下载语音模型。")
        case .insufficientStorage(let requiredBytes, let availableBytes):
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            return L10n.format("存储空间不足：至少需要 %@，当前可用 %@。", String(describing: formatter.string(fromByteCount: requiredBytes)), String(describing: formatter.string(fromByteCount: availableBytes)))
        case .emptyTranscript:
            return L10n.string("没有识别到可插入的语音内容。")
        case .retryClipUnavailable:
            return L10n.string("没有可重试的语音录音。")
        }
    }
}

@MainActor
final class WhisperVoiceModelManager: ObservableObject {
    static let shared = WhisperVoiceModelManager()
    static let modelVariant = "small"
    static let estimatedDownloadBytes: Int64 = 550 * 1_024 * 1_024
    static let requiredFreeBytes: Int64 = 1_500 * 1_024 * 1_024

    @Published private(set) var state: WhisperVoiceModelState
    @Published private(set) var downloadFraction: Double = 0
    @Published private(set) var usesCellular = false

    private let fileManager = FileManager.default
    private let defaults = UserDefaults.standard
    private let modelFolderDefaultsKey = "remodex.whisper.small.modelFolder"
    private var model: WhisperKit?
    private var downloadTask: Task<Void, Never>?
    private var downloadProgress: Progress?

    private init() {
        state = Self.persistedModelFolder() == nil ? .missing : .ready
        WhisperVoiceRetryStore.shared.removeExpired()
    }

    var isReady: Bool {
        state == .ready
    }

    var availableStorageBytes: Int64 {
        let values = try? applicationSupportDirectory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    func startDownload(allowCellular: Bool) {
        guard downloadTask == nil else { return }
        downloadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.downloadTask = nil }
            do {
                try await self.downloadModel(allowCellular: allowCellular)
            } catch is CancellationError {
                self.state = .missing
            } catch {
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    func pauseDownload() {
        downloadProgress?.pause()
        state = .paused
    }

    func resumeDownload() {
        downloadProgress?.resume()
        state = .downloading
    }

    func cancelDownload() {
        downloadProgress?.cancel()
        downloadTask?.cancel()
        downloadTask = nil
        downloadProgress = nil
        downloadFraction = 0
        state = .missing
    }

    func prewarmIfAvailable() async {
        guard Self.persistedModelFolder() != nil, model == nil else { return }
        try? await loadPersistedModel()
    }

    func transcribe(audioURL: URL) async throws -> String {
        if model == nil {
            try await loadPersistedModel()
        }
        guard let model else {
            throw WhisperVoiceError.modelRequired
        }

        let results = try await model.transcribe(
            audioPath: audioURL.path,
            decodeOptions: DecodingOptions(language: nil, detectLanguage: true)
        )
        let text = results
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw WhisperVoiceError.emptyTranscript
        }
        return text
    }

    private func downloadModel(allowCellular: Bool) async throws {
        state = .checking
        let path = await VoiceDownloadNetworkPath.current()
        usesCellular = path.usesInterfaceType(.cellular)
        if usesCellular && !allowCellular {
            throw WhisperVoiceError.cellularConfirmationRequired
        }

        try fileManager.createDirectory(at: modelBaseDirectory, withIntermediateDirectories: true)
        let available = availableStorageBytes
        guard available == 0 || available >= Self.requiredFreeBytes else {
            throw WhisperVoiceError.insufficientStorage(
                requiredBytes: Self.requiredFreeBytes,
                availableBytes: available
            )
        }

        state = .downloading
        let folder = try await WhisperKit.download(
            variant: Self.modelVariant,
            downloadBase: modelBaseDirectory,
            useBackgroundSession: true,
            progressCallback: { [weak self] progress in
                Task { @MainActor in
                    self?.downloadProgress = progress
                    self?.downloadFraction = progress.fractionCompleted
                }
            }
        )
        try Task.checkCancellation()
        defaults.set(folder.path, forKey: modelFolderDefaultsKey)
        downloadFraction = 1
        try await loadModel(at: folder)
    }

    private func loadPersistedModel() async throws {
        guard let folder = Self.persistedModelFolder() else {
            state = .missing
            throw WhisperVoiceError.modelRequired
        }
        try await loadModel(at: folder)
    }

    private func loadModel(at folder: URL) async throws {
        state = .loading
        let configuration = WhisperKitConfig(
            model: Self.modelVariant,
            modelFolder: folder.path,
            verbose: false,
            prewarm: true,
            load: true,
            download: false
        )
        model = try await WhisperKit(configuration)
        state = .ready
    }

    private var modelBaseDirectory: URL {
        applicationSupportDirectory
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "cn.syggu.remodex", isDirectory: true)
            .appendingPathComponent("WhisperKit", isDirectory: true)
    }

    private var applicationSupportDirectory: URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
    }

    private static func persistedModelFolder() -> URL? {
        guard let path = UserDefaults.standard.string(forKey: "remodex.whisper.small.modelFolder"),
              FileManager.default.fileExists(atPath: path) else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}

private enum VoiceDownloadNetworkPath {
    static func current() async -> NWPath {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let queue = DispatchQueue(label: "cn.syggu.remodex.whisper-network")
            let lock = NSLock()
            var completed = false
            monitor.pathUpdateHandler = { path in
                lock.lock()
                guard !completed else {
                    lock.unlock()
                    return
                }
                completed = true
                lock.unlock()
                monitor.cancel()
                continuation.resume(returning: path)
            }
            monitor.start(queue: queue)
        }
    }
}

struct WhisperVoiceRetryClip: Codable, Sendable {
    let id: UUID
    let createdAt: Date
    let mimeType: String
    let durationSeconds: TimeInterval
    let audioData: Data
}

nonisolated final class WhisperVoiceRetryStore: @unchecked Sendable {
    static let shared = WhisperVoiceRetryStore()
    static let retentionSeconds: TimeInterval = 24 * 60 * 60

    private let fileManager = FileManager.default
    private let directoryOverride: URL?
    private let keyProvider: @Sendable () throws -> SymmetricKey

    init(
        directory: URL? = nil,
        keyProvider: @escaping @Sendable () throws -> SymmetricKey = {
            CodexLocalPersistenceKeyProvider.historyKey()
        }
    ) {
        directoryOverride = directory
        self.keyProvider = keyProvider
    }

    var hasRetryableClip: Bool {
        latestStoredURL() != nil
    }

    @discardableResult
    func retain(_ clip: VoiceRecordingClip) throws -> UUID {
        removeExpired()
        let value = WhisperVoiceRetryClip(
            id: UUID(),
            createdAt: Date(),
            mimeType: clip.mimeType,
            durationSeconds: clip.durationSeconds,
            audioData: try Data(contentsOf: clip.url)
        )
        let plaintext = try JSONEncoder().encode(value)
        let sealed = try AES.GCM.seal(plaintext, using: keyProvider())
        guard let combined = sealed.combined else {
            throw WhisperVoiceError.retryClipUnavailable
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try combined.write(to: storedURL(for: value.id), options: [.atomic, .completeFileProtection])
        return value.id
    }

    func latest() throws -> (clip: WhisperVoiceRetryClip, fileURL: URL) {
        removeExpired()
        guard let storedURL = latestStoredURL() else {
            throw WhisperVoiceError.retryClipUnavailable
        }
        let sealed = try AES.GCM.SealedBox(combined: Data(contentsOf: storedURL))
        let plaintext = try AES.GCM.open(sealed, using: keyProvider())
        let clip = try JSONDecoder().decode(WhisperVoiceRetryClip.self, from: plaintext)
        let fileURL = fileManager.temporaryDirectory
            .appendingPathComponent("remodex-voice-retry-\(clip.id.uuidString)")
            .appendingPathExtension(clip.mimeType == "audio/mp4" ? "m4a" : "wav")
        try clip.audioData.write(to: fileURL, options: [.atomic, .completeFileProtection])
        return (clip, fileURL)
    }

    func discard(_ id: UUID) {
        try? fileManager.removeItem(at: storedURL(for: id))
    }

    func removeExpired(now: Date = Date()) {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for url in urls {
            let modifiedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if modifiedAt == nil || now.timeIntervalSince(modifiedAt!) >= Self.retentionSeconds {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    private func latestStoredURL() -> URL? {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        return urls.max { lhs, rhs in
            let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return left < right
        }
    }

    private var directory: URL {
        if let directoryOverride {
            return directoryOverride
        }
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "cn.syggu.remodex", isDirectory: true)
            .appendingPathComponent("voice-retry", isDirectory: true)
    }

    private func storedURL(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension("voiceclip")
    }
}
