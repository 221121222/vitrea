//
//  GateView.swift
//  Vitrea
//
//  全屏闸门：① 建立回环隧道（优先内置，退路 LocalDevVPN）→ ② 配对 → 放行。
//  按 iOS 版本只展示当前适用的配对路线，减少操作步数。
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct GateView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 0)

            VStack(spacing: 12) {
                Image(systemName: "wallet.bifold.fill")
                    .font(.system(size: 48, weight: .semibold))
                    .foregroundStyle(.blue)
                Text("Vitrea")
                    .font(.largeTitle.bold())
                Text("制作、发现并写入 Apple Wallet 卡面")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            VStack(spacing: 12) {
                stepBadge(index: 1, title: "连接隧道", done: model.tunnelUp)
                stepBadge(index: 2, title: "完成配对", done: model.paired)
            }
            .padding(.horizontal, 40)

            switch model.gateStage {
            case .vpn:     VPNGateStep()
            case .pairing: PairingGateStep()
            case .done:    EmptyView()
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 40)
    }

    private func stepBadge(index: Int, title: String, done: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "\(index).circle")
                .foregroundColor(done ? .green : .secondary)
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundColor(done ? .primary : .secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - Step 1：建立回环隧道

struct VPNGateStep: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    @ObservedObject private var tunnel = LoopbackTunnelService.shared

    @State private var waiting = false
    @State private var elapsed = 0
    @State private var pollTask: Task<Void, Never>?
    @State private var prepared = false

    private let vpnURL = URL(string: "localdevvpn://")!

    var body: some View {
        VStack(spacing: 14) {
            Text(headline)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            if tunnel.availability.isReady {
                builtInControls
            } else {
                externalControls
            }

            if waiting {
                ProgressView("等待隧道连接… \(elapsed)s")
                    .font(.caption)
            }

            if let error = tunnel.lastError, tunnel.availability.isReady {
                Text(error)
                    .font(.caption2)
                    .foregroundColor(.orange)
                    .multilineTextAlignment(.center)
            }
        }
        .task {
            guard !prepared else { return }
            prepared = true
            await tunnel.prepare()
            if WriteEngine.shared.isTunnelUp {
                model.advanceGate(to: .pairing)
            } else if tunnel.availability.isReady {
                // 内置回环可用就直接拉起来，省掉用户一次点击。
                await startBuiltIn()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, waiting, WriteEngine.shared.isTunnelUp {
                model.advanceGate(to: .pairing)
            }
        }
        .onDisappear { pollTask?.cancel() }
    }

    // MARK: 文案

    private var headline: String {
        if tunnel.availability.isReady {
            return "Vitrea 内置回环：在本机建立一条能连回自己的隧道，卡面才能写入设备。"
        }
        switch tunnel.availability {
        case .unsupported:
            return "内置回环不可用（当前签名未包含 NetworkExtension 权限）。请改用 LocalDevVPN。"
        case .failed(let reason):
            return "内置回环启动失败：\(reason)\n可改用 LocalDevVPN。"
        default:
            return "正在检查回环隧道…"
        }
    }

    // MARK: 内置回环按钮

    @ViewBuilder
    private var builtInControls: some View {
        if tunnel.isConnected || WriteEngine.shared.isTunnelUp {
            Label("隧道已连接", systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.green)
        } else {
            Button {
                Task { await startBuiltIn() }
            } label: {
                Label(tunnel.isBusy ? "正在连接…" : "启动内置回环",
                      systemImage: "bolt.horizontal.fill")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(.blue, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .foregroundColor(.white)
            }
            .buttonStyle(.plain)
            .disabled(tunnel.isBusy)

            Button {
                openURL(vpnURL)
                beginPolling()
            } label: {
                Text("改用 LocalDevVPN")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: 外置 LocalDevVPN 按钮（内置不可用时的退路）

    @ViewBuilder
    private var externalControls: some View {
        Button {
            openURL(vpnURL)
            beginPolling()
        } label: {
            Label("打开 LocalDevVPN", systemImage: "bolt.horizontal.fill")
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(.blue, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .foregroundColor(.white)
        }
        .buttonStyle(.plain)

        Text("也可以从 App Store 安装 LocalDevVPN 后回到本页。")
            .font(.caption2)
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
    }

    // MARK: 行为

    private func startBuiltIn() async {
        _ = await tunnel.activate()
        beginPolling()
    }

    private func beginPolling() {
        waiting = true
        elapsed = 0
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if Task.isCancelled { return }
                elapsed += 2
                await tunnel.refreshStatus()
                if WriteEngine.shared.isTunnelUp {
                    await MainActor.run {
                        waiting = false
                        model.advanceGate(to: .pairing)
                    }
                    return
                }
                if elapsed >= 90 {
                    await MainActor.run { waiting = false }
                    return
                }
            }
        }
    }
}

// MARK: - Step 2：配对

struct PairingGateStep: View {
    @EnvironmentObject var model: AppModel
    @State private var showPicker = false

    @ObservedObject private var pairing = PairingController.shared

    private var isNewOS: Bool { ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 }

    var body: some View {
        VStack(spacing: 16) {
            // 完整配对方法（含「设置 → 隐私与安全性 → 开发者」开启开发者模式）
            setupGuide

            if isNewOS {
                Text("点击下方按钮，按提示在「设置」中完成本机配对。")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                if let pin = pairing.pairingPIN {
                    VStack(spacing: 6) {
                        Text("在设置中输入 PIN")
                            .font(.caption).foregroundColor(.secondary)
                        Text(pin)
                            .font(.system(size: 36, weight: .bold, design: .rounded))
                            .tracking(8)
                    }
                }

                Button {
                    Task {
                        do {
                            _ = try await pairing.startAndWait()
                            checkPaired()
                        } catch {
                            await MainActor.run {
                                // 失败时显示提示，不静默
                                model.advanceGate(to: .pairing)
                            }
                        }
                    }
                } label: {
                    Label(pairing.running ? "配对中…" : "与此 iPhone 配对",
                          systemImage: "person.2.fill")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(.blue, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .foregroundColor(.white)
                }
                .buttonStyle(.plain)
                .disabled(pairing.running)
            } else {
                Text("从 SideStore 导入 .mobiledevicepairing 配对文件，一次导入长期有效。")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                Button { showPicker = true } label: {
                    Label("导入配对文件", systemImage: "doc.fill")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(.blue, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .foregroundColor(.white)
                }
                .buttonStyle(.plain)
            }
        }
        .onAppear { if WriteEngine.shared.isPaired { finish() } }
        .onChange(of: pairing.pairingPIN) { _, newPin in
            if newPin != nil { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { checkPaired() } }
        }
        .sheet(isPresented: $showPicker) {
            PairingFilePicker { url in
                if PairingImportBridge.importPairingFile(from: url) { finish() }
            }
        }
    }

    private func checkPaired() {
        if WriteEngine.shared.isPaired { finish() }
    }

    // MARK: 完整配对方法（含开发者模式）

    private var setupGuide: some View {
        GlassCard(padding: 14, cornerRadius: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "checklist")
                        .foregroundColor(.blue)
                    Text("完整配对方法").font(.subheadline.weight(.semibold))
                }

                guideRow(n: 1, text: "先开启开发者模式：打开 iPhone 的「设置」→「隐私与安全性」→「开发者」，打开「开发者模式」，按提示重启设备。")
                guideRow(n: 2, text: isNewOS
                    ? "在下方点「与此 iPhone 配对」，系统跳到「设置」开启本机配对并输入 PIN，自动回到本 App 即完成。"
                    : "从 SideStore / AltStore 等导出 .mobiledevicepairing 配对文件，点下方「导入配对文件」选中它。")
                guideRow(n: 3, text: "配对成功且隧道保持连接后，即可开始写入卡面。")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func guideRow(n: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(n)")
                .font(.caption.weight(.bold))
                .foregroundColor(.blue)
                .frame(width: 16, alignment: .leading)
            Text(text)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func finish() {
        if WriteEngine.shared.isPaired && WriteEngine.shared.isTunnelUp {
            model.completeGate()
        } else if WriteEngine.shared.isPaired {
            model.advanceGate(to: .vpn)
        }
    }
}

// MARK: - 配对文件选择器

struct PairingFilePicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { onPick(url) }
        }
    }
}

// MARK: - 配对导入桥

enum PairingImportBridge {
    static func importPairingFile(from sourceURL: URL) -> Bool {
        let secured = sourceURL.startAccessingSecurityScopedResource()
        defer { if secured { sourceURL.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: sourceURL), !data.isEmpty else { return false }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        do {
            try data.write(to: docs.appendingPathComponent("aircard_pairing.plist"), options: .atomic)
            try data.write(to: docs.appendingPathComponent("airlift_pairing.plist"), options: .atomic)
            PairingController.customPairingFilePath = docs.appendingPathComponent("aircard_pairing.plist").path
            return WriteEngine.shared.isPaired
        } catch {
            return false
        }
    }
}
