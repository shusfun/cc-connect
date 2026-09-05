// FILE: WhatsNewSheet.swift
// Purpose: Lightweight root sheet that summarizes one release's notable improvements.
// Layer: View
// Exports: WhatsNewSheet
// Depends on: SwiftUI, AppFont

import SwiftUI

private struct WhatsNewItem {
    let title: String
    let detail: String
}

private let whatsNewItems: [WhatsNewItem] = [
    .init(
        title: L10n.string("Live Desktop Sync"),
        detail: L10n.string("Keep messages, models, queues, approvals, unread status, and active conversations synchronized between Remodex and Codex Desktop.")
    ),
    .init(
        title: L10n.string("Approve for Me"),
        detail: L10n.string("Let Codex review approval requests automatically, see what access is needed, and retry denied actions with one tap.")
    ),
    .init(
        title: L10n.string("Goals"),
        detail: L10n.string("Create long-running goals, track progress and token budgets, pause or resume work, and receive completion notifications.")
    ),
    .init(
        title: L10n.string("Smarter Worktrees"),
        detail: L10n.string("Choose any base branch, carry configured project files into new worktrees, and keep worktree chats grouped under their original project.")
    ),
    .init(
        title: L10n.string("Better Model Controls"),
        detail: L10n.string("Use the redesigned model and intelligence picker with Fast Mode, an all-models browser, and automatic reloading.")
    ),
    .init(
        title: L10n.string("Redesigned Composer"),
        detail: L10n.string("Manage queued prompts, active plans, file changes, and skill mentions through cleaner, more compact controls.")
    ),
    .init(
        title: L10n.string("Better Markdown"),
        detail: L10n.string("Enjoy Markdown in your own messages and faster, smoother streaming responses.")
    ),
    .init(
        title: L10n.string("Clearer Tool Activity"),
        detail: L10n.string("Commands and tool calls are now grouped, expandable, and easier to follow with improved icons, statuses, history, and file changes.")
    ),
    .init(
        title: L10n.string("Smarter Sidebar"),
        detail: L10n.string("Find active and unread chats faster with improved sorting, status indicators, and automation labels.")
    ),
    .init(
        title: L10n.string("Reliable Recovery"),
        detail: L10n.string("Pairing, reconnects, and running chats now recover more reliably after sleep, relaunch, bridge restarts, or network loss.")
    ),
    .init(
        title: L10n.string("Cleaner Timelines"),
        detail: L10n.string("Duplicate messages, reasoning, final answers, and stale tool activity have been reduced, with smoother scrolling and history restoration.")
    ),
    .init(
        title: L10n.string("Improved Terminal"),
        detail: L10n.string("Select and copy terminal output, with refreshed native menus across Terminal, Settings, Git, and chat controls.")
    ),
    .init(
        title: L10n.string("Better Voice Input"),
        detail: L10n.string("Voice transcription is faster and more reliable, with smoother recording animations.")
    ),
    .init(
        title: L10n.string("Fresh New Look"),
        detail: L10n.string("A new Remodex icon and unified visual identity, plus an SF Pro Rounded font option.")
    ),
    .init(
        title: L10n.string("More Reliable Workflows"),
        detail: L10n.string("Plan Mode, completed steps, message sending, attachments, and long-running sessions are now more dependable.")
    ),
    .init(
        title: L10n.string("Performance and Stability"),
        detail: L10n.string("Cleaner Mac bridge removal, fixed service restart loops, and many additional synchronization, performance, and stability improvements.")
    ),
]

struct WhatsNewSheet: View {
    @Environment(\.locale) private var _localizationLocale

    let version: String
    let onDismiss: () -> Void

    var body: some View {
        let _ = _localizationLocale
        NavigationStack {
            ZStack(alignment: .bottom) {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 24) {
                        header
                        featureList
                        visibilityNote
                    }
                    .padding(24)
                    .padding(.bottom, 140)
                }

                pinnedDismissButton
            }
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What's New")
                .font(AppFont.title2(weight: .bold))

            Text("Remodex \(version)")
                .font(AppFont.mono(.subheadline))
                .foregroundStyle(.secondary)

            Text("Here’s what changed in this build.")
                .font(AppFont.body())
                .foregroundStyle(.secondary)
        }
    }

    private var featureList: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(whatsNewItems.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 12) {
                    Circle()
                        .fill(.secondary)
                        .frame(width: 5, height: 5)
                        .padding(.top, 8)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(item.title):")
                            .font(AppFont.body(weight: .semibold))
                            .foregroundStyle(.primary)

                        Text(item.detail)
                            .font(AppFont.body())
                            .foregroundStyle(.primary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var visibilityNote: some View {
        Text("We'll only show this once for each app version.")
            .font(AppFont.caption())
            .foregroundStyle(.secondary)
    }

    private var pinnedDismissButton: some View {
        VStack(spacing: 0) {
            LinearGradient(
                colors: [
                    Color(.systemBackground).opacity(0),
                    Color(.systemBackground).opacity(0.92),
                    Color(.systemBackground)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 64)
            .allowsHitTesting(false)

            PrimaryCapsuleButton(title: L10n.string("Got It")) {
                onDismiss()
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            .background(Color(.systemBackground))
        }
    }
}
