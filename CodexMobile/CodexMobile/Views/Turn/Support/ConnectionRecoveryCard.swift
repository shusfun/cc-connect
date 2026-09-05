// FILE: ConnectionRecoveryCard.swift
// Purpose: Shows compact recovery guidance above the composer using the shared glass accessory style.
// Layer: View Component
// Exports: ConnectionRecoveryCard, ConnectionRecoverySnapshot, ConnectionRecoveryStatus, ConnectionRecoveryTrailingStyle
// Depends on: SwiftUI, PlanAccessoryCard, AppFont

import SwiftUI

enum ConnectionRecoveryStatus: Equatable {
    case interrupted
    case reconnecting
    case actionRequired
    case syncing

    var label: String {
        switch self {
        case .interrupted:
            return L10n.string("Interrupted")
        case .reconnecting:
            return L10n.string("Reconnecting")
        case .actionRequired:
            return L10n.string("Action Needed")
        case .syncing:
            return L10n.string("Syncing")
        }
    }

    var tint: Color {
        switch self {
        case .interrupted:
            return .orange
        case .reconnecting:
            return Color(.plan)
        case .actionRequired:
            return .orange
        case .syncing:
            return Color(.plan)
        }
    }
}

enum ConnectionRecoveryTrailingStyle: Equatable {
    case action(String)
    case progress
    case none
}

struct ConnectionRecoverySnapshot: Equatable {
    let title: String
    let summary: String
    let detail: String?
    let status: ConnectionRecoveryStatus
    let trailingStyle: ConnectionRecoveryTrailingStyle

    init(
        title: String = L10n.string("Connection"),
        summary: String,
        detail: String? = nil,
        status: ConnectionRecoveryStatus,
        trailingStyle: ConnectionRecoveryTrailingStyle
    ) {
        self.title = title
        self.summary = summary
        self.detail = detail
        self.status = status
        self.trailingStyle = trailingStyle
    }

    var isActionable: Bool {
        if case .action = trailingStyle {
            return true
        }
        return false
    }
}

struct ConnectionRecoveryCard: View {
    @Environment(\.locale) private var _localizationLocale

    let snapshot: ConnectionRecoverySnapshot
    let onTap: () -> Void
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        let _ = _localizationLocale
        GlassAccessoryCard(onTap: {
            guard snapshot.isActionable else { return }
            onTap()
        }) {
            leadingMarker
        } header: {
            headerRow
        } summary: {
            summaryRow
        } trailing: {
            trailingContent
        }
        .overlay(alignment: .topTrailing) {
            if let onDismiss {
                dismissButton(action: onDismiss)
            }
        }
        .opacity(snapshot.isActionable ? 1 : 0.94)
        .accessibilityLabel(snapshot.title)
        .accessibilityValue(snapshot.status.label)
        .accessibilityHint(snapshot.isActionable ? L10n.string("Opens the suggested recovery action") : L10n.string("Shows the current recovery status"))
    }

    private var leadingMarker: some View {
        ZStack {
            Circle()
                .fill(snapshot.status.tint.opacity(0.1))
                .frame(width: 22, height: 22)

            Circle()
                .fill(snapshot.status.tint)
                .frame(width: 7, height: 7)
        }
    }

    private var headerRow: some View {
        HStack(alignment: .center, spacing: 6) {
            Text(snapshot.title)
                .font(AppFont.caption2())
                .foregroundStyle(.secondary)

            Circle()
                .fill(Color(.separator).opacity(0.6))
                .frame(width: 3, height: 3)

            Text(snapshot.status.label)
                .font(AppFont.caption(weight: .regular))
                .foregroundStyle(snapshot.status.tint)
        }
    }

    private var summaryRow: some View {
        VStack(alignment: .leading, spacing: snapshot.detail == nil ? 0 : 4) {
            Text(snapshot.summary)
                .font(AppFont.subheadline(weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            if let detail = snapshot.detail {
                Text(detail)
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
            }
        }
    }

    private var trailingContent: some View {
        Group {
            switch snapshot.trailingStyle {
            case .action(let actionTitle):
                Text(actionTitle)
                    .font(AppFont.caption(weight: .semibold))
                    .foregroundStyle(snapshot.status.tint)
            case .progress:
                ProgressView()
                    .controlSize(.mini)
                    .tint(snapshot.status.tint)
            case .none:
                EmptyView()
            }
        }
        .frame(minWidth: 58, alignment: .trailing)
    }

    // The icon stays small, but the tap target meets the 44pt HIG minimum so
    // dismiss taps stop falling through to the card's own button underneath.
    private func dismissButton(action: @escaping () -> Void) -> some View {
        Button {
            HapticFeedback.shared.triggerImpactFeedback(style: .light)
            action()
        } label: {
            RemodexIcon.image(systemName: "xmark")
                .font(AppFont.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Dismiss")
    }
}
