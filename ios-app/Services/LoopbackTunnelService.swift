//
//  LoopbackTunnelService.swift
//  Vitrea
//
//  内置回环隧道：把 LocalDevVPN 那套「让 App 能连回本机 lockdownd」的能力
//  收进 Vitrea 自己，用户不必再另外装一个 VPN App。
//
//  组成
//  ----
//  · 主 App 侧（本文件）：用 NETunnelProviderManager 建 / 存 / 启停 VPN 配置。
//  · 扩展侧：`TunnelProv/PacketTunnelProvider.swift`（随包内置的 .appex）。
//
//  权限
//  ----
//  两个 target 都要带 `com.apple.developer.networking.networkextension`
//  = `packet-tunnel-provider`（见 `ios-app/Vitrea.entitlements` 与
//  `TunnelProv/TunnelProv.entitlements`）。**自签安装时该权限来自描述文件**，
//  若签名工具没带上，扩展会启动失败 —— 此时界面会自动退回「打开 LocalDevVPN」，
//  功能不受影响。
//

import Foundation
import NetworkExtension

@MainActor
final class LoopbackTunnelService: ObservableObject {

    static let shared = LoopbackTunnelService()

    // MARK: - 常量

    /// 扩展的 Bundle ID，必须与 `project.yml` 里 VitreaTunnel 的 PRODUCT_BUNDLE_IDENTIFIER 一致。
    static let providerBundleID = "cc.cardart.workshop.tunnel"
    static let deviceIP = "10.7.0.0"
    static let peerIP = "10.7.0.1"

    /// 内置回环是否可用。
    enum Availability: Equatable {
        /// 还没探测
        case unknown
        /// 已就绪（扩展在包里、配置能存）
        case ready
        /// 环境不支持（例如自签没带 NetworkExtension 权限、或非 iOS 设备）
        case unsupported
        /// 出错，附原因
        case failed(String)

        var isReady: Bool { self == .ready }
    }

    // MARK: - 状态

    @Published private(set) var availability: Availability = .unknown
    @Published private(set) var status: NEVPNStatus = .invalid
    @Published private(set) var busy = false
    @Published private(set) var lastError: String?

    private var manager: NETunnelProviderManager?
    private var statusObserver: NSObjectProtocol?

    private init() {
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let connection = note.object as? NEVPNConnection else { return }
            Task { @MainActor [weak self] in
                self?.status = connection.status
            }
        }
    }

    deinit {
        if let statusObserver {
            NotificationCenter.default.removeObserver(statusObserver)
        }
    }

    // MARK: - 派生状态

    var isConnected: Bool { status == .connected }

    var isBusy: Bool {
        busy || status == .connecting || status == .disconnecting || status == .reasserting
    }

    var statusText: String {
        switch status {
        case .connected:      return "已连接"
        case .connecting:     return "连接中…"
        case .disconnecting:  return "断开中…"
        case .reasserting:    return "重连中…"
        case .invalid:        return "未配置"
        default:              return "未连接"
        }
    }

    // MARK: - 探测

    /// 启动时调一次：找到/创建自己的隧道配置，并判断这条路线能不能走通。
    func prepare() async {
        guard availability == .unknown else {
            await refreshStatus()
            return
        }
        do {
            let manager = try await loadOrCreateManager()
            self.manager = manager
            availability = .ready
            status = manager.connection.status
        } catch {
            // 扩展缺失或权限不足：不是致命错误，界面会退回 LocalDevVPN 按钮。
            availability = .unsupported
            lastError = error.localizedDescription
        }
    }

    func refreshStatus() async {
        guard let manager else { return }
        status = manager.connection.status
    }

    // MARK: - 启停

    /// 启动内置回环。返回是否成功把「启动指令」交出去（真正连上要看 status）。
    @discardableResult
    func activate() async -> Bool {
        guard !isBusy else { return true }
        busy = true
        defer { busy = false }

        do {
            let manager = try await loadOrCreateManager()
            self.manager = manager
            availability = .ready

            // 配置可能被用户手动改过（例如关掉过开关），存一次再启。
            if !manager.isEnabled {
                manager.isEnabled = true
                try await manager.saveToPreferences()
                try await manager.loadFromPreferences()
            }

            switch manager.connection.status {
            case .connected, .connecting:
                status = manager.connection.status
                return true
            default:
                break
            }

            try manager.connection.startVPNTunnel()
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            if (error as NSError).domain == NEVPNErrorDomain {
                availability = .failed(error.localizedDescription)
            }
            return false
        }
    }

    func deactivate() {
        manager?.connection.stopVPNTunnel()
    }

    // MARK: - 配置管理

    private func loadOrCreateManager() async throws -> NETunnelProviderManager {
        let existing = try await NETunnelProviderManager.loadAllFromPreferences()
        if let mine = existing.first(where: Self.isOurs) {
            // 顺手补齐可能缺失的字段（老版本配置 / 被系统清过）
            if mine.protocolConfiguration == nil || !mine.isEnabled {
                mine.isEnabled = true
                try await mine.saveToPreferences()
                try await mine.loadFromPreferences()
            }
            return mine
        }
        return try await makeManager()
    }

    private func makeManager() async throws -> NETunnelProviderManager {
        let manager = NETunnelProviderManager()

        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = Self.providerBundleID
        proto.serverAddress = Self.peerIP
        proto.providerConfiguration = [
            "TunnelDeviceIP": Self.deviceIP,
            "TunnelFakeIP": Self.peerIP,
        ]

        manager.protocolConfiguration = proto
        manager.localizedDescription = "Vitrea 内置回环"
        manager.isEnabled = true

        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()
        return manager
    }

    private static func isOurs(_ manager: NETunnelProviderManager) -> Bool {
        guard let proto = manager.protocolConfiguration as? NETunnelProviderProtocol else {
            return false
        }
        return proto.providerBundleIdentifier == providerBundleID
    }
}
