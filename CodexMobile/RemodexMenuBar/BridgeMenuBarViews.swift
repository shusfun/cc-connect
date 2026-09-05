// FILE: BridgeMenuBarViews.swift
// Purpose: Renders the native Remodex Mac control surface and pairing QR.
// Layer: Companion app view
// Exports: BridgeMenuBarContentView, BridgeMenuBarLabel
// Depends on: AppKit, CoreImage, SwiftUI, BridgeMenuBarStore

import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI
import CryptoKit

struct BridgeMenuBarContentView: View {
    @ObservedObject var store: BridgeMenuBarStore
    @ObservedObject private var access = DeviceAccessService.shared
    @State private var relayDraft = ""
    @State private var remarkDraft = ""
    @State private var replacingPhone: String?
    @State private var confirmsLogout = false
    @State private var selection = "概览"

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Label("Remodex", systemImage: "terminal.fill").font(.title2.bold()).padding(.bottom, 32)
                ForEach(["概览", "连接与配对", "诊断", "设置"], id: \.self) { page in
                    Button { selection = page } label: {
                        Label(page, systemImage: symbol(page)).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                            .background(selection == page ? Color.accentColor.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(.plain).accessibilityAddTraits(selection == page ? .isSelected : [])
                }
                Spacer()
                Label(store.snapshot?.isRunning == true ? "Bridge 运行中" : "Bridge 已停止", systemImage: "circle.fill")
                    .font(.caption).foregroundStyle(store.snapshot?.isRunning == true ? .green : .secondary)
                Text("任务在你的电脑运行").font(.caption).foregroundStyle(.secondary)
            }.padding(24).frame(width: 190).frame(maxHeight: .infinity).background(.thinMaterial)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(selection).font(.largeTitle.bold())
                            Text("你的设备，你的开发空间。").foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(store.phase).font(.callout.weight(.medium)).padding(.horizontal, 14).padding(.vertical, 8)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                    }
                    if store.isPerformingAction { ProgressView(store.phase).accessibilityLabel("正在处理：\(store.phase)") }
                    feedback
                    if store.logUnavailable { Label("诊断日志不可写，操作结果仍会在这里显示。", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                    switch selection {
                    case "概览":
                        card("运行控制") { controls }
                        if !access.isActivated { card("激活这台设备") { accountSection } }
                        card("连接状态") { statusGrid }
                    case "连接与配对":
                        card("设备身份") { accountSection }
                        card("手机配对") { pairingSection }
                    case "诊断":
                        card("当前状态") { statusGrid }
                        card("诊断记录") {
                            Text("操作编号：\(store.operationID.uuidString)").font(.caption.monospaced()).textSelection(.enabled)
                            Text("错误码：\(store.errorCode.isEmpty ? "无" : store.errorCode)")
                            HStack { Button("打开日志", action: store.openLogsFolder); Button("复制脱敏诊断", action: store.copyDiagnostics) }
                        }
                    default:
                        card("Relay 服务") { relaySection }
                        card("电源与运行") { sleepSection }
                        Toggle("登录时启动", isOn: Binding(get: { store.launchAtLogin }, set: store.setLaunchAtLogin))
                    }
                }.padding(32).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.frame(minWidth: 800, minHeight: 580)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { relayDraft = store.relayOverride; remarkDraft = access.remark; store.refresh() }
        .onChange(of: store.relayOverride) { _, value in relayDraft = value }
        .onChange(of: access.remark) { _, value in remarkDraft = value }
        .confirmationDialog("替换当前可信手机？旧手机将立即失去访问权限。", isPresented: Binding(get: { replacingPhone != nil }, set: { if !$0 { replacingPhone = nil } })) {
            Button("确认替换", role: .destructive) { if let id = replacingPhone { Task { await access.approvePhone(id: id, replace: true) } }; replacingPhone = nil }
        }
        .confirmationDialog("退出登录将撤销本设备及手机配对，不影响其他设备或代码文件。", isPresented: $confirmsLogout) {
            Button("退出登录", role: .destructive) { Task { await access.logout() } }
        }
    }

    private func symbol(_ page: String) -> String {
        switch page { case "概览": return "square.grid.2x2"; case "连接与配对": return "link"; case "诊断": return "waveform.path.ecg"; default: return "slider.horizontal.3" }
    }
    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title).font(.headline)
            content()
        }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.primary.opacity(0.06)))
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
                }.disabled(access.isActivating || access.isLoggingOut)
                if access.isActivating { Button("取消本次激活", action: access.cancelActivation) }
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
                    TimelineView(.periodic(from: .now, by: 1)) { timeline in
                        if payload.expiryDate > timeline.date, let text = session.qrText,
                           store.snapshot?.bridgeStatus?.connectionStatus == "connected" {
                            PairingQRCodeView(text: text).frame(width: 300, height: 300)
                        } else {
                            Label(payload.expiryDate <= timeline.date ? "配对码已过期，请刷新" : "等待 Relay 连接后显示二维码", systemImage: "qrcode")
                                .frame(width: 300, height: 300).background(.white).foregroundStyle(.black)
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("设备身份指纹")
                        Text(SHA256.hash(data: Data(base64Encoded: payload.macIdentityPublicKey) ?? Data()).map { String(format: "%02x", $0) }.joined())
                            .font(.system(size: 10, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        TimelineView(.periodic(from: .now, by: 1)) { timeline in
                            Text(payload.expiryDate > timeline.date ? "剩余 \(Int(payload.expiryDate.timeIntervalSince(timeline.date))) 秒" : "已过期")
                        }
                        if let code = session.qrText {
                            Button("复制配对码") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(code, forType: .string) }
                                .disabled(payload.expiryDate <= Date())
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
                Label("启动 Bridge 后生成配对二维码", systemImage: "qrcode")
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
    let text: String

    var body: some View {
        Group {
            if let image = PairingQRImageCache.image(text: text) {
                Image(nsImage: image)
                    .interpolation(.none)
            } else {
                Image(systemName: "qrcode")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 300, height: 300)
        .background(.white)
        .accessibilityLabel("手机配对二维码")
    }
}

@MainActor
private enum PairingQRImageCache {
    static let cache: NSCache<NSString, NSImage> = { let cache = NSCache<NSString, NSImage>(); cache.countLimit = 12; return cache }()
    static let context = CIContext()
    static func image(text: String) -> NSImage? {
        let backing = NSScreen.main?.backingScaleFactor ?? 2
        let key = "\(backing):\(text)" as NSString
        if let image = cache.object(forKey: key) { return image }
        let filter = CIFilter.qrCodeGenerator()
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let bounds = output.extent.insetBy(dx: -4, dy: -4)
        let padded = output.composited(over: CIImage(color: .white).cropped(to: bounds)).cropped(to: bounds)
        let factor = max(1, floor(300 * backing / bounds.width))
        let scaled = padded.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: CGFloat(cgImage.width) / backing, height: CGFloat(cgImage.height) / backing))
        cache.setObject(image, forKey: key)
        return image
    }
}
