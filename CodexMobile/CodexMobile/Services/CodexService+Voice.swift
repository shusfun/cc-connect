// FILE: CodexService+Voice.swift
// Purpose: Validates local voice clips and transcribes them entirely on iPhone with WhisperKit.
// Layer: Service
// Exports: CodexVoiceTranscriptionPreflight, CodexService voice helpers
// Depends on: Foundation, WhisperVoiceModelManager

import Foundation

struct CodexVoiceTranscriptionPreflight: Equatable, Sendable {
    static let maxDurationSeconds: TimeInterval = 150
    static let maxByteCount: Int = 10 * 1_024 * 1_024
    private static let maxDurationDisplaySeconds = Int(maxDurationSeconds)

    let byteCount: Int
    let durationSeconds: TimeInterval

    var failureMessage: String? {
        if !durationSeconds.isFinite || durationSeconds <= 0 {
            return L10n.string("语音录音中没有可识别的音频。")
        }
        if durationSeconds > Self.maxDurationSeconds {
            return L10n.format("语音录音不能超过 %@ 秒。", String(describing: Self.maxDurationDisplaySeconds))
        }
        if byteCount > Self.maxByteCount {
            return L10n.string("语音录音不能超过 10 MB。")
        }
        return nil
    }

    func validate() throws {
        if let failureMessage {
            throw CodexServiceError.invalidInput(failureMessage)
        }
    }
}

extension CodexService {
    func prewarmVoiceTranscription() {
        Task { @MainActor in
            await WhisperVoiceModelManager.shared.prewarmIfAvailable()
        }
    }

    var prefersM4AVoiceTranscription: Bool {
        false
    }

    func transcribeVoiceAudioFile(
        at url: URL,
        durationSeconds: TimeInterval,
        mimeType _: String = "audio/wav"
    ) async throws -> String {
        let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey])
        let preflight = CodexVoiceTranscriptionPreflight(
            byteCount: resourceValues.fileSize ?? 0,
            durationSeconds: durationSeconds
        )
        try preflight.validate()
        return try await WhisperVoiceModelManager.shared.transcribe(audioURL: url)
    }
}
