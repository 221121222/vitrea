//
//  CleanerService.swift
//  Vitrea
//
//  清理服务 —— 交互与边界参照 ThreeOneOSFive（3105）的「有限清理」：
//  只处理 App 沙盒内可再生的临时数据（Library/Caches 与 tmp），
//  Documents、UserDefaults、钥匙串、配对记录、写入日志一律不碰。
//  · 目录白名单 + 根目录校验，越界直接抛错，绝不递归到沙盒之外
//  · 扫描统计体积与文件数，清理逐项计数成败，返回真实释放量
//  · 符号链接不跟随、不计数、不删除
//

import Foundation
import UIKit

// MARK: - 共享 HTTP 缓存（集中持有，便于统计与清理）

enum AppHTTPCache {
    static let cardArt = URLCache(memoryCapacity: 48 * 1024 * 1024,
                                  diskCapacity: 256 * 1024 * 1024,
                                  diskPath: "CardArtHTTP")

    static let stickers = URLCache(memoryCapacity: 32 * 1024 * 1024,
                                   diskCapacity: 256 * 1024 * 1024,
                                   diskPath: "Stickers")
}

// MARK: - 数据模型

struct CleanerUsage: Equatable {
    let bytes: Int64
    let itemCount: Int

    static let empty = CleanerUsage(bytes: 0, itemCount: 0)
}

struct CleanerResult: Equatable {
    let freedBytes: Int64
    let removedItemCount: Int
    let failedItemCount: Int
}

enum CleanerError: Error, Equatable {
    case unsafeRoot   // 目标不在允许的沙盒目录内
}

/// 可清理项（白名单，新增项目必须显式登记）
enum CleanerTarget: String, CaseIterable, Identifiable {
    case cardImages
    case httpCache
    case stickerCache
    case temporaryFiles

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cardImages:     return "卡面图片缓存"
        case .httpCache:      return "网络请求缓存"
        case .stickerCache:   return "贴纸素材缓存"
        case .temporaryFiles: return "临时文件"
        }
    }

    var subtitle: String {
        switch self {
        case .cardImages:     return "Caches/VitreaCardCache · 清理后重新联网加载"
        case .httpCache:      return "Caches/CardArtHTTP · 清理后重新联网加载"
        case .stickerCache:   return "Caches/Stickers · 清理后重新联网加载"
        case .temporaryFiles: return "tmp · 写入过程产生的暂存文件"
        }
    }

    var systemImage: String {
        switch self {
        case .cardImages:     return "photo.stack.fill"
        case .httpCache:      return "network"
        case .stickerCache:   return "sticker.fill"
        case .temporaryFiles: return "internaldrive.fill"
        }
    }
}

struct CleanerRecord: Identifiable, Equatable {
    let target: CleanerTarget
    let usage: CleanerUsage

    var id: String { target.id }
    var title: String { target.title }
    var subtitle: String { target.subtitle }
}

// MARK: - 排序 / 选择（与 3105 的 CleanerCatalog 同构）

enum CleanerSortOrder: String, CaseIterable, Identifiable {
    case largestFirst
    case smallestFirst

    var id: String { rawValue }

    var title: String {
        switch self {
        case .largestFirst:  return "从大到小"
        case .smallestFirst: return "从小到大"
        }
    }
}

enum CleanerCatalog {
    static func sorted<Record>(
        _ records: [Record],
        order: CleanerSortOrder,
        size: (Record) -> Int64,
        displayName: (Record) -> String,
        stableID: (Record) -> String
    ) -> [Record] {
        records.sorted { left, right in
            let leftSize = size(left)
            let rightSize = size(right)
            if leftSize != rightSize {
                switch order {
                case .largestFirst:  return leftSize > rightSize
                case .smallestFirst: return leftSize < rightSize
                }
            }
            let nameComparison = displayName(left).localizedCaseInsensitiveCompare(displayName(right))
            if nameComparison != .orderedSame { return nameComparison == .orderedAscending }
            return stableID(left).localizedCaseInsensitiveCompare(stableID(right)) == .orderedAscending
        }
    }

    static func selectingAllVisible(
        _ visibleIDs: [String],
        preserving selectedIDs: Set<String>
    ) -> Set<String> {
        selectedIDs.union(visibleIDs)
    }
}

// MARK: - 清理服务

enum CleanerService {

    private static let fm = FileManager.default

    private static var cachesRoot: URL {
        fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    }

    private static var tmpRoot: URL { fm.temporaryDirectory }

    // MARK: 扫描

    /// 只返回有体积的项目（0 字节不打扰用户）
    static func scan() -> [CleanerRecord] {
        CleanerTarget.allCases.compactMap { target in
            let usage = usage(for: target)
            guard usage.bytes > 0 else { return nil }
            return CleanerRecord(target: target, usage: usage)
        }
    }

    static func usage(for target: CleanerTarget) -> CleanerUsage {
        switch target {
        case .cardImages:
            return directoryUsage(ImageCacheStore.shared.diskCacheURL)
        case .httpCache:
            return cacheUsage(directories: urlCacheDiskURLs("CardArtHTTP"),
                              cache: AppHTTPCache.cardArt)
        case .stickerCache:
            return cacheUsage(directories: urlCacheDiskURLs("Stickers"),
                              cache: AppHTTPCache.stickers)
        case .temporaryFiles:
            return directoryUsage(tmpRoot)
        }
    }

    // MARK: 清理

    /// 按选中项清理。返回真实释放量（清理前后各统计一次）。
    static func clean(_ ids: Set<String>) -> CleanerResult {
        var beforeBytes: Int64 = 0
        var afterBytes: Int64 = 0
        var removed = 0
        var failed = 0

        for target in CleanerTarget.allCases where ids.contains(target.id) {
            beforeBytes += usage(for: target).bytes
            do {
                try cleanTarget(target, removed: &removed, failed: &failed)
            } catch {
                failed += 1
            }
            afterBytes += usage(for: target).bytes
        }

        purgeMemoryCaches()
        return CleanerResult(freedBytes: max(0, beforeBytes - afterBytes),
                             removedItemCount: removed,
                             failedItemCount: failed)
    }

    /// 只释放内存里的解码位图（磁盘不动）
    static func purgeMemoryCaches() {
        DispatchQueue.main.async {
            ImageCacheStore.shared.purgeMemory()
            StickerService.shared.purgeMemory()
        }
    }

    private static func cleanTarget(_ target: CleanerTarget,
                                    removed: inout Int,
                                    failed: inout Int) throws {
        switch target {
        case .cardImages:
            let dir = ImageCacheStore.shared.diskCacheURL
            try removeContents(of: dir, removed: &removed, failed: &failed)
            // 目录本身保留：ImageCacheStore 初始化时创建，删掉后不会重建
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        case .httpCache:
            AppHTTPCache.cardArt.removeAllCachedResponses()
            for dir in urlCacheDiskURLs("CardArtHTTP") {
                try? removeContents(of: dir, removed: &removed, failed: &failed)
            }

        case .stickerCache:
            AppHTTPCache.stickers.removeAllCachedResponses()
            for dir in urlCacheDiskURLs("Stickers") {
                try? removeContents(of: dir, removed: &removed, failed: &failed)
            }

        case .temporaryFiles:
            try removeContents(of: tmpRoot, removed: &removed, failed: &failed)
        }
    }

    // MARK: 目录工具

    /// URLCache 的落盘目录不一定能被枚举到，此时退回它自己上报的磁盘占用
    private static func cacheUsage(directories: [URL], cache: URLCache) -> CleanerUsage {
        let scanned = merged(directories.map(directoryUsage))
        guard scanned.bytes == 0 else { return scanned }
        let reported = Int64(cache.currentDiskUsage)
        return CleanerUsage(bytes: reported, itemCount: scanned.itemCount)
    }

    /// URLCache 的 diskPath 在不同系统上可能落在 Caches 根或 Caches/<bundle id> 下，两个候选都认
    private static func urlCacheDiskURLs(_ path: String) -> [URL] {
        var candidates = [cachesRoot.appendingPathComponent(path, isDirectory: true)]
        if let bundleID = Bundle.main.bundleIdentifier {
            candidates.append(
                cachesRoot
                    .appendingPathComponent(bundleID, isDirectory: true)
                    .appendingPathComponent(path, isDirectory: true)
            )
        }
        return candidates.filter { fm.fileExists(atPath: $0.path) }
    }

    /// 递归统计：只算普通文件，符号链接与特殊节点一律跳过
    private static func directoryUsage(_ url: URL) -> CleanerUsage {
        let root = url.standardizedFileURL
        guard (try? validate(root)) != nil,
              let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
              ) else {
            return .empty
        }

        var bytes: Int64 = 0
        var count = 0
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true { continue }
            guard values?.isRegularFile == true else { continue }
            bytes += Int64(values?.fileSize ?? 0)
            count += 1
        }
        return CleanerUsage(bytes: bytes, itemCount: count)
    }

    private static func removeContents(of directory: URL,
                                       removed: inout Int,
                                       failed: inout Int) throws {
        let root = directory.standardizedFileURL
        try validate(root)

        let children = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for child in children {
            do {
                try fm.removeItem(at: child)
                removed += 1
            } catch {
                let code = (error as NSError).code
                if code != NSFileNoSuchFileError { failed += 1 }
            }
        }
    }

    /// 根目录校验：只允许 Caches 下的子目录与 tmp 根目录本身
    private static func validate(_ url: URL) throws {
        guard url.isFileURL else { throw CleanerError.unsafeRoot }
        let path = url.path
        let caches = cachesRoot.standardizedFileURL.path
        let tmp = tmpRoot.standardizedFileURL.path
        let insideCaches = path.hasPrefix(caches + "/") && path != caches
        guard path == tmp || insideCaches else { throw CleanerError.unsafeRoot }
    }

    private static func merged(_ usages: [CleanerUsage]) -> CleanerUsage {
        usages.reduce(.empty) {
            CleanerUsage(bytes: $0.bytes + $1.bytes, itemCount: $0.itemCount + $1.itemCount)
        }
    }
}
