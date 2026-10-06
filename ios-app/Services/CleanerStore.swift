//
//  CleanerStore.swift
//  Vitrea
//
//  清理页的共享状态（两个范围：本应用沙盒 / 设备上其他应用）。
//
//  为什么需要这个 store：
//    原先扫描状态放在 DeviceCleanerView 的 @State 里，而该视图是
//    `Group { if scope == .local { … } else { DeviceCleanerView() } }` 的一个分支 ——
//    每次从「其他应用」切到「本应用」再切回来，视图被重建、@State 归零，
//    于是又白扫一遍（这就是「切换另一个页面再返回后又重新刷新」）。
//
//  现在状态提升到单例 store：
//    · 首次进入某个范围时扫一次（页面不能是空的）
//    · 之后**只有点刷新按钮**才重新扫描；切范围 / 切 Tab / 返回都不会触发
//

import Foundation
import SwiftUI

@MainActor
final class CleanerStore: ObservableObject {

    static let shared = CleanerStore()

    // MARK: 本应用沙盒

    @Published private(set) var localRecords: [CleanerRecord] = []
    @Published private(set) var isScanningLocal = false
    private var hasScannedLocal = false
    private var localScanID = UUID()

    // MARK: 设备上其他应用（沙盒外）

    @Published private(set) var deviceRecords: [DeviceAppRecord] = []
    @Published private(set) var isScanningDevice = false
    /// 扫描进度（已扫 / 总数）—— 单独推，避免每块都重排整个列表
    @Published private(set) var deviceScanned = 0
    @Published private(set) var deviceTotal = 0
    @Published private(set) var deviceError: String?

    private var hasScannedDevice = false
    private var deviceScanID = UUID()
    private var deviceApps: [DeviceApp] = []
    private var deviceUsages: [String: ContainerUsage] = [:]

    // MARK: 通用

    @Published private(set) var sortOrder: CleanerSortOrder = .largestFirst

    private init() {}

    var localTotalBytes: Int64 { localRecords.reduce(0) { $0 + $1.usage.bytes } }
    var deviceTotalBytes: Int64 { deviceRecords.reduce(0) { $0 + $1.usage.bytes } }
    var isBusy: Bool { isScanningLocal || isScanningDevice }

    // MARK: - 首次进入才扫

    func loadLocalIfNeeded() {
        guard !hasScannedLocal else { return }
        refreshLocal()
    }

    func loadDeviceIfNeeded() async {
        guard !hasScannedDevice else { return }
        await refreshDevice()
    }

    // MARK: - 手动刷新（唯一会重新扫描的入口）

    func refreshLocal() {
        guard !isScanningLocal else { return }
        let token = UUID()
        localScanID = token
        isScanningLocal = true
        localRecords = []

        // 沙盒内扫描很快，但也一并保活，避免切后台被打断
        BackgroundKeeper.shared.begin(reason: "cleaner-scan-local")
        DispatchQueue.global(qos: .userInitiated).async {
            let found = CleanerService.scan()
            DispatchQueue.main.async {
                defer { BackgroundKeeper.shared.end() }
                guard self.localScanID == token else { return }
                self.localRecords = self.sortLocal(found)
                self.isScanningLocal = false
                self.hasScannedLocal = true
            }
        }
    }

    func refreshDevice() async {
        guard !isScanningDevice else { return }
        // 跨应用扫描要逐个租借容器，可能几十秒 —— 切后台必须能继续
        BackgroundKeeper.shared.begin(reason: "cleaner-scan-device")
        defer { BackgroundKeeper.shared.end() }

        let token = UUID()
        deviceScanID = token
        isScanningDevice = true
        deviceError = nil
        deviceScanned = 0
        deviceTotal = 0
        deviceRecords = []
        deviceUsages = [:]
        deviceApps = []

        do {
            let apps = try await DeviceCleaner.listApps()
            guard deviceScanID == token else { return }
            deviceApps = apps
            deviceTotal = apps.count

            // 分片并发：每片一条独立隧道，握手开销 = 片数（而不是应用数）。
            // 片内仍是 al_container_scan_many 的一次隧道扫多个应用。
            let chunkSize = 30
            let maxParallel = 6
            let chunks: [[DeviceApp]] = stride(from: 0, to: apps.count, by: chunkSize).map {
                Array(apps[$0..<min($0 + chunkSize, apps.count)])
            }

            var collected: [String: ContainerUsage] = [:]
            var done = 0

            await withTaskGroup(of: (Int, [ContainerScanEntry]).self) { group in
                var launched = 0

                func launch(_ index: Int) {
                    let ids = chunks[index].map(\.bundleID)
                    group.addTask {
                        let entries = (try? await DeviceCleaner.scanMany(bundleIDs: ids)) ?? []
                        return (index, entries)
                    }
                }

                while launched < chunks.count && launched < maxParallel {
                    launch(launched)
                    launched += 1
                }

                while let (index, entries) = await group.next() {
                    guard deviceScanID == token else { group.cancelAll(); return }
                    for e in entries where e.error == nil && e.bytes > 0 {
                        collected[e.bundleID] = ContainerUsage(bytes: e.bytes, items: e.items)
                    }
                    done += chunks[index].count
                    deviceScanned = done          // 只推进度数字，不动列表 → 不触发重排
                    if launched < chunks.count {
                        launch(launched)
                        launched += 1
                    }
                }
            }

            guard deviceScanID == token else { return }
            deviceUsages = collected
            deviceScanned = done
            deviceRecords = sortDevice(collected, apps: apps)
            isScanningDevice = false
            hasScannedDevice = true
        } catch {
            guard deviceScanID == token else { return }
            isScanningDevice = false
            hasScannedDevice = true
            deviceError = error.localizedDescription
        }
    }

    // MARK: - 排序

    func setSortOrder(_ order: CleanerSortOrder) {
        guard order != sortOrder else { return }
        sortOrder = order
        localRecords = sortLocal(localRecords)
        deviceRecords = sortDevice(deviceUsages, apps: deviceApps)
    }

    private func sortLocal(_ records: [CleanerRecord]) -> [CleanerRecord] {
        CleanerCatalog.sorted(records,
                              order: sortOrder,
                              size: { $0.usage.bytes },
                              displayName: { $0.title },
                              stableID: { $0.id })
    }

    private func sortDevice(_ usages: [String: ContainerUsage],
                            apps: [DeviceApp]) -> [DeviceAppRecord] {
        let records = apps.compactMap { app -> DeviceAppRecord? in
            guard let usage = usages[app.bundleID], usage.bytes > 0 else { return nil }
            return DeviceAppRecord(app: app, usage: usage)
        }
        return CleanerCatalog.sorted(records,
                                     order: sortOrder,
                                     size: { $0.usage.bytes },
                                     displayName: { $0.app.displayName },
                                     stableID: { $0.id })
    }

    // MARK: - 清理

    /// 清理本应用沙盒内的选中项，返回给用户看的结果文案
    func cleanLocal(ids: Set<String>) async -> String {
        BackgroundKeeper.shared.begin(reason: "cleaner-clean-local")
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = CleanerService.clean(ids)
                let fresh = CleanerService.scan()
                let message = "已释放 \(Self.sizeText(result.freedBytes))，删除 \(result.removedItemCount) 个文件。\(result.failedItemCount) 个项目无法清理。"
                DispatchQueue.main.async {
                    defer { BackgroundKeeper.shared.end() }
                    self.localRecords = self.sortLocal(fresh)
                    cont.resume(returning: message)
                }
            }
        }
    }

    /// 清理其他应用的选中项（一次隧道刷新区内体积），返回结果文案
    func cleanDevice(ids: Set<String>) async -> String {
        // 逐个应用租借容器 + 清理，可能很久 —— 切后台必须能继续
        BackgroundKeeper.shared.begin(reason: "cleaner-clean-device")
        defer { BackgroundKeeper.shared.end() }

        var freed: Int64 = 0
        var removed: Int64 = 0
        var failed: Int64 = 0
        var unavailable = 0

        for id in ids {
            do {
                let result = try await DeviceCleaner.clean(bundleID: id)
                freed += result.freedBytes
                removed += result.removed
                failed += result.failed
            } catch {
                unavailable += 1
            }
        }

        // 清理后一次性重新统计（一次隧道），比逐个刷新快得多
        let refreshed = (try? await DeviceCleaner.scanMany(bundleIDs: Array(ids))) ?? []
        for entry in refreshed where entry.error == nil {
            if entry.bytes > 0 {
                deviceUsages[entry.bundleID] = ContainerUsage(bytes: entry.bytes, items: entry.items)
            } else {
                deviceUsages.removeValue(forKey: entry.bundleID)
            }
        }
        deviceRecords = sortDevice(deviceUsages, apps: deviceApps)

        return "已释放 \(Self.sizeText(freed))，删除 \(removed) 个文件。\(failed + Int64(unavailable)) 个项目或应用无法清理。"
    }

    static func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
