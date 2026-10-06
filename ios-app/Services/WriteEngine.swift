//
//  WriteEngine.swift
//  Vitrea
//
//  写入链路：环境校验 → 卡面渲染 → AirTraffic 写入 → 缓存失效。
//  四类错误分别落到 UI：未配对 / 隧道断开 / 路径不存在 / 写入校验失败。
//  全程不越狱、不碰 Secure Enclave、不动支付凭据，只替换图像缓存文件。
//

import Foundation
import UIKit
import AirliftFFI

// MARK: - 错误分类

enum WriteErrorKind: String, Codable, LocalizedError {

    var errorDescription: String? { userMessage }

    case notPaired     // 未配对 / 配对失效
    case tunnelDown    // loopback 隧道断开
    case pathMissing   // 目标路径不存在
    case verifyFailed  // 写入校验失败

    var userMessage: String {
        switch self {
        case .notPaired:
            return "未检测到有效配对记录。请回到配对引导，重新完成本机配对或导入配对文件。"
        case .tunnelDown:
            return "LocalDevVPN 隧道未连接。请打开 LocalDevVPN 并确认 loopback 隧道可用后重试。"
        case .pathMissing:
            return "设备上的 Passbook 目标路径不存在。请先在钱包里打开一次这张卡，再回来写入。"
        case .verifyFailed:
            return "写入校验失败。文件可能未被设备接受，建议检查连接后重试。"
        }
    }

    var icon: String {
        switch self {
        case .notPaired:   return "person.crop.circle.badge.questionmark"
        case .tunnelDown:  return "bolt.slash.fill"
        case .pathMissing: return "folder.badge.questionmark"
        case .verifyFailed:return "checkmark.seal.fill"
        }
    }
}

// MARK: - 写入日志（可查、持久化）

struct WriteLogEntry: Identifiable, Codable {
    let id: UUID
    let time: Date
    let message: String
    let errorKind: String?
}

// MARK: - WriteEngine

final class WriteEngine {
    static let shared = WriteEngine()

    private let deviceIP = "10.7.0.1"
    private let maxLogCount = 200
    private(set) var logs: [WriteLogEntry] = []

    private var scannerThread: Thread?

    private init() {
        logs = loadLogs()
    }

    // MARK: 环境校验

    /// 返回 nil 表示环境就绪；否则返回错误分类
    func checkEnvironment() -> WriteErrorKind? {
        let pairingPath = PairingController.pairingFilePath()
        let pairingOK = FileManager.default.fileExists(atPath: pairingPath)
            && ((try? FileManager.default.attributesOfItem(atPath: pairingPath)[.size] as? Int) ?? 0) > 0
        guard pairingOK else { return .notPaired }

        guard NetworkStatus.loopbackTunnelUp(deviceIP: deviceIP) else { return .tunnelDown }
        return nil
    }

    var isTunnelUp: Bool { NetworkStatus.loopbackTunnelUp(deviceIP: deviceIP) }
    var isPaired: Bool {
        let p = PairingController.pairingFilePath()
        return FileManager.default.fileExists(atPath: p)
            && ((try? FileManager.default.attributesOfItem(atPath: p)[.size] as? Int) ?? 0) > 0
    }

    // MARK: 单卡写入

    /// - Throws: WriteErrorKind（四类之一）
    func writeCard(cardId: String, image: UIImage,
                   onLog: @escaping (String) -> Void,
                   onProgress: @escaping (Double) -> Void) async throws {
        if let env = checkEnvironment() {
            record(env.userMessage, errorKind: env)
            throw env
        }
        syncHosts()
        onProgress(0.1)

        let skins = ImageEngine.prepareAllCardSkins(from: image)
        guard !skins.isEmpty else {
            record("卡面渲染失败", errorKind: .verifyFailed)
            throw WriteErrorKind.verifyFailed
        }
        onProgress(0.3)

        let stageDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("workshop_card_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: stageDir, withIntermediateDirectories: true)
        for (name, data) in skins {
            try? data.write(to: stageDir.appendingPathComponent(name))
        }
        defer { try? FileManager.default.removeItem(at: stageDir) }

        let target = "/var/mobile/Library/Passes/Cards/\(cardId).pkpass"
        onLog("正在写入 \(cardId.prefix(10))… 的 Passbook 缓存")
        onProgress(0.5)

        let writeResult = await attemptFFIWriteAsync(stageDir: stageDir.path, target: target)
        switch writeResult {
        case .failure(let kind):
            record(kind.userMessage, errorKind: kind)
            throw kind
        case .success:
            break
        }

        onProgress(0.8)
        onLog("图像已写入，正在失效 FrontFace / Preview / PlaceHolder 缓存")
        invalidateCaches(cardId: cardId)

        onProgress(1.0)
        record("卡面写入成功：\(cardId.prefix(10))…（重启钱包后生效）", errorKind: nil)
    }

    // MARK: 批量写入

    /// 全部卡批量写入。返回每张的结果，UI 分别展示成败。
    func batchWrite(items: [(cardId: String, image: UIImage)],
                    onLog: @escaping (String) -> Void,
                    onProgress: @escaping (Double, Int, Int) -> Void) async -> [(cardId: String, error: WriteErrorKind?)] {
        var results: [(String, WriteErrorKind?)] = []
        let total = items.count

        for (i, item) in items.enumerated() {
            do {
                try await writeCard(
                    cardId: item.cardId, image: item.image,
                    onLog: { onLog("[\(i+1)/\(total)] \($0)") },
                    onProgress: { onProgress($0, i + 1, total) }
                )
                results.append((item.cardId, nil))
            } catch let kind as WriteErrorKind {
                results.append((item.cardId, kind))
            } catch {
                results.append((item.cardId, .verifyFailed))
            }
            onProgress(1, i + 1, total)
        }
        return results
    }

    // MARK: FFI 写入（含一次重试 + 错误分类）

    private enum FFIResult { case success, failure(WriteErrorKind) }

    /// FFI 写入是阻塞调用：放到专用串行队列执行，避免卡死 Swift 协作线程池
    private func attemptFFIWriteAsync(stageDir: String, target: String) async -> FFIResult {
        await withCheckedContinuation { cont in
            ffiQueue.async {
                cont.resume(returning: self.attemptFFIWrite(stageDir: stageDir, target: target))
            }
        }
    }

    private let ffiQueue = DispatchQueue(label: "cc.cardart.workshop.writeengine", qos: .userInitiated)

    private func attemptFFIWrite(stageDir: String, target: String) -> FFIResult {
        for attempt in 0..<2 {
            let pairingPath = PairingController.pairingFilePath()
            var outError: UnsafeMutablePointer<CChar>?

            // C 回调不可捕获上下文：日志经 context 指针收集
            let sink = NSMutableString()
            let sinkPtr = Unmanaged.passRetained(sink).toOpaque()
            defer { Unmanaged.passUnretained(sink).release() }

            let rc = pairingPath.withCString { pairC in
                stageDir.withCString { srcC in
                    target.withCString { tgtC in
                        al_exploit_write_dir(pairC, srcC, tgtC, { ctx, msg in
                            guard let ctx, let msg else { return }
                            Unmanaged<NSMutableString>.fromOpaque(ctx)
                                .takeUnretainedValue()
                                .append(String(cString: msg))
                        }, sinkPtr, &outError)
                    }
                }
            }

            var captured = sink as String
            if let p = outError {
                let s = String(cString: p)
                al_string_free(p)
                if !s.isEmpty { captured = s }
            }

            if rc == 0 { return .success }

            let kind = classify(captured)
            // 隧道断开 / 校验失败允许一次重试；配对失效 / 路径不存在不重试
            if attempt == 0, kind == .verifyFailed || kind == .tunnelDown {
                Thread.sleep(forTimeInterval: 1.2)
                continue
            }
            return .failure(kind)
        }
        return .failure(.verifyFailed)
    }

    private func classify(_ message: String) -> WriteErrorKind {
        let m = message.lowercased()
        if m.contains("pair") || m.contains("untrusted") || m.contains("session") || m.contains(" lockdown") {
            return .notPaired
        }
        if m.contains("no such file") || m.contains("not found") || m.contains("missing") || m.contains("path") {
            return .pathMissing
        }
        if m.contains("connect") || m.contains("tunnel") || m.contains("timed out") || m.contains("network") {
            return .tunnelDown
        }
        return .verifyFailed
    }

    // MARK: 缓存失效

    /// 向 .cache / .pkcache 写入损坏的 FrontFace / Preview / PlaceHolder，
    /// 迫使 Wallet 重开时重新生成图像缓存。
    /// 必须同步执行：此前用 global queue async 派发 + defer 立即删除暂存目录，
    /// 失效写入从未真正落到设备，导致卡面写入后钱包里永远是旧图。
    private func invalidateCaches(cardId: String) {
        let invDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("workshop_inv_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: invDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: invDir) }

        for leaf in ["FrontFace", "Preview", "PlaceHolder"] {
            try? Data("corrupted".utf8).write(to: invDir.appendingPathComponent(leaf))
        }

        let pairingPath = PairingController.pairingFilePath()
        for ext in [".cache", ".pkcache"] {
            let target = "/var/mobile/Library/Passes/Cards/\(cardId)\(ext)"
            _ = pairingPath.withCString { pairC in
                invDir.path.withCString { srcC in
                    target.withCString { tgtC in
                        al_exploit_write_dir(pairC, srcC, tgtC, nil, nil, nil)
                    }
                }
            }
        }
    }

    // MARK: 卡识别（呼出 Apple Pay 时经 syslog 识别当前卡）

    func startScanner(onCard: @escaping (String, String?) -> Void,
                      onStatus: @escaping (String) -> Void) {
        stopScanner()
        guard isPaired else {
            onStatus("需要先完成配对才能识别卡片")
            return
        }
        guard isTunnelUp else {
            onStatus("LocalDevVPN 隧道未连接，无法识别卡片。请连接 LocalDevVPN 后重试。")
            return
        }
        syncHosts()
        let pairingPath = PairingController.pairingFilePath()

        let thread = Thread {
            var outError: UnsafeMutablePointer<CChar>?
            // C 回调不可捕获：逻辑对象经 context 指针传入
            let bridge = ScannerBridge(onCard: onCard, onStatus: onStatus)
            let bridgePtr = Unmanaged.passRetained(bridge).toOpaque()
            defer { Unmanaged.passUnretained(bridge).release() }

            let rc = pairingPath.withCString { pairC in
                al_syslog_stream_start(pairC, { ctx, line in
                    guard let ctx, let line else { return }
                    Unmanaged<ScannerBridge>.fromOpaque(ctx)
                        .takeUnretainedValue()
                        .handle(String(cString: line))
                }, bridgePtr, &outError)
            }
            if let p = outError {
                let msg = String(cString: p)
                al_string_free(p)
                DispatchQueue.main.async {
                    onStatus(rc == 0 ? "识别已停止" : "识别失败：\(msg)")
                }
            }
        }
        thread.name = "Workshop.SyslogScanner"
        thread.stackSize = 4 * 1024 * 1024
        thread.qualityOfService = .userInitiated
        scannerThread = thread
        thread.start()
        onStatus("请连按两次侧边键呼出 Apple Pay，点选你的卡片…")
    }

    func stopScanner() {
        al_syslog_stream_stop()
        scannerThread = nil
    }

    // MARK: 主机同步

    /// 对齐上游 AirCard：除固定隧道 IP 外，同步本机接口候选地址到 Rust 核心，
    /// 供 RSD 隧道 multihost 连接使用（只设单一 host 时部分网络环境下会连接失败）。
    private func syncHosts() {
        _ = deviceIP.withCString { al_set_target_host($0) }

        var candidates: [String] = [deviceIP]
        for cand in NetworkStatus.tunnelHostCandidates() where !candidates.contains(cand) {
            candidates.append(cand)
        }
        let cStrings = candidates.map { strdup($0) }
        defer { cStrings.forEach { free($0) } }
        var ptrs = cStrings.map { UnsafePointer($0) }
        ptrs.withUnsafeBufferPointer { buf in
            if let base = buf.baseAddress {
                _ = al_set_target_hosts(base, buf.count)
            }
        }
    }

    // MARK: 日志持久化

    private func record(_ message: String, errorKind: WriteErrorKind?) {
        let entry = WriteLogEntry(id: UUID(), time: Date(),
                                  message: message, errorKind: errorKind?.rawValue)
        logs.insert(entry, at: 0)
        if logs.count > maxLogCount { logs = Array(logs.prefix(maxLogCount)) }
        saveLogs()
    }

    private var logFile: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("write_log.json")
    }

    private func loadLogs() -> [WriteLogEntry] {
        guard let data = try? Data(contentsOf: logFile),
              let entries = try? JSONDecoder().decode([WriteLogEntry].self, from: data) else {
            return []
        }
        return entries
    }

    private func saveLogs() {
        guard let data = try? JSONEncoder().encode(logs) else { return }
        try? data.write(to: logFile, options: .atomic)
    }
}

// MARK: - 扫描器桥（C 回调上下文对象）

private final class ScannerBridge {
    let onCard: (String, String?) -> Void
    let onStatus: (String) -> Void

    init(onCard: @escaping (String, String?) -> Void,
         onStatus: @escaping (String) -> Void) {
        self.onCard = onCard
        self.onStatus = onStatus
    }

    /// 在 C 回调线程调用；过滤后回主线程派发
    func handle(_ line: String) {
        let lower = line.lowercased()
        let relevant = lower.contains("pass") || lower.contains("card")
            || lower.contains("wallet") || lower.contains("verificationcheck")
            || lower.contains("setactivepaymentapplet") || lower.contains("applet")
        guard relevant else { return }

        var network: String?
        var seen = Set<String>()

        for match in WalletScanParser.activationMatches(in: line) {
            network = match.network?.displayName
            if let id = match.id, let clean = WalletCard.cleanCardId(id), seen.insert(clean).inserted {
                DispatchQueue.main.async { [onCard] in onCard(clean, network) }
            }
        }
        for id in WalletScanParser.cardIDs(in: line) {
            if let clean = WalletCard.cleanCardId(id), seen.insert(clean).inserted {
                DispatchQueue.main.async { [onCard] in onCard(clean, network) }
            }
        }
    }
}

