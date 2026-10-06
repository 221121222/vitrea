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

// MARK: - 写入进度

/// 一次批量写入的进度快照（交给 UI / 实时活动）
struct WriteBatchProgress {
    /// 总体进度 0…1
    let fraction: Double
    /// 阶段文案
    let stage: String
    /// 已完成张数 / 总张数
    let done: Int
    let total: Int
    /// 失败张数
    let failed: Int
    /// 当前正在写的卡（展示用短标签）
    let cardLabel: String
}

/// 单张卡的进度回调（fraction + 阶段文案）。
/// 约定：WriteEngine 内部会切回主线程再调用，消费方可以直接改 UI 状态。
typealias WriteProgressHandler = (Double, String) -> Void

// MARK: - Rust 日志 → 文件级进度
//
// `al_exploit_write_dir` 是**一次阻塞调用**，没有进度回调参数；但它会把过程写进日志回调。
// 下面这些格式来自 `rust-core/src/exploit.rs` 的实际 logger.log 调用：
//
//   airlift: found 8 file(s) to write
//   airlift: attempting fast atomic batch write for 8 file(s)...
//   airlift: [3/8] writing 'x.png' (123456 bytes)...          ← 开始写第 3 个
//   airlift: [3/8] 'x.png' written successfully ✅             ← 第 3 个写完（逐文件回退路径）
//   airlift: starting com.apple.atc batch sync for 8 files...
//   airlift: FileComplete sent [3/8]                           ← 第 3 个写完（ATC 批量路径）
//   airlift: [batch 3/8] written -> x.png
//   airlift: fast batch write succeeded for all 8 file(s) in 1 shot! ✅
//   airlift: successfully batch-wrote 8 files in one shot! ✅
//   airlift: successfully wrote 8 files to /var/mobile/...
//
// 解析这些行就能拿到**真实**的文件级进度，而不是靠猜。

struct FFIProgressParser {

    private(set) var total = 0
    private(set) var completed = 0
    private(set) var finished = false

    /// 「已完成」关键词（出现在 [i/N] 行里即认为第 i 个已落盘）
    private static let doneKeywords = [
        "written successfully",
        "written ->",
        "filecomplete sent",
    ]
    /// 「开始写」关键词
    private static let startKeywords = ["writing"]
    /// 终态关键词
    private static let terminalKeywords = [
        "fast batch write succeeded",
        "successfully batch-wrote",
        "successfully wrote",
    ]

    /// 消费一行日志；返回 true 表示进度有变化
    @discardableResult
    mutating func consume(_ rawLine: String) -> Bool {
        let line = rawLine.lowercased()
        var changed = false

        // ① 「[i/N]」或「[batch i/N]」形式的位置标记
        if let (index, count) = Self.bracketCounts(line), count > 0 {
            if count > total { total = count; changed = true }
            if Self.doneKeywords.contains(where: line.contains) {
                if index > completed { completed = index; changed = true }
            } else if Self.startKeywords.contains(where: line.contains) {
                // 开始写第 i 个 → 已完成 i-1
                let doneBefore = max(0, index - 1)
                if doneBefore > completed { completed = doneBefore; changed = true }
            }
        }

        // ② 「found N file(s)」「for N file(s)」「N files」→ 总文件数
        if line.contains("file"), let n = Self.countBeforeFileWord(line), n > total {
            total = n
            changed = true
        }

        // ③ 终态
        if Self.terminalKeywords.contains(where: line.contains) {
            if total > 0, completed < total { completed = total; changed = true }
            if !finished { finished = true; changed = true }
        }

        return changed
    }

    /// 取 "[3/8]" / "[batch 3/8]" 里的 (3, 8)
    private static func bracketCounts(_ line: String) -> (Int, Int)? {
        guard let open = line.firstIndex(of: "["),
              let close = line[open...].firstIndex(of: "]") else { return nil }
        let inner = line[line.index(after: open)..<close]
        let parts = inner.split(separator: "/")
        guard parts.count == 2,
              let a = trailingInt(parts[0]),
              let b = trailingInt(parts[1]) else { return nil }
        return (a, b)
    }

    /// 取 " file" 前面那个数字
    private static func countBeforeFileWord(_ line: String) -> Int? {
        guard let r = line.range(of: " file") else { return nil }
        return trailingInt(line[line.startIndex..<r.lowerBound])
    }

    /// 取片段末尾的连续数字（`"batch 3"` → 3，`"8"` → 8）
    private static func trailingInt(_ s: Substring) -> Int? {
        let digits = s.reversed().prefix { $0.isNumber }.reversed()
        return digits.isEmpty ? nil : Int(String(digits))
    }
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
    //
    // 进度分段（单张卡内 0…1）：
    //   0.02  检查连接
    //   0.05  准备隧道
    //   0.07→0.30  渲染卡面（纯 CPU）
    //   0.30→0.36  落暂存目录
    //   0.36→0.95  FFI 写入（**由 Rust 日志驱动真实文件级进度**）
    //   0.95→0.99  刷新钱包缓存
    //   1.00  完成

    private enum Phase {
        static let envStart      = 0.02
        static let tunnelReady   = 0.05
        static let renderStart   = 0.07
        static let renderDone    = 0.30
        static let staged        = 0.36
        static let ffiStart      = 0.36
        static let ffiEnd        = 0.95
        static let invalidating  = 0.97
        static let done          = 1.0
    }

    /// - Throws: WriteErrorKind（四类之一）
    func writeCard(cardId: String, image: UIImage,
                   onLog: @escaping (String) -> Void,
                   onProgress: @escaping WriteProgressHandler) async throws {
        if let env = checkEnvironment() {
            record(env.userMessage, errorKind: env)
            throw env
        }
        report(onProgress, Phase.envStart, "正在检查连接…")

        syncHosts()
        report(onProgress, Phase.tunnelReady, "正在准备隧道…")

        report(onProgress, Phase.renderStart, "正在渲染卡面…")
        let skins = ImageEngine.prepareAllCardSkins(from: image)
        guard !skins.isEmpty else {
            record("卡面渲染失败", errorKind: .verifyFailed)
            throw WriteErrorKind.verifyFailed
        }
        report(onProgress, Phase.renderDone, "卡面渲染完成")

        let stageDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("workshop_card_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: stageDir, withIntermediateDirectories: true)
        for (name, data) in skins {
            try? data.write(to: stageDir.appendingPathComponent(name))
        }
        defer { try? FileManager.default.removeItem(at: stageDir) }
        report(onProgress, Phase.staged, "正在准备写入文件…")

        let target = "/var/mobile/Library/Passes/Cards/\(cardId).pkpass"
        onLog("正在写入 \(cardId.prefix(10))… 的 Passbook 缓存")

        let writeResult = await attemptFFIWriteAsync(stageDir: stageDir.path, target: target) { completed, total in
            let span = Phase.ffiEnd - Phase.ffiStart
            let frac = total > 0 ? Double(completed) / Double(total) : 0
            let index = total > 0 ? min(completed + 1, total) : completed
            self.report(onProgress,
                        Phase.ffiStart + span * frac,
                        total > 0 ? "正在写入 (\(index)/\(total))…" : "正在写入…")
        }
        switch writeResult {
        case .failure(let kind):
            record(kind.userMessage, errorKind: kind)
            throw kind
        case .success:
            break
        }

        report(onProgress, Phase.invalidating, "正在刷新钱包缓存…")
        onLog("图像已写入，正在失效 FrontFace / Preview / PlaceHolder 缓存")
        invalidateCaches(cardId: cardId)

        report(onProgress, Phase.done, "完成")
        record("卡面写入成功：\(cardId.prefix(10))…（重启钱包后生效）", errorKind: nil)
    }

    /// 统一切回主线程再回调，消费方可以直接改 UI / 实时活动
    private func report(_ handler: @escaping WriteProgressHandler, _ fraction: Double, _ stage: String) {
        if Thread.isMainThread {
            handler(fraction, stage)
        } else {
            DispatchQueue.main.async { handler(fraction, stage) }
        }
    }

    // MARK: 批量写入

    /// 全部卡批量写入。返回每张的结果，UI 分别展示成败。
    /// `onProgress` 给出**总体**进度（跨卡归一化），供进度条与灵动岛使用。
    func batchWrite(items: [(cardId: String, label: String, image: UIImage)],
                    onLog: @escaping (String) -> Void,
                    onProgress: @escaping (WriteBatchProgress) -> Void) async -> [(cardId: String, error: WriteErrorKind?)] {
        var results: [(String, WriteErrorKind?)] = []
        let total = items.count
        var failedCount = 0

        for (i, item) in items.enumerated() {
            let base = Double(i) / Double(max(total, 1))
            let span = 1.0 / Double(max(total, 1))

            do {
                try await writeCard(
                    cardId: item.cardId, image: item.image,
                    onLog: { onLog("[\(i+1)/\(total)] \($0)") },
                    onProgress: { cardFraction, stage in
                        onProgress(WriteBatchProgress(
                            fraction: base + span * cardFraction,
                            stage: stage,
                            done: i,
                            total: total,
                            failed: failedCount,
                            cardLabel: item.label
                        ))
                    }
                )
                results.append((item.cardId, nil))
            } catch let kind as WriteErrorKind {
                results.append((item.cardId, kind))
                failedCount += 1
            } catch {
                results.append((item.cardId, .verifyFailed))
                failedCount += 1
            }

            // 收尾：把这张卡补满
            onProgress(WriteBatchProgress(
                fraction: Double(i + 1) / Double(max(total, 1)),
                stage: i + 1 < total ? "第 \(i + 1) 张完成" : "完成",
                done: i + 1,
                total: total,
                failed: failedCount,
                cardLabel: item.label
            ))
        }
        return results
    }

    // MARK: FFI 写入（含一次重试 + 错误分类）

    private enum FFIResult { case success, failure(WriteErrorKind) }

    /// FFI 写入是阻塞调用：放到专用串行队列执行，避免卡死 Swift 协作线程池
    /// - Parameter onFileProgress: (已完成文件数, 总文件数)，从 Rust 日志解析而来
    private func attemptFFIWriteAsync(stageDir: String,
                                      target: String,
                                      onFileProgress: @escaping (Int, Int) -> Void) async -> FFIResult {
        await withCheckedContinuation { cont in
            ffiQueue.async {
                cont.resume(returning: self.attemptFFIWrite(stageDir: stageDir,
                                                            target: target,
                                                            onFileProgress: onFileProgress))
            }
        }
    }

    private let ffiQueue = DispatchQueue(label: "cc.cardart.workshop.writeengine", qos: .userInitiated)

    private func attemptFFIWrite(stageDir: String,
                                 target: String,
                                 onFileProgress: @escaping (Int, Int) -> Void) -> FFIResult {
        for attempt in 0..<2 {
            let pairingPath = PairingController.pairingFilePath()
            var outError: UnsafeMutablePointer<CChar>?

            // C 回调不可捕获上下文：日志 sink + 进度解析器一起放进桥对象，经 context 指针传入
            let bridge = WriteLogBridge(onFileProgress: onFileProgress)
            let bridgePtr = Unmanaged.passRetained(bridge).toOpaque()
            defer { Unmanaged.passUnretained(bridge).release() }

            let rc = pairingPath.withCString { pairC in
                stageDir.withCString { srcC in
                    target.withCString { tgtC in
                        al_exploit_write_dir(pairC, srcC, tgtC, { ctx, msg in
                            guard let ctx, let msg else { return }
                            Unmanaged<WriteLogBridge>.fromOpaque(ctx)
                                .takeUnretainedValue()
                                .handle(String(cString: msg))
                        }, bridgePtr, &outError)
                    }
                }
            }

            var captured = bridge.sink
            if let p = outError {
                let s = String(cString: p)
                al_string_free(p)
                if !s.isEmpty { captured = s }
            }

            if rc == 0 {
                // 补齐最后一格：成功时 completed 必然等于 total
                let progress = bridge.progress
                if progress.total > 0, progress.completed < progress.total {
                    onFileProgress(progress.total, progress.total)
                }
                return .success
            }

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

// MARK: - 写入日志 / 进度桥（C 回调上下文对象）
//
// 一次 FFI 写入里同时要干两件事：把日志攒起来做错误分类，以及解析文件级进度。
// 两者都从同一条 C 回调来，所以合并成一个桥对象。
// 回调由 Rust 侧触发（可能落在 tokio 工作线程上），因此这里加锁保护，
// 不依赖「回调一定串行」这个隐含前提。

private final class WriteLogBridge {
    private let lock = NSLock()
    private let sinkStorage = NSMutableString()
    private var parserStorage = FFIProgressParser()

    private let onFileProgress: (Int, Int) -> Void
    private var lastReported = -1

    init(onFileProgress: @escaping (Int, Int) -> Void) {
        self.onFileProgress = onFileProgress
    }

    /// 完整日志（供错误分类使用）
    var sink: String {
        lock.lock(); defer { lock.unlock() }
        return sinkStorage as String
    }

    /// 当前解析到的进度
    var progress: (completed: Int, total: Int) {
        lock.lock(); defer { lock.unlock() }
        return (parserStorage.completed, parserStorage.total)
    }

    func handle(_ text: String) {
        lock.lock()
        sinkStorage.append(text)
        let changed = parserStorage.consume(text)
        let completed = parserStorage.completed
        let total = parserStorage.total
        let shouldReport = changed && completed != lastReported
        if shouldReport { lastReported = completed }
        lock.unlock()

        // 锁外回调，避免下游（切主线程）持锁
        if shouldReport { onFileProgress(completed, total) }
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

