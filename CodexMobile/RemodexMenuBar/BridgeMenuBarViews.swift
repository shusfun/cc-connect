// FILE: BridgeMenuBarViews.swift
// Purpose: Renders the native Remodex Mac control surface and pairing QR.
// Layer: Companion app view
// Exports: BridgeMenuBarContentView, BridgeMenuBarLabel
// Depends on: AppKit, CoreImage, SwiftUI, BridgeMenuBarStore

import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

struct BridgeMenuBarContentView: View {
    @ObservedObject var store: BridgeMenuBarStore
    @ObservedObject private var access = DeviceAccessService.shared
    @State private var relayDraft = ""
    @State private var remarkDraft = ""
    @State private var replacingPhone: String?
    @State private var confirmsLogout = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                accountSection
                Divider()
                statusGrid
                Divider()
                pairingSection
                Divider()
                relaySection
                Divider()
                controls
                Divider()
                sleepSection
                feedback
            }
            .padding(16)
        }
        .frame(width: 380, height: 640)
        .onAppear { relayDraft = store.relayOverride }
        .onChange(of: store.relayOverride) { _, value in relayDraft = value }
        .onChange(of: access.remark) { _, value in remarkDraft = value }
        .confirmationDialog("替换当前可信手机？旧手机将立即失去访问权限。", isPresented: Binding(get: { replacingPhone != nil }, set: { if !$0 { replacingPhone = nil } })) {
            Button("确认替换", role: .destructive) { if let id = replacingPhone { Task { await access.approvePhone(id: id, replace: true) } }; replacingPhone = nil }
        }
        .confirmationDialog("退出登录将撤销本设备及手机配对，不影响其他设备或代码文件。", isPresented: $confirmsLogout) {
            Button("退出登录", role: .destructive) { Task { await access.logout() } }
        }
    }

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(access.status).font(.headline)
            if access.isActivated {
                TextField("设备备注", text: $remarkDraft).textFieldStyle(.roundedBorder)
                Button("保存备注") { Task { await access.saveRemark(remarkDraft) } }
                ForEach(access.pendingPhones, id: \.self) { phone in
                    Text("新的手机配对申请").font(.headline)
                    Text(phone["key"] ?? "").font(.caption.monospaced()).textSelection(.enabled)
                    Button("允许配对") { if let id = phone["id"] { Task { await access.approvePhone(id: id, replace: false) } } }
                    Button("替换旧手机", role: .destructive) { replacingPhone = phone["id"] }
                }
                Button("退出登录", role: .destructive) { confirmsLogout = true }
            } else {
                Button(access.isActivating ? "等待浏览器批准…" : "使用 GitHub 激活") {
                    store.saveRelayOverride(relayDraft)
                    access.activate(relay: relayDraft)
                }.disabled(access.isActivating)
            }
            if !access.errorMessage.isEmpty { Text(access.errorMessage).foregroundStyle(.orange).font(.caption) }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Remodex")
                    .font(.system(size: 16, weight: .semibold))
                Text("Mac 运行中心")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Label(statusTitle, systemImage: statusIcon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(statusColor)
        }
    }

    private var statusGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 10) {
            statusRow("Bridge", store.snapshot?.isRunning == true ? "运行中" : "已停止")
            statusRow("Relay", store.snapshot?.bridgeStatus?.connectionStatus ?? "未连接")
            statusRow("Codex", store.snapshot?.codexStatusLabel ?? "未知")
            statusRow("手机连接", String(store.snapshot?.connectionCount ?? 0))
            statusRow("可信手机", String(store.snapshot?.trustedDevice?.trustedPhoneCount ?? 0))
            statusRow("最近同步", store.snapshot?.statusFootnote ?? "无")
            statusRow("版本", store.snapshot?.currentVersion ?? "—")
            statusRow("进程", store.snapshot?.processID.map(String.init) ?? "—")
        }
    }

    private func statusRow(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var pairingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("手机配对")
            if let session = store.snapshot?.pairingSession,
               let payload = session.pairingPayload {
                HStack(alignment: .top, spacing: 14) {
                    PairingQRCodeView(payload: payload)
                        .frame(width: 126, height: 126)
                    VStack(alignment: .leading, spacing: 8) {
                        Label(payload.expiryDate > Date() ? "等待扫码" : "已过期", systemImage: "qrcode.viewfinder")
                            .foregroundStyle(payload.expiryDate > Date() ? .green : .orange)
                        if let code = session.pairingCode, !code.isEmpty {
                            Text(code)
                                .font(.system(size: 22, weight: .semibold, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        Text(store.snapshot?.trustedPhoneStatusLabel ?? "未配对")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Button {
                            store.refreshPairing()
                        } label: {
                            Label("刷新配对码", systemImage: "arrow.clockwise")
                        }
                    }
                }
            } else {
                Label("启动 Bridge 后生成 QR 和短码", systemImage: "qrcode")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var relaySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Relay")
            TextField("wss://cc.syggu.cn", text: $relayDraft)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
            Button {
                store.saveRelayOverride(relayDraft)
            } label: {
                Label("保存并应用", systemImage: "checkmark")
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("管理")
            HStack {
                iconButton("启动", icon: "play.fill", action: store.startBridge)
                iconButton("停止", icon: "stop.fill", role: .destructive, action: store.stopBridge)
                iconButton("重启", icon: "arrow.clockwise", action: store.restartBridge)
            }
            HStack {
                iconButton("打开最近任务", icon: "arrow.up.forward.app", action: store.resumeLastThread)
                iconButton("重置配对", icon: "person.crop.circle.badge.xmark", role: .destructive, action: store.resetPairing)
            }
            Toggle("登录时启动 Remodex", isOn: Binding(
                get: { store.launchAtLogin },
                set: store.setLaunchAtLogin
            ))
            .toggleStyle(.switch)
        }
    }

    private var sleepSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("远程可用性")
            Label("显示器熄灭不影响连接；系统睡眠后远程不可达，唤醒后会自动增量恢复。", systemImage: "moon.zzz")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button {
                    store.openPowerSettings()
                } label: {
                    Label("电源设置", systemImage: "gear")
                }
                Button {
                    store.openLogsFolder()
                } label: {
                    Label("日志", systemImage: "doc.text")
                }
                Button {
                    store.copyDiagnostics()
                } label: {
                    Label("复制诊断", systemImage: "doc.on.doc")
                }
            }
        }
    }

    @ViewBuilder
    private var feedback: some View {
        if !store.errorMessage.isEmpty {
            Label(store.errorMessage, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        } else if !store.transientMessage.isEmpty {
            Label(store.transientMessage, systemImage: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.green)
        } else if let error = store.snapshot?.lastErrorMessage, !error.isEmpty {
            Label(error, systemImage: "exclamationmark.circle")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
    }

    private func iconButton(
        _ title: String,
        icon: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            Label(title, systemImage: icon)
        }
        .disabled(store.isPerformingAction)
    }

    private var statusTitle: String {
        store.snapshot?.statusHeadline ?? "正在启动"
    }

    private var statusIcon: String {
        store.snapshot?.bridgeStatus?.connectionStatus == "connected"
            ? "checkmark.circle.fill"
            : (store.snapshot?.isRunning == true ? "circle.dotted" : "stop.circle")
    }

    private var statusColor: Color {
        store.snapshot?.bridgeStatus?.connectionStatus == "connected"
            ? .green
            : (store.snapshot?.isRunning == true ? .orange : .secondary)
    }
}

struct BridgeMenuBarLabel: View {
    let snapshot: BridgeSnapshot?
    let isBusy: Bool

    var body: some View {
        Image(systemName: isBusy ? "arrow.triangle.2.circlepath" : "terminal")
            .symbolVariant(snapshot?.bridgeStatus?.connectionStatus == "connected" ? .fill : .none)
            .accessibilityLabel("Remodex Mac 运行中心")
    }
}

private struct PairingQRCodeView: View {
    let payload: BridgePairingPayload
    private let context = CIContext()
    private let filter = CIFilter.qrCodeGenerator()

    var body: some View {
        Group {
            if let image = qrImage {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(8)
            } else {
                Image(systemName: "qrcode")
                    .foregroundStyle(.secondary)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var qrImage: NSImage? {
        guard let data = try? JSONEncoder().encode(payload) else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: .zero)
    }
}
