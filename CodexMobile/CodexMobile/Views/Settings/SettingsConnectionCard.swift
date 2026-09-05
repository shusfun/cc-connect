// FILE: SettingsConnectionCard.swift
// Purpose: Presents paired-computer connection state and connection actions.
// Layer: Settings UI component
// Exports: SettingsConnectionCard
// Depends on: SwiftUI, CodexService connection state, SettingsSupportCards

import SwiftUI

struct SettingsConnectionCard: View {
    @Environment(\.locale) private var _localizationLocale

    @Environment(CodexService.self) private var codex
    let onEditComputerName: () -> Void

    var body: some View {
        let _ = _localizationLocale
        SettingsCard(
            title: L10n.string("Device"),
            footer: L10n.string("Display sleep does not interrupt Remodex. If macOS enters system sleep, remote access stays offline until the Mac wakes.")
        ) {
            if let trustedPairPresentation = codex.trustedPairPresentation {
                SettingsTrustedComputerCard(
                    presentation: trustedPairPresentation,
                    connectionStatusLabel: connectionStatusLabel,
                    isConnected: codex.connectionPhase == .connected,
                    onEditName: onEditComputerName
                )
            } else {
                SettingsInlineMessage(text: L10n.string("No paired device yet. Scan the QR code from your Mac to connect."))
            }

            if connectionPhaseShowsProgress {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text(connectionProgressLabel)
                        .font(AppFont.subheadline())
                        .foregroundStyle(.secondary)
                }
            }

            if case .retrying(_, let message) = codex.connectionRecoveryState,
               !message.isEmpty {
                SettingsInlineMessage(text: message)
            }

            if let error = codex.lastErrorMessage, !error.isEmpty {
                SettingsInlineMessage(text: error, tint: .red)
            }

            if codex.isConnected {
                SettingsButton(L10n.string("Disconnect"), role: .destructive) {
                    HapticFeedback.shared.triggerImpactFeedback()
                    disconnectRelay()
                }
            } else if codex.hasTrustedMacReconnectCandidate {
                SettingsButton(L10n.string("Forget Pair"), role: .destructive) {
                    HapticFeedback.shared.triggerImpactFeedback()
                    codex.forgetTrustedMac()
                }
            }
        }
    }

    private var connectionPhaseShowsProgress: Bool {
        switch codex.connectionPhase {
        case .connecting, .loadingChats, .syncing:
            return true
        case .offline, .connected:
            return false
        }
    }

    private var connectionStatusLabel: String {
        switch codex.connectionPhase {
        case .offline:
            return L10n.string("Offline")
        case .connecting:
            return L10n.string("Connecting")
        case .loadingChats:
            return L10n.string("Loading")
        case .syncing:
            return L10n.string("Syncing")
        case .connected:
            return L10n.string("Connected")
        }
    }

    private var connectionProgressLabel: String {
        switch codex.connectionPhase {
        case .connecting:
            return L10n.string("Connecting to relay…")
        case .loadingChats:
            return L10n.string("Loading chats…")
        case .syncing:
            return L10n.string("Syncing workspace…")
        case .offline, .connected:
            return ""
        }
    }

    private func disconnectRelay() {
        Task { @MainActor in
            await codex.disconnect()
            codex.clearSavedRelaySession()
        }
    }
}
