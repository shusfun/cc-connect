// FILE: OnboardingStepPage.swift
// Purpose: Single setup step page with icon, description, and command card.
// Layer: View
// Exports: OnboardingStepPage
// Depends on: SwiftUI, AppFont, OnboardingCommandCard

import SwiftUI

struct OnboardingStepPage: View {
    @Environment(\.locale) private var _localizationLocale

    let stepNumber: Int
    let icon: String
    let title: String
    let description: String
    var command: String? = nil
    var commandCaption: String? = nil

    private let accentGradient = LinearGradient(
        colors: [Color(.plan).opacity(0.35), Color(.plan).opacity(0.08)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    var body: some View {
        let _ = _localizationLocale
        ZStack {
            // Subtle ambient radial glow
            RadialGradient(
                colors: [Color(.plan).opacity(0.06), .clear],
                center: .center,
                startRadius: 20,
                endRadius: 340
            )
            .offset(y: -60)
            .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                VStack(spacing: 36) {
                    // Icon with gradient glow
                    ZStack {
                        // Soft glow behind icon
                        Circle()
                            .fill(
                                RadialGradient(
                                    colors: [Color(.plan).opacity(0.18), .clear],
                                    center: .center,
                                    startRadius: 10,
                                    endRadius: 70
                                )
                            )
                            .frame(width: 140, height: 140)

                        RemodexIcon.image(systemName: icon)
                            .font(.system(size: 32, weight: .light))
                            .foregroundStyle(.white)
                            .frame(width: 80, height: 80)
                            .background(
                                RoundedRectangle(cornerRadius: 22, style: .continuous)
                                    .fill(Color.white.opacity(0.06))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 22, style: .continuous)
                                    .stroke(accentGradient, lineWidth: 1)
                            )
                    }

                    VStack(spacing: 12) {
                        // Step label
                        Text(L10n.format("STEP %@", String(describing: stepNumber)))
                            .font(AppFont.caption2(weight: .bold))
                            .foregroundStyle(Color(.plan).opacity(0.7))
                            .kerning(1.5)

                        Text(title)
                            .font(AppFont.system(size: 28, weight: .bold))

                        Text(description)
                            .font(AppFont.subheadline(weight: .regular))
                            .foregroundStyle(.white.opacity(0.45))
                            .multilineTextAlignment(.center)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let command {
                        VStack(alignment: .leading, spacing: 10) {
                            OnboardingCommandCard(command: command)

                            if let commandCaption, !commandCaption.isEmpty {
                                Text(commandCaption)
                                    .font(AppFont.caption())
                                    .foregroundStyle(.white.opacity(0.45))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .padding(.horizontal, 28)

                Spacer()
            }
        }
    }
}

// MARK: - Previews

#Preview("Mac App Pairing") {
    ZStack {
        Color.black.ignoresSafeArea()
        OnboardingStepPage(
            stepNumber: 1,
            icon: "macbook",
            title: "在 Mac 打开 Remodex",
            description: "Mac App 会启动内置 Bridge 并显示配对二维码。"
        )
    }
    .preferredColorScheme(.dark)
}
