// FILE: SidebarProjectShowMoreButton.swift
// Purpose: Localizes "show more" project-section button UI and animation state.
// Layer: Sidebar UI component
// Exports: SidebarProjectShowMoreButton
// Depends on: SwiftUI, HapticButton

import SwiftUI

struct SidebarProjectShowMoreButton: View {
    @Environment(\.locale) private var _localizationLocale

    let hiddenCount: Int
    let reveal: () -> Void

    @State private var chevronRotated = false

    var body: some View {
        let _ = _localizationLocale
        HapticButton(action: {
            withAnimation(.easeInOut(duration: 0.2)) {
                chevronRotated = true
                reveal()
            }
        }) {
            HStack(spacing: 6) {
                Text(hiddenCount > 0 ? L10n.format("Show %@ more", String(describing: hiddenCount)) : L10n.string("Show more"))
                RemodexIcon.image(systemName: "chevron.down")
                    .font(AppFont.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(chevronRotated ? 180 : 0))
                Spacer(minLength: 0)
            }
            .font(AppFont.caption(weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.leading, 4)
        .padding(.trailing, 12)
        .padding(.top, 6)
        .onAppear { chevronRotated = false }
    }
}
