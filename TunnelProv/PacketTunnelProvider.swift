//
//  PacketTunnelProvider.swift
//  VitreaTunnel
//
//  Vitrea 内置回环隧道（Packet Tunnel Provider 扩展）。
//
//  为什么需要它
//  ------------
//  本机开发者配对（lockdownd / 62078）只监听物理网卡，App 进程**无法**直接连
//  127.0.0.1 访问它；因此写入卡面 / 注入墙纸前必须先有一条能“回到自己”的通道。
//  Vitrea 内置的这条通道做的是：
//
//    1. 建一个 utun 虚拟接口，自身地址 `10.7.0.0/32`；
//    2. 只把 `10.7.0.1/32` 一条路由指进 utun（其余流量一律排除，不影响正常上网）；
//    3. 收到该接口上的 IP 包时，把**源/目的地址对调着改写**再塞回协议栈：
//         源 = 10.7.0.0 → 改写成 10.7.0.1
//         目的 = 10.7.0.1 → 改写成 10.7.0.0
//       于是「发往 10.7.0.1 的包」会以「来自 10.7.0.1、发给本机 10.7.0.0」的
//       形式被内核收回，`lockdownd` 就能收到；回包走相反路径回到 App 的 socket。
//
//  地址掩码必须是 /32：如果给 utun 配 /24，内核会自动给整个网段加一条直连路由，
//  把路由器 / DNS / 同网段其它主机的流量一起吸进隧道，导致断网。
//
//  配置项（由主 App 通过 NETunnelProviderProtocol.providerConfiguration 下发）
//  -------------------------------------------------------------------------
//    TunnelDeviceIP  隧道自身地址，默认 10.7.0.0
//    TunnelFakeIP    被弹回的伪对端地址，默认 10.7.0.1
//
//  署名
//  ----
//  回环思路来自 LocalDevVPN（SideStore Team，MIT 风格许可，见项目 README 致谢）；
//  本文件为独立实现，仅沿用「/32 utun + 单条 /32 路由 + 地址对调回灌」这一机制。
//

import Foundation
import NetworkExtension

final class PacketTunnelProvider: NEPacketTunnelProvider {

    // MARK: - 默认配置

    private enum Defaults {
        static let deviceIP = "10.7.0.0"
        static let peerIP = "10.7.0.1"
        static let subnetMask = "255.255.255.255"
        static let mtu = 1500
    }

    /// IPv4 头部长度（不含 options）
    private static let minIPv4HeaderLength = 20
    /// IPv4 头部里「源地址」字段的偏移
    private static let sourceOffset = 12
    /// IPv4 头部里「目的地址」字段的偏移
    private static let destinationOffset = 16

    private let stateLock = NSLock()
    private var deviceAddress: UInt32 = 0
    private var peerAddress: UInt32 = 0
    private var pumping = false

    // MARK: - 生命周期

    override func startTunnel(options: [String: NSObject]?,
                              completionHandler: @escaping (Error?) -> Void) {

        let configuration = (protocolConfiguration as? NETunnelProviderProtocol)?
            .providerConfiguration

        let deviceIP = (options?["TunnelDeviceIP"] as? String)
            ?? (configuration?["TunnelDeviceIP"] as? String)
            ?? Defaults.deviceIP
        let peerIP = (options?["TunnelFakeIP"] as? String)
            ?? (configuration?["TunnelFakeIP"] as? String)
            ?? Defaults.peerIP

        guard let deviceValue = Self.addressValue(deviceIP),
              let peerValue = Self.addressValue(peerIP),
              deviceValue != peerValue else {
            NSLog("[VitreaTunnel] 地址配置非法 device=\(deviceIP) peer=\(peerIP)")
            completionHandler(NEVPNError(.configurationInvalid))
            return
        }

        stateLock.lock()
        deviceAddress = deviceValue
        peerAddress = peerValue
        stateLock.unlock()

        NSLog("[VitreaTunnel] 启动回环隧道 device=\(deviceIP)/32 peer=\(peerIP)/32")

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: deviceIP)
        settings.mtu = NSNumber(value: Defaults.mtu)

        let ipv4 = NEIPv4Settings(addresses: [deviceIP],
                                  subnetMasks: [Defaults.subnetMask])
        // 只把伪对端这一条 /32 送进隧道，别的一律排除，避免抢占正常网络。
        ipv4.includedRoutes = [
            NEIPv4Route(destinationAddress: peerIP, subnetMask: Defaults.subnetMask)
        ]
        ipv4.excludedRoutes = [
            NEIPv4Route(destinationAddress: "0.0.0.0", subnetMask: "0.0.0.0")
        ]
        settings.ipv4Settings = ipv4

        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self else {
                completionHandler(error)
                return
            }
            if let error {
                NSLog("[VitreaTunnel] setTunnelNetworkSettings 失败: \(error)")
                completionHandler(error)
                return
            }
            self.stateLock.lock()
            self.pumping = true
            self.stateLock.unlock()
            self.pumpPackets()
            completionHandler(nil)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason,
                             completionHandler: @escaping () -> Void) {
        stateLock.lock()
        pumping = false
        stateLock.unlock()
        NSLog("[VitreaTunnel] 停止隧道 reason=\(reason.rawValue)")
        completionHandler()
    }

    // MARK: - 包回灌

    /// 反复读取 utun 上的包 → 改写地址 → 原样写回协议栈。
    private func pumpPackets() {
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self, self.isPumping else { return }

            self.stateLock.lock()
            let device = self.deviceAddress
            let peer = self.peerAddress
            self.stateLock.unlock()

            var forwarded = packets
            for index in forwarded.indices
            where protocols[index].int32Value == AF_INET {
                Self.bounce(&forwarded[index], device: device, peer: peer)
            }

            self.packetFlow.writePackets(forwarded, withProtocols: protocols)
            self.pumpPackets()
        }
    }

    private var isPumping: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return pumping
    }

    /// 把「源 = 隧道自身地址」改写成伪对端、把「目的 = 伪对端」改写成本机地址。
    /// 两条改写合在一起，正好让包绕回本机协议栈。
    private static func bounce(_ packet: inout Data, device: UInt32, peer: UInt32) {
        guard packet.count >= minIPv4HeaderLength else { return }

        let base = packet.startIndex
        // IHL：头部长度以 4 字节为单位，低 4 位。
        let headerLength = Int(packet[base] & 0x0F) * 4
        guard headerLength >= minIPv4HeaderLength, packet.count >= headerLength else { return }

        let source = Self.readAddress(packet, at: base + sourceOffset)
        let destination = Self.readAddress(packet, at: base + destinationOffset)

        if source == device {
            Self.writeAddress(peer, into: &packet, at: base + sourceOffset)
        }
        if destination == peer {
            Self.writeAddress(device, into: &packet, at: base + destinationOffset)
        }
    }

    // MARK: - 小工具

    /// 逐字节读写，避免对 Data 缓冲区做未对齐的 UInt32 访问。
    private static func readAddress(_ data: Data, at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for index in 0..<4 {
            value = (value << 8) | UInt32(data[offset + index])
        }
        return value
    }

    private static func writeAddress(_ value: UInt32, into data: inout Data, at offset: Int) {
        for index in 0..<4 {
            let shift = UInt32((3 - index) * 8)
            data[offset + index] = UInt8((value >> shift) & 0xFF)
        }
    }

    /// "10.7.0.1" → 0x0A070001
    static func addressValue(_ text: String) -> UInt32? {
        let octets = text.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return nil }
        var value: UInt32 = 0
        for octet in octets {
            guard let byte = UInt8(octet) else { return nil }
            value = (value << 8) | UInt32(byte)
        }
        return value
    }
}
