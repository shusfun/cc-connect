// FILE: TerminalConnectionEditorSheet.swift
// Purpose: Owns the SSH connection editor sheet and its form sections.
// Layer: View Component
// Exports: TerminalConnectionEditorSheet
// Depends on: SwiftUI, UIKit, RemodexTerminalModels, RemodexTerminalPrivateKeyStore

import SwiftUI
import UIKit

struct TerminalConnectionEditorSheet: View {
    @Environment(\.locale) private var _localizationLocale

    @Environment(\.dismiss) private var dismiss
    @Binding var profile: RemodexTerminalProfile
    @Binding var connection: String
    @Binding var privateKey: String
    @Binding var passphrase: String

    let canSave: Bool
    let onSave: () -> Void
    let onResetKnownHost: () -> Void

    @State private var isShowingAdvanced = false
    @State private var isShowingKeyEditor = false
    @State private var isConfirmingKnownHostReset = false
    @State private var isShowingConnectionHelp = false

    private var keyLabel: String {
        RemodexTerminalPrivateKeyStore.hasPrivateKey(privateKey) ? L10n.string("Imported") : L10n.string("Import")
    }

    private var advancedLabel: String {
        profile.port == 22 ? L10n.string("Default") : L10n.string("Custom")
    }

    private var isAdvancedVisible: Bool {
        isShowingAdvanced
            || profile.port != 22
    }

    private var portBinding: Binding<String> {
        Binding(
            get: { String(profile.port) },
            set: { value in
                if let parsedPort = Int(value) {
                    profile.port = max(1, min(65535, parsedPort))
                }
            }
        )
    }

    var body: some View {
        let _ = _localizationLocale
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    TerminalEditorSection(title: L10n.string("Connection")) {
                        TerminalConnectionStringField(connection: $connection)
                    }

                    TerminalEditorSection(title: L10n.string("Nickname")) {
                        TerminalRoundedTextField(
                            placeholder: L10n.string("Nickname"),
                            text: $profile.nickname
                        )
                    }

                    TerminalAuthenticationSection(
                        keyLabel: keyLabel,
                        privateKey: $privateKey,
                        passphrase: $passphrase,
                        isShowingKeyEditor: $isShowingKeyEditor
                    )

                    TerminalSSHSection(
                        profile: $profile,
                        portBinding: portBinding,
                        isShowingAdvanced: $isShowingAdvanced,
                        isConfirmingKnownHostReset: $isConfirmingKnownHostReset,
                        advancedLabel: advancedLabel,
                        isAdvancedVisible: isAdvancedVisible
                    )
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 22)
            }
            .localizedNavigationTitle("New Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        HapticFeedback.shared.triggerImpactFeedback(style: .light)
                        isShowingConnectionHelp = true
                    } label: {
                        RemodexIcon.image(systemName: "questionmark.circle")
                            .font(.system(size: 17, weight: .medium))
                    }
                    .accessibilityLabel("SSH setup guide")

                    Button("Connect", action: onSave)
                        .font(AppFont.system(size: 15, weight: .bold))
                        .disabled(!canSave)
                }
            }
            .sheet(isPresented: $isShowingConnectionHelp) {
                TerminalConnectionHelpSheet()
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .confirmationDialog(
                L10n.string("Reset saved SSH host key?"),
                isPresented: $isConfirmingKnownHostReset,
                titleVisibility: .visible
            ) {
                Button("Reset Host Key", role: .destructive, action: onResetKnownHost)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The next connection to this host will trust the key it presents.")
            }
        }
    }
}

private struct TerminalAuthenticationSection: View {
    @Environment(\.locale) private var _localizationLocale

    let keyLabel: String
    @Binding var privateKey: String
    @Binding var passphrase: String
    @Binding var isShowingKeyEditor: Bool

    var body: some View {
        let _ = _localizationLocale
        TerminalEditorSection(title: L10n.string("Authentication")) {
            VStack(spacing: 0) {
                TerminalEditorRow(title: L10n.string("Method"), value: L10n.string("SSH Key"))
                Divider()
                Button(action: toggleKeyEditor) {
                    TerminalEditorRow(
                        title: L10n.string("SSH Key"),
                        value: keyLabel,
                        showsChevron: true
                    )
                }
                .buttonStyle(.plain)

                if isShowingKeyEditor || !RemodexTerminalPrivateKeyStore.hasPrivateKey(privateKey) {
                    TerminalPrivateKeyEditor(privateKey: $privateKey, passphrase: $passphrase)
                        .padding(.top, 14)
                }
            }
            .padding(16)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
        }
    }

    private func toggleKeyEditor() {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
            isShowingKeyEditor.toggle()
        }
    }
}

private struct TerminalSSHSection: View {
    @Environment(\.locale) private var _localizationLocale

    @Binding var profile: RemodexTerminalProfile
    let portBinding: Binding<String>
    @Binding var isShowingAdvanced: Bool
    @Binding var isConfirmingKnownHostReset: Bool
    let advancedLabel: String
    let isAdvancedVisible: Bool

    var body: some View {
        let _ = _localizationLocale
        TerminalEditorSection(title: "SSH") {
            VStack(spacing: 0) {
                Button(action: toggleAdvanced) {
                    TerminalEditorRow(
                        title: L10n.string("Advanced Configuration"),
                        value: advancedLabel,
                        showsChevron: true
                    )
                }
                .buttonStyle(.plain)

                if isAdvancedVisible {
                    Divider()
                    TerminalTextField(
                        title: L10n.string("Port"),
                        text: portBinding,
                        placeholder: "22",
                        keyboardType: .numberPad
                    )
                    .padding(.top, 14)
                }

                Divider()
                Button {
                    isConfirmingKnownHostReset = true
                } label: {
                    TerminalEditorRow(
                        title: L10n.string("Known Host"),
                        value: L10n.string("Reset")
                    )
                }
                .buttonStyle(.plain)
                .disabled(profile.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(16)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
        }
    }

    private func toggleAdvanced() {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
            isShowingAdvanced.toggle()
        }
    }
}
