// FILE: CodexService+VoiceCompatibility.swift
// Purpose: Maps on-device recording and Whisper failures into stable UI recovery reasons.
// Layer: Service
// Exports: CodexVoiceFailureReason, CodexService voice failure helpers
// Depends on: Foundation, VoiceRecordingError

import Foundation

enum CodexVoiceFailureReason: Equatable {
    case microphonePermissionRequired
    case microphoneUnavailable
    case recorderUnavailable
    case retryAvailable(String)
    case generic(String)
}

extension CodexService {
    func classifyVoiceFailure(_ error: Error) -> CodexVoiceFailureReason {
        if let voiceError = error as? VoiceRecordingError {
            switch voiceError {
            case .microphonePermissionDenied:
                return .microphonePermissionRequired
            case .missingMicrophoneInput:
                return .microphoneUnavailable
            case .unableToConfigureAudioSession,
                 .unableToPrepareAudioEngine,
                 .unableToCreateOutputFile,
                 .alreadyRecording,
                 .notRecording:
                return .recorderUnavailable
            case .transcriptionFailed:
                return .generic(normalizedVoiceErrorMessage(error))
            }
        }

        return .generic(normalizedVoiceErrorMessage(error))
    }

    func resolveVoiceRecoveryReason(_ reason: CodexVoiceFailureReason) -> CodexVoiceFailureReason? {
        reason
    }

    private func normalizedVoiceErrorMessage(_ error: Error) -> String {
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? L10n.string("设备端语音转写失败。") : message
    }
}
