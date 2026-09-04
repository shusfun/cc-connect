// FILE: TurnVoicePresentationBuilders.swift
// Purpose: Maps voice recording/auth state into composer and recovery UI presentations.
// Layer: View Support
// Exports: TurnVoiceButtonPresentationBuilder, TurnVoiceRecoveryPresentationBuilder
// Depends on: SwiftUI, TurnComposerVoiceButtonPresentation, ConnectionRecoverySnapshot

import SwiftUI

enum TurnVoiceButtonPresentationBuilder {
    static func presentation(
        isTranscribing: Bool,
        isPreflighting: Bool,
        isRecording: Bool,
        isConnected _: Bool
    ) -> TurnComposerVoiceButtonPresentation {
        if isTranscribing {
            return TurnComposerVoiceButtonPresentation(
                systemImageName: "waveform",
                foregroundColor: Color(.secondaryLabel),
                backgroundColor: Color(.systemGray5),
                accessibilityLabel: "Transcribing voice note",
                isDisabled: true,
                showsProgress: true,
                hasCircleBackground: true
            )
        }

        if isPreflighting {
            return TurnComposerVoiceButtonPresentation(
                systemImageName: "hourglass",
                foregroundColor: Color(.secondaryLabel),
                backgroundColor: Color(.systemGray5),
                accessibilityLabel: "Preparing microphone",
                isDisabled: true,
                showsProgress: true,
                hasCircleBackground: true
            )
        }

        if isRecording {
            return TurnComposerVoiceButtonPresentation(
                systemImageName: "stop.fill",
                foregroundColor: Color(.systemBackground),
                backgroundColor: Color(.systemRed),
                accessibilityLabel: "Stop voice recording",
                isDisabled: false,
                showsProgress: false,
                hasCircleBackground: true
            )
        }

        return TurnComposerVoiceButtonPresentation(
            systemImageName: "mic",
            foregroundColor: Color.primary,
            backgroundColor: .clear,
            accessibilityLabel: "开始设备端离线语音转写",
            isDisabled: false,
            showsProgress: false,
            hasCircleBackground: false
        )
    }
}

enum TurnVoiceRecoveryPresentationBuilder {
    static func presentation(for reason: CodexVoiceFailureReason) -> VoiceRecoveryPresentation {
        switch reason {
        case .microphonePermissionRequired:
            return VoiceRecoveryPresentation(
                snapshot: snapshot(
                    summary: "Microphone access is off for Remodex.",
                    detail: "Open iPhone Settings, allow Microphone for Remodex, then try recording again.",
                    status: .actionRequired,
                    trailingStyle: .action("Open Settings")
                ),
                action: .openSystemSettings
            )
        case .microphoneUnavailable:
            return VoiceRecoveryPresentation(
                snapshot: snapshot(
                    summary: "No microphone input is available right now.",
                    detail: "Check that another app is not holding the microphone, then try again.",
                    status: .actionRequired,
                    trailingStyle: .none
                ),
                action: .none
            )
        case .recorderUnavailable:
            return VoiceRecoveryPresentation(
                snapshot: snapshot(
                    summary: "Remodex could not start the recorder.",
                    detail: "Close other audio-heavy apps, then try voice mode again.",
                    status: .actionRequired,
                    trailingStyle: .none
                ),
                action: .none
            )
        case .retryAvailable(let message):
            return VoiceRecoveryPresentation(
                snapshot: snapshot(
                    summary: message.isEmpty ? "设备端语音转写失败。" : message,
                    detail: "录音已加密保留 24 小时，可直接重试，不会自动发送。",
                    status: .actionRequired,
                    trailingStyle: .action("重试")
                ),
                action: .retryVoice
            )
        case .generic(let message):
            return VoiceRecoveryPresentation(
                snapshot: ConnectionRecoverySnapshot(
                    title: "Voice Mode",
                    summary: message,
                    status: .actionRequired,
                    trailingStyle: .none
                ),
                action: .none
            )
        }
    }

    private static func snapshot(
        summary: String,
        detail: String? = nil,
        status: ConnectionRecoveryStatus,
        trailingStyle: ConnectionRecoveryTrailingStyle
    ) -> ConnectionRecoverySnapshot {
        ConnectionRecoverySnapshot(
            title: "Voice Mode",
            summary: summary,
            detail: detail,
            status: status,
            trailingStyle: trailingStyle
        )
    }
}
