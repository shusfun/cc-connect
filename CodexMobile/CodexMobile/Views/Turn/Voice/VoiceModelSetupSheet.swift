// FILE: VoiceModelSetupSheet.swift
// Purpose: Manages the first-use download and lifecycle of the on-device Whisper small model.
// Layer: View
// Exports: VoiceModelSetupSheet
// Depends on: SwiftUI, WhisperVoiceModelManager

import SwiftUI

struct VoiceModelSetupSheet: View {
    @Environment(\.locale) private var _localizationLocale

    @ObservedObject private var manager = WhisperVoiceModelManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsCellularDownload = false

    var body: some View {
        let _ = _localizationLocale
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("设备端离线语音")
                            .font(AppFont.headline())
                        Text("WhisperKit small 多语言模型只在这台 iPhone 上运行，录音不会发送到 Mac、Relay 或模型服务。")
                            .font(AppFont.caption())
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    RemodexIcon.image(systemName: "waveform.badge.mic")
                        .font(.system(size: 22, weight: .semibold))
                        .frame(width: 44, height: 44)
                }

                VStack(alignment: .leading, spacing: 10) {
                    detailRow(title: L10n.string("下载大小"), value: formattedBytes(WhisperVoiceModelManager.estimatedDownloadBytes))
                    detailRow(title: L10n.string("空间要求"), value: formattedBytes(WhisperVoiceModelManager.requiredFreeBytes))
                    detailRow(title: L10n.string("可用空间"), value: formattedBytes(manager.availableStorageBytes))
                    detailRow(title: L10n.string("保留规则"), value: L10n.string("失败录音加密保留 24 小时"))
                }

                stateContent

                Spacer(minLength: 0)
            }
            .padding(20)
            .navigationTitle("离线语音模型")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        RemodexIcon.image(systemName: "xmark")
                    }
                    .accessibilityLabel("关闭")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .confirmationDialog(
            L10n.string("使用蜂窝网络下载？"),
            isPresented: $confirmsCellularDownload,
            titleVisibility: .visible
        ) {
            Button("本次允许蜂窝下载") {
                manager.startDownload(allowCellular: true)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(L10n.format("模型约占 %@，此次确认不会改变系统网络设置。", String(describing: formattedBytes(WhisperVoiceModelManager.estimatedDownloadBytes))))
        }
    }

    @ViewBuilder
    private var stateContent: some View {
        switch manager.state {
        case .missing:
            primaryButton(title: L10n.string("通过 Wi-Fi 下载"), icon: "arrow.down.circle") {
                manager.startDownload(allowCellular: false)
            }
            Button("改用蜂窝网络") {
                confirmsCellularDownload = true
            }
            .buttonStyle(.bordered)
            .frame(minHeight: 44)
        case .checking:
            progressLine(title: L10n.string("正在检查网络和存储空间"), fraction: nil)
        case .downloading:
            progressLine(title: L10n.string("正在下载模型"), fraction: manager.downloadFraction)
            HStack {
                Button {
                    manager.pauseDownload()
                } label: {
                    Label("暂停", systemImage: "pause.fill")
                }
                Button(role: .destructive) {
                    manager.cancelDownload()
                } label: {
                    Label("取消", systemImage: "xmark")
                }
            }
            .buttonStyle(.bordered)
            .frame(minHeight: 44)
        case .paused:
            progressLine(title: L10n.string("下载已暂停"), fraction: manager.downloadFraction)
            HStack {
                Button {
                    manager.resumeDownload()
                } label: {
                    Label("继续", systemImage: "play.fill")
                }
                Button(role: .destructive) {
                    manager.cancelDownload()
                } label: {
                    Label("取消", systemImage: "xmark")
                }
            }
            .buttonStyle(.bordered)
            .frame(minHeight: 44)
        case .loading:
            progressLine(title: L10n.string("正在加载并预热模型"), fraction: nil)
        case .ready:
            Label("模型已就绪，可在飞行模式下转写", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            primaryButton(title: L10n.string("完成"), icon: "checkmark") {
                dismiss()
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(AppFont.caption())
                .foregroundStyle(.red)
            HStack {
                Button {
                    manager.startDownload(allowCellular: false)
                } label: {
                    Label("重试", systemImage: "arrow.clockwise")
                }
                Button("蜂窝下载") {
                    confirmsCellularDownload = true
                }
            }
            .buttonStyle(.bordered)
            .frame(minHeight: 44)
        }
    }

    private func primaryButton(title: LocalizedStringKey, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
    }

    private func progressLine(title: LocalizedStringKey, fraction: Double?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(AppFont.subheadline(weight: .medium))
            if let fraction {
                ProgressView(value: fraction)
                Text(fraction, format: .percent.precision(.fractionLength(0)))
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
    }

    private func detailRow(title: LocalizedStringKey, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
        }
        .font(AppFont.caption())
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
