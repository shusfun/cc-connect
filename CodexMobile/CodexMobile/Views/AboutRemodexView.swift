// FILE: AboutRemodexView.swift
// Purpose: Full-screen guide explaining how Remodex works, styled as a blog page.
// Layer: View
// Exports: AboutRemodexView

import SwiftUI

struct AboutRemodexView: View {
    @Environment(\.locale) private var _localizationLocale

    var body: some View {
        let _ = _localizationLocale
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                header
                howItWorksSection
                Divider().opacity(0.3)
                architectureDiagram
                Divider().opacity(0.3)
                relaySection
                Divider().opacity(0.3)
                appServerSection
                Divider().opacity(0.3)
                pairingSection
                Divider().opacity(0.3)
                encryptionSection
                Divider().opacity(0.3)
                gitSection
                Divider().opacity(0.3)
                resilienceSection
                Divider().opacity(0.3)
                desktopSection
                footer
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 40)
        }
        .font(AppFont.body())
        .localizedNavigationTitle("About Remodex")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Header

    @ViewBuilder private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Remodex")
                .font(AppFont.headline(weight: .bold))
                .foregroundStyle(.primary)

            Text("Control **Codex** from your iPhone.")
                .font(AppFont.subheadline())
                .foregroundStyle(.secondary)

            calloutCard(
                icon: "desktopcomputer",
                color: .cyan,
                text: L10n.string("The Codex runtime stays on your device. Your phone is a secure remote control connected through a relay.")
            )
        }
        .padding(.top, 8)
    }

    // MARK: - How It Works

    @ViewBuilder private var howItWorksSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle(L10n.string("How It Works"))

            bodyText(L10n.string("Your device runs a lightweight **bridge** that connects to a **relay server** over WebSocket."))

            bulletList([
                L10n.string("You send a prompt from your phone"),
                L10n.string("It travels through the relay to the bridge on your device"),
                L10n.string("The bridge forwards it to `codex app-server` via JSON-RPC"),
                L10n.string("Responses stream back the same path in real time"),
            ])

            calloutCard(
                icon: "lock.shield.fill",
                color: .green,
                text: L10n.string("All execution happens locally on your device — code generation, tool use, file edits. Nothing runs on the relay.")
            )
        }
    }

    // MARK: - Architecture

    @ViewBuilder private var architectureDiagram: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle(L10n.string("Architecture"))

            VStack(spacing: 0) {
                diagramStep(from: "Remodex iOS", to: L10n.string("Bridge (Device)"), via: "WebSocket")
                diagramStep(from: L10n.string("Bridge (Device)"), to: "codex app-server", via: "JSON-RPC")
                diagramStep(from: "codex app-server", to: "~/.codex/sessions", via: L10n.string("JSONL rollout"), isLast: true)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(.tertiarySystemFill).opacity(0.5))
            )
        }
    }

    @ViewBuilder
    private func diagramStep(from: String, to: String, via: String, isLast: Bool = false) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(from)
                    .font(AppFont.caption(weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .trailing)

                VStack(spacing: 2) {
                    RemodexIcon.image(systemName: "arrow.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                    Text(via)
                        .font(AppFont.caption2())
                        .foregroundStyle(.secondary)
                        .italic()
                }
                .frame(width: 90)

                Text(to)
                    .font(AppFont.caption(weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !isLast {
                Rectangle()
                    .fill(Color.primary.opacity(0.06))
                    .frame(width: 1, height: 14)
            }
        }
    }

    // MARK: - Relay

    @ViewBuilder private var relaySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle(L10n.string("The Relay"))

            bodyText(L10n.string("A lightweight WebSocket server that routes messages between your iPhone and your device."))

            iconRow("arrow.triangle.2.circlepath", L10n.string("Handles session discovery so your phone finds the device's live session"))
            iconRow("eye.slash.fill", L10n.string("Never sees decrypted message contents after the handshake"))
            iconRow("tag.fill", L10n.string("Only observes connection metadata — session IDs, device IDs, timing"))

            Spacer().frame(height: 4)

            bodyText(L10n.string("Relay 只负责设备会合与端到端密文转发；Codex、Git、项目和聊天正文始终留在你的 Mac 与 iPhone。"))
        }
    }

    // MARK: - App-Server

    @ViewBuilder private var appServerSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Codex App-Server")

            bodyText(L10n.string("The bridge spawns a **`codex app-server`** process — the same JSON-RPC interface behind the Codex desktop app and IDE extensions."))

            bulletList([
                L10n.string("Phone conversations are first-class Codex sessions"),
                L10n.string("Produces JSONL rollout files under `~/.codex/sessions/`"),
                L10n.string("Threads started from your phone show up in Codex.app"),
            ])

            calloutCard(
                icon: "point.topleft.down.to.point.bottomright.curvepath",
                color: .orange,
                text: L10n.string("Bridge is managed by the desktop app. Use its connection and diagnostics pages; no global Remodex CLI is required.")
            )
        }
    }

    // MARK: - Pairing

    @ViewBuilder private var pairingSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle(L10n.string("Pairing & Security"))

            bodyText(L10n.string("On first connect, the bridge prints a **QR code** containing:"))

            bulletList([
                L10n.string("The relay URL"),
                L10n.string("The one-time pairing invitation"),
                L10n.string("The bridge's identity public key"),
            ])

            bodyText(L10n.string("Verify the fingerprint, request pairing, and approve this iPhone on the device. The QR code pins the full identity key; it is not the encryption itself."))

            iconRow("checkmark.shield.fill", L10n.string("iPhone saves the bridge as a **trusted device** in Keychain"))
            iconRow("desktopcomputer", L10n.string("Bridge persists your phone's identity locally"))
            iconRow("arrow.clockwise", L10n.string("Later launches auto-reconnect — no QR needed"))

            Spacer().frame(height: 4)

            bodyText(L10n.string("The QR remains available as a recovery path if trust changes or the session can't be resolved."))
        }
    }

    // MARK: - Encryption

    @ViewBuilder private var encryptionSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle(L10n.string("End-to-End Encryption"))

            bodyText(L10n.string("After pairing, every message is wrapped in encrypted envelopes:"))

            specRow(L10n.string("Cipher"), "AES-256-GCM")
            specRow(L10n.string("Key derivation"), L10n.string("HKDF-SHA256, per-direction keys"))
            specRow(L10n.string("Key exchange"), "X25519 ephemeral")
            specRow(L10n.string("Identity"), "Ed25519 signatures")
            specRow(L10n.string("Replay protection"), L10n.string("Monotonic counters"))
            specRow("At-rest (iPhone)", L10n.string("Keychain-backed AES key"))
        }
    }

    // MARK: - Git

    @ViewBuilder private var gitSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Git & Workspace")

            bodyText(L10n.string("The bridge handles **git commands** from your phone locally on the paired device:"))

            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    gitCommand("status")
                    gitCommand("commit")
                    gitCommand("push")
                    gitCommand("pull")
                    gitCommand("branches")
                    gitCommand("checkout")
                }
                VStack(alignment: .leading, spacing: 6) {
                    gitCommand("createBranch")
                    gitCommand("log")
                    gitCommand("stash")
                    gitCommand("stashPop")
                    gitCommand("resetToRemote")
                    gitCommand("remoteUrl")
                }
            }

            Spacer().frame(height: 4)

            bodyText(L10n.string("Also supports **workspace revert** — preview and apply reverse patches when the assistant makes changes you want to undo."))
        }
    }

    // MARK: - Resilience

    @ViewBuilder private var resilienceSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle(L10n.string("Connection Resilience"))

            iconRow("arrow.clockwise", L10n.string("Auto-reconnect with exponential backoff (1s → 5s)"))
            iconRow("envelope.badge.fill", L10n.string("Bounded outbound buffer re-sends missed encrypted messages"))
            iconRow("cpu.fill", L10n.string("Codex process stays alive across transient drops"))
            iconRow("power", L10n.string("SIGINT / SIGTERM trigger clean shutdown"))
        }
    }

    // MARK: - Desktop

    @ViewBuilder private var desktopSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle(L10n.string("Desktop App Integration"))

            bodyText(L10n.string("Threads from your phone are persisted as JSONL rollout files, so they appear in **Codex.app** on your device."))

            calloutCard(
                icon: "macbook.and.iphone",
                color: .blue,
                text: L10n.string("The desktop app doesn't live-reload external writes. Use the desktop app handoff button in Remodex to continue the current thread on your device.")
            )
        }
    }

    // MARK: - Reusable components

    @ViewBuilder
    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(AppFont.headline(weight: .semibold))
            .foregroundStyle(.primary)
    }

    @ViewBuilder
    private func bodyText(_ text: String) -> some View {
        Text(LocalizedStringKey(text))
            .font(AppFont.subheadline())
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func bulletList(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: 10) {
                    Text("->")
                        .font(AppFont.caption(weight: .bold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 18)

                    Text(LocalizedStringKey(item))
                        .font(AppFont.subheadline())
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private func iconRow(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            RemodexIcon.image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )

            Text(LocalizedStringKey(text))
                .font(AppFont.subheadline())
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func specRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(AppFont.caption(weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)

            Text(value)
                .font(AppFont.mono(.caption))
                .foregroundStyle(.primary)
        }
    }

    @ViewBuilder
    private func gitCommand(_ name: String) -> some View {
        Text("git/\(name)")
            .font(AppFont.mono(.caption2))
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func calloutCard(icon: String, color: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            RemodexIcon.image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(color.opacity(0.1))
                )

            Text(LocalizedStringKey(text))
                .font(AppFont.caption())
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.tertiarySystemFill).opacity(0.4))
        )
    }

    // MARK: - Footer

    @ViewBuilder private var footer: some View {
        VStack(spacing: 10) {
            OpenSourceBadge(style: .dark)

            Text("ISC License")
                .font(AppFont.caption())
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }
}

#Preview {
    NavigationStack {
        AboutRemodexView()
    }
}
