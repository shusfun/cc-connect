// FILE: SettingsView.swift
// Purpose: Settings for Local Mode (Codex runs on the paired computer, relay WebSocket).
// Layer: View
// Exports: SettingsView

import SwiftUI
import UIKit

private struct SettingsComputerNamePresentation: Identifiable, Equatable {
    let deviceId: String?
    let currentName: String
    let systemName: String

    var id: String { deviceId ?? currentName }
}

private enum SettingsSheet: Identifiable, Equatable {
    case computerName(SettingsComputerNamePresentation)
    case voiceModel

    var id: String {
        switch self {
        case .computerName(let presentation):
            return "computerName-\(presentation.id)"
        case .voiceModel:
            return "voiceModel"
        }
    }
}

// One active presentation at a time so sheets and offer-code redemption
// never compete while Settings is already inside a full-screen cover.
private enum SettingsActivePresentation: Equatable {
    case none
    case sheet(SettingsSheet)
}

struct SettingsView: View {
    @Environment(CodexService.self) private var codex
    @AppStorage("codex.appFontStyle") private var appFontStyleRawValue = AppFont.defaultStoredStyleRawValue
    @State private var activePresentation: SettingsActivePresentation = .none
    @State private var isShowingAboutRemodex = false

    var body: some View {
        List {
            SettingsAppearanceCard(appFontStyle: appFontStyleBinding)
            SettingsRuntimeDefaultsCard()
            SettingsBridgeVersionCard()
            SettingsUsageCard()
            SettingsVoiceModelCard {
                presentSettingsSheet(.voiceModel)
            }
            SettingsArchivedChatsCard()
            SettingsAboutCard {
                showAboutRemodex()
            }
            SettingsConnectionCard {
                presentComputerNameSheet()
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(10)
        .font(AppFont.body())
        .tint(.primary)
        .navigationTitle("Settings")
        // Keep the About push anchored to SettingsView so custom List rows do
        // not depend on NavigationLink behavior inside rebuilt sections.
        .navigationDestination(isPresented: $isShowingAboutRemodex) {
            AboutRemodexView()
        }
        .sheet(item: activeSheetBinding) { sheet in
            settingsSheetContent(for: sheet)
        }
    }

    private var activeSheetBinding: Binding<SettingsSheet?> {
        Binding(
            get: {
                if case .sheet(let sheet) = activePresentation {
                    return sheet
                }
                return nil
            },
            set: { newSheet in
                if let newSheet {
                    activePresentation = .sheet(newSheet)
                } else if case .sheet = activePresentation {
                    activePresentation = .none
                }
            }
        )
    }

    @ViewBuilder
    private func settingsSheetContent(for sheet: SettingsSheet) -> some View {
        switch sheet {
        case .computerName(let presentation):
            SettingsComputerNameSheet(
                nickname: sidebarComputerNicknameBinding(for: presentation.deviceId),
                currentName: presentation.currentName,
                systemName: presentation.systemName
            )
        case .voiceModel:
            VoiceModelSetupSheet()
        }
    }

    private func showAboutRemodex() {
        isShowingAboutRemodex = true
    }

    private func presentSettingsSheet(_ sheet: SettingsSheet) {
        activePresentation = .sheet(sheet)
    }


    private var appFontStyleBinding: Binding<AppFont.Style> {
        Binding(
            get: { AppFont.Style(rawValue: appFontStyleRawValue) ?? AppFont.defaultStyle },
            set: { appFontStyleRawValue = $0.rawValue }
        )
    }

    // Captures the visible device details before presenting so reconnect updates cannot dismiss the editor.
    private func presentComputerNameSheet() {
        guard let trustedPairPresentation = codex.trustedPairPresentation else {
            return
        }

        presentSettingsSheet(
            .computerName(
                SettingsComputerNamePresentation(
                    deviceId: trustedPairPresentation.deviceId,
                    currentName: trustedPairPresentation.name,
                    systemName: trustedPairPresentation.systemName ?? trustedPairPresentation.name
                )
            )
        )
    }

    // Writes nicknames against the tapped trusted computer so switching pairs does not reuse the wrong alias.
    private func sidebarComputerNicknameBinding(for deviceId: String?) -> Binding<String> {
        Binding(
            get: { SidebarComputerNicknameStore.nickname(for: deviceId) },
            set: { SidebarComputerNicknameStore.setNickname($0, for: deviceId) }
        )
    }
}

private struct SettingsUsageCard: View {
    @Environment(CodexService.self) private var codex
    @Environment(\.scenePhase) private var scenePhase

    @State private var isRefreshing = false

    var body: some View {
        SettingsCard(
            title: "Usage",
            footer: "Account-wide rate limits from your paired device."
        ) {
            UsageStatusSummaryContent(
                contextWindowUsage: nil,
                showsContextWindowSection: false,
                rateLimitBuckets: codex.rateLimitBuckets,
                isLoadingRateLimits: codex.isLoadingRateLimits,
                rateLimitsErrorMessage: codex.rateLimitsErrorMessage,
                showsRateLimitHeader: false,
                refreshControl: UsageStatusRefreshControl(
                    title: "Refresh",
                    isRefreshing: isRefreshing,
                    action: refreshStatus
                )
            )
        }
        .task {
            await refreshStatusIfNeeded()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                await refreshStatusIfNeeded()
            }
        }
    }

    private func refreshStatus() {
        guard !isRefreshing else { return }
        HapticFeedback.shared.triggerImpactFeedback(style: .light)
        isRefreshing = true

        Task {
            await refreshStatusData()
            await MainActor.run {
                isRefreshing = false
            }
        }
    }

    private func refreshStatusIfNeeded() async {
        guard !isRefreshing else { return }
        guard codex.shouldAutoRefreshUsageStatus(threadId: nil) else { return }

        await MainActor.run {
            isRefreshing = true
        }
        await refreshStatusData()
        await MainActor.run {
            isRefreshing = false
        }
    }

    // Settings only needs the account-wide usage windows.
    private func refreshStatusData() async {
        await codex.refreshUsageStatus(threadId: nil)
    }
}

private struct SettingsAppearanceCard: View {
    @Binding var appFontStyle: AppFont.Style
    @AppStorage(GlassPreference.storageKey) private var useLiquidGlass = true
    @AppStorage(UserBubbleColor.storageKey) private var userBubbleColorRawValue = UserBubbleColor.defaultStoredRawValue
    private let settingsAccentColor = Color.primary

    var body: some View {
        SettingsCard(title: "Appearance") {
            SettingsMenuPickerRow(
                title: "Font",
                value: appFontStyle.title,
                options: AppFont.Style.allCases.map { style in
                    SettingsMenuPickerOption(value: style, title: style.title)
                },
                selection: $appFontStyle
            )

            HStack {
                Text("Message Bubble")
                UIKitMenuButton {
                    HStack {
                        Spacer()
                        Circle()
                            .fill(selectedUserBubbleColor.swatchColor)
                            .frame(width: 14, height: 14)
                    }
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .trailing)
                    .contentShape(Rectangle())
                } menu: {
                    UIMenu(
                        options: [.singleSelection],
                        children: UserBubbleColor.allCases.map { color in
                            UIAction(
                                title: color.title,
                                image: color.menuSwatchImage,
                                state: color == selectedUserBubbleColor ? .on : .off
                            ) { _ in
                                userBubbleColorRawValue = color.rawValue
                            }
                        }
                    )
                }
                .accessibilityLabel("Message Bubble color")
                .accessibilityValue(selectedUserBubbleColor.title)
                .tint(settingsAccentColor)
            }

            if GlassPreference.isSupported {
                Toggle("Liquid Glass", isOn: $useLiquidGlass)
                    .tint(settingsToggleTintColor)
            }

        }
    }

    private var selectedUserBubbleColor: UserBubbleColor {
        UserBubbleColor(rawValue: userBubbleColorRawValue) ?? .default
    }
}

private struct SettingsVoiceModelCard: View {
    let onShowInfo: () -> Void

    var body: some View {
        SettingsCard(title: "离线语音") {
            Button {
                HapticFeedback.shared.triggerImpactFeedback(style: .light)
                onShowInfo()
            } label: {
                SettingsLinkRow(
                    title: "WhisperKit small",
                    subtitle: "在这台 iPhone 上下载、管理和离线转写"
                ) {
                    RemodexIcon.image(systemName: "waveform")
                }
            }
        }
    }
}

private struct SettingsBridgeVersionCard: View {
    @Environment(CodexService.self) private var codex
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        SettingsCard(
            title: "Bridge",
            footer: guidanceText
        ) {
            SettingsValueRow(
                title: "Status",
                value: versionStatusLabel,
                valueColor: versionStatusColor
            )

            SettingsValueRow(
                title: "Installed",
                value: installedVersionLabel,
                valueColor: installedValueStyle,
                usesMonospacedValue: true
            )

        }
        .task {
            await codex.refreshBridgeVersionState()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                await codex.refreshBridgeVersionState()
            }
        }
    }

    private var installedVersionLabel: String {
        normalizedVersion(codex.bridgeInstalledVersion) ?? "Unknown"
    }

    private var guidanceText: String? {
        installedVersion == nil
            ? "连接已配对的 Mac 后读取内置 Bridge 版本。"
            : "Bridge 随 Remodex.app 一起更新，不需要安装全局 CLI。"
    }

    private var versionStatusColor: Color {
        codex.isConnected ? .green : .secondary
    }

    private var versionStatusLabel: String {
        codex.isConnected ? "已连接" : "未连接"
    }

    private var installedValueStyle: Color {
        installedVersion == nil ? .secondary : .primary
    }

    private var installedVersion: String? {
        normalizedVersion(codex.bridgeInstalledVersion)
    }

    private func normalizedVersion(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }

        return trimmed
    }
}

private struct SettingsArchivedChatsCard: View {
    @Environment(CodexService.self) private var codex

    private var archivedCount: Int {
        codex.threads.filter { $0.syncState == .archivedLocal }.count
    }

    var body: some View {
        SettingsCard(title: "Archived") {
            NavigationLink {
                ArchivedChatsView()
            } label: {
                SettingsLinkRow(
                    title: "Archived Chats",
                    subtitle: archivedCount > 0 ? "\(archivedCount) saved locally" : nil,
                    showsDisclosure: false
                ) {
                    RemodexIcon.image(systemName: "archivebox")
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        SettingsView()
            .environment(CodexService())
    }
}
