//
//  DeviceCleanerService.swift
//  Vitrea
//
//  跨应用清理：借 HouseArrest（VendContainer）把别的 App 容器以 AFC 形式租借出来，
//  只扫描 / 清理该容器内的 Library/Caches 与 tmp —— 与 3105 的「有限清理」同一边界。
//
//  前置条件与写入一致：需要有效的本机配对 + LocalDevVPN 回环隧道。
//  所有 FFI 调用都是阻塞的，一律走专用串行队列，不占用 Swift 协作线程池。
//

import Foundation
import AirliftFFI

// MARK: - 模型

struct DeviceApp: Identifiable, Codable, Equatable {
    let bundleID: String
    let name: String
    let container: String?
    let type: String?      // User / System …
    let version: String?

    var id: String { bundleID }

    var isUserApp: Bool { (type ?? "").localizedCaseInsensitiveContains("User") }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? bundleID : trimmed
    }
}

struct ContainerUsage: Codable, Equatable {
    let bytes: Int64
    let items: Int64

    static let empty = ContainerUsage(bytes: 0, items: 0)
}

struct ContainerCleanResult: Codable, Equatable {
    let freedBytes: Int64
    let removed: Int64
    let failed: Int64
}

/// 带体积的应用记录（列表展示用）
struct DeviceAppRecord: Identifiable, Equatable {
    let app: DeviceApp
    let usage: ContainerUsage

    var id: String { app.bundleID }
}

/// 批量扫描结果（一次隧道扫多个应用）
struct ContainerScanEntry: Decodable, Equatable {
    let bundleID: String
    let bytes: Int64
    let items: Int64
    let error: String?
}

enum DeviceCleanerError: LocalizedError {
    case environment(WriteErrorKind)
    case ffi(String)

    var errorDescription: String? {
        switch self {
        case .environment(let kind): return kind.userMessage
        case .ffi(let message):      return message
        }
    }
}

// MARK: - 服务

enum DeviceCleaner {

    /// FFI 是阻塞调用：统一丢到专用串行队列，避免拖垮协作线程池
    private static let queue = DispatchQueue(label: "cc.cardart.workshop.cleaner", qos: .userInitiated)

    /// 批量扫描要并发跑（每组一条独立隧道），所以单独用一个并发队列。
    /// 清理仍然走串行队列 —— 同时删多个容器没必要，还容易触发系统限流。
    private static let scanQueue = DispatchQueue(label: "cc.cardart.workshop.cleaner.scan",
                                                qos: .userInitiated,
                                                attributes: .concurrent)

    /// 自身 Bundle ID 不参与跨应用清理（本应用由 CleanerService 负责）
    private static var ownBundleID: String { Bundle.main.bundleIdentifier ?? "cc.cardart.workshop" }

    // MARK: 环境

    /// 返回 nil 表示可以开始扫描；否则返回需要提示用户的错误
    static func environmentIssue() -> WriteErrorKind? {
        WriteEngine.shared.checkEnvironment()
    }

    // MARK: 应用列表

    static func listApps() async throws -> [DeviceApp] {
        try await onQueue { try performListApps() }
    }

    // MARK: 体积统计

    static func usage(bundleID: String) async throws -> ContainerUsage {
        try await onQueue { try performUsage(bundleID: bundleID) }
    }

    /// 一次隧道批量统计：比逐个调用快一个量级（握手开销只付一次）。
    /// 走并发队列 —— 调用方可以同时发起多组，各组各建一条隧道并行扫描。
    static func scanMany(bundleIDs: [String]) async throws -> [ContainerScanEntry] {
        try await onScanQueue { try performScanMany(bundleIDs: bundleIDs) }
    }

    // MARK: 清理

    static func clean(bundleID: String) async throws -> ContainerCleanResult {
        try await onQueue { try performClean(bundleID: bundleID) }
    }

    // MARK: - FFI 封装

    private static func onQueue<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            queue.async {
                do { cont.resume(returning: try body()) }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    private static func onScanQueue<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            scanQueue.async {
                do { cont.resume(returning: try body()) }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    private static func pairingPath() -> String { PairingController.pairingFilePath() }

    private static func performListApps() throws -> [DeviceApp] {
        var outJSON: UnsafeMutablePointer<CChar>?
        var outError: UnsafeMutablePointer<CChar>?

        let rc = pairingPath().withCString { pair in
            al_container_list_apps(pair, nil, nil, &outJSON, &outError)
        }
        defer {
            if let outJSON { al_string_free(outJSON) }
            if let outError { al_string_free(outError) }
        }

        guard rc == 0, let outJSON else {
            throw DeviceCleanerError.ffi(errorText(outError) ?? "无法获取设备应用列表")
        }

        let data = Data(bytes: outJSON, count: strlen(outJSON))
        let apps = try JSONDecoder().decode([DeviceApp].self, from: data)
        return apps.filter { $0.bundleID != ownBundleID }
    }

    private static func performUsage(bundleID: String) throws -> ContainerUsage {
        var outJSON: UnsafeMutablePointer<CChar>?
        var outError: UnsafeMutablePointer<CChar>?

        let rc = pairingPath().withCString { pair in
            bundleID.withCString { bundle in
                al_container_usage(pair, bundle, nil, nil, &outJSON, &outError)
            }
        }
        defer {
            if let outJSON { al_string_free(outJSON) }
            if let outError { al_string_free(outError) }
        }

        guard rc == 0, let outJSON else {
            throw DeviceCleanerError.ffi(errorText(outError) ?? "无法读取该应用的缓存体积")
        }

        let data = Data(bytes: outJSON, count: strlen(outJSON))
        struct Payload: Decodable { let bytes: Int64; let items: Int64 }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        return ContainerUsage(bytes: payload.bytes, items: payload.items)
    }

    private static func performScanMany(bundleIDs: [String]) throws -> [ContainerScanEntry] {
        guard !bundleIDs.isEmpty else { return [] }

        var outJSON: UnsafeMutablePointer<CChar>?
        var outError: UnsafeMutablePointer<CChar>?

        let joined = bundleIDs.joined(separator: ",")
        let rc = pairingPath().withCString { pair in
            joined.withCString { ids in
                al_container_scan_many(pair, ids, nil, nil, &outJSON, &outError)
            }
        }
        defer {
            if let outJSON { al_string_free(outJSON) }
            if let outError { al_string_free(outError) }
        }

        guard rc == 0, let outJSON else {
            throw DeviceCleanerError.ffi(errorText(outError) ?? "批量扫描失败")
        }

        let data = Data(bytes: outJSON, count: strlen(outJSON))
        return try JSONDecoder().decode([ContainerScanEntry].self, from: data)
    }

    private static func performClean(bundleID: String) throws -> ContainerCleanResult {        var outJSON: UnsafeMutablePointer<CChar>?
        var outError: UnsafeMutablePointer<CChar>?

        let rc = pairingPath().withCString { pair in
            bundleID.withCString { bundle in
                al_container_clean(pair, bundle, nil, nil, &outJSON, &outError)
            }
        }
        defer {
            if let outJSON { al_string_free(outJSON) }
            if let outError { al_string_free(outError) }
        }

        guard rc == 0, let outJSON else {
            throw DeviceCleanerError.ffi(errorText(outError) ?? "清理失败")
        }

        let data = Data(bytes: outJSON, count: strlen(outJSON))
        struct Payload: Decodable { let freedBytes: Int64; let removed: Int64; let failed: Int64 }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        return ContainerCleanResult(freedBytes: payload.freedBytes,
                                    removed: payload.removed,
                                    failed: payload.failed)
    }

    private static func errorText(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
        guard let pointer else { return nil }
        let text = String(cString: pointer)
        return text.isEmpty ? nil : text
    }
}
