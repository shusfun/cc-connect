// FILE: SelectableMessageTextSheet.swift
// Purpose: Presents stable selectable snapshots for timeline text that cannot select inline.
// Layer: View Component
// Exports: SelectableMessageTextSheetState, SelectableMessageTextSheet
// Depends on: SwiftUI, TurnMarkdownTextRendering

import SwiftUI

enum SelectableMessageTextSheetContentKind {
    case systemPlainText
    case streamingAssistantMarkdown

    var title: String {
        switch self {
        case .systemPlainText:
            return L10n.string("System Message")
        case .streamingAssistantMarkdown:
            return L10n.string("Assistant Message")
        }
    }
}

// Settled assistant rows select inline; streaming rows use a stable sheet so
// selection does not compete with the live markdown reveal.
struct SelectableMessageTextSheetState: Identifiable {
    let id = UUID()
    let contentKind: SelectableMessageTextSheetContentKind
    let text: String
}

struct SelectableMessageTextSheet: View {
    @Environment(\.locale) private var _localizationLocale

    let state: SelectableMessageTextSheetState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let _ = _localizationLocale
        NavigationStack {
            ScrollView {
                selectableContent
                    .padding(16)
            }
            .navigationTitle(state.contentKind.title)
            .navigationBarTitleDisplayMode(.inline)
            .adaptiveNavigationBar()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private var selectableContent: some View {
        switch state.contentKind {
        case .systemPlainText:
            Text(state.text)
                .font(AppFont.body())
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .streamingAssistantMarkdown:
            MarkdownTextView(
                text: state.text,
                profile: .assistantProse,
                enablesSelection: true
            )
        }
    }
}
