//
//  ImageCache.swift
//  Vitrea
//
//  在线直连 + 内存缓存 + 本地持久化缓存。
//  · 同一 URL 的下载任务合并，列表快速滑动时不重复请求
//  · 缩略图常驻内存缓存，详情页返回列表不再闪占位图
//  · 解码后的位图按像素成本计入缓存，收到内存警告时统一释放
//

import SwiftUI
import UIKit
import CryptoKit

// MARK: - 缓存仓库

final class ImageCacheStore {
    static let shared = ImageCacheStore()

    /// 已解码位图（成本按像素计）
    private let memory = NSCache<NSURL, UIImage>()
    /// 合并中的下载任务，避免同一 URL 重复请求
    private var inFlight: [URL: Task<UIImage, Error>] = [:]
    private let lock = NSLock()

    private let queue = DispatchQueue(label: "vitrea.imagecache", qos: .utility)
    private let diskURL: URL

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        cfg.waitsForConnectivity = false
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        cfg.urlCache = URLCache(memoryCapacity: 48 * 1024 * 1024,
                                diskCapacity: 256 * 1024 * 1024,
                                diskPath: "CardArtHTTP")
        cfg.httpMaximumConnectionsPerHost = 8
        return URLSession(configuration: cfg)
    }()

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        diskURL = caches.appendingPathComponent("VitreaCardCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskURL, withIntermediateDirectories: true)

        // 内存上限：约 140MB 解码成本；缩略图数量上限放宽，保证回列表秒显
        memory.totalCostLimit = 140 * 1024 * 1024
        memory.countLimit = 500

        NotificationCenter.default.addObserver(
            self, selector: #selector(purgeMemory),
            name: UIApplication.didReceiveMemoryWarningNotification, object: nil
        )
    }

    @objc func purgeMemory() {
        memory.removeAllObjects()
    }

    private func key(for url: URL) -> String {
        let data = Data(url.absoluteString.utf8)
        return SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
    }

    private func diskFile(for url: URL) -> URL {
        diskURL.appendingPathComponent(key(for: url))
    }

    /// 同步取内存缓存（视图重新出现时即时恢复，避免闪占位图）
    func cachedImage(for url: URL) -> UIImage? {
        memory.object(forKey: url as NSURL)
    }

    /// 取图：内存 → 磁盘（降维解码）→ 网络。同一 URL 并发调用只发一次请求。
    func load(_ url: URL, maxDimension: CGFloat) async throws -> UIImage {
        if let cached = memory.object(forKey: url as NSURL) { return cached }

        let task = lock.withLock { () -> Task<UIImage, Error> in
            if let running = inFlight[url] { return running }
            let t = Task { [weak self] () throws -> UIImage in
                defer {
                    if let s = self {
                        s.lock.withLock { s.inFlight.removeValue(forKey: url) }
                    }
                }
                guard let s = self else { throw CancellationError() }
                return try await s.fetch(url, maxDimension: maxDimension)
            }
            inFlight[url] = t
            return t
        }

        return try await task.value
    }

    private func fetch(_ url: URL, maxDimension: CGFloat) async throws -> UIImage {
        let file = diskFile(for: url)
        var dataToDecode: Data?

        if let disk = try? Data(contentsOf: file), !disk.isEmpty {
            dataToDecode = disk
        } else {
            let (data, _) = try await session.data(from: url)
            dataToDecode = data
            // 异步持久化原始数据，不阻塞首屏
            queue.async { try? data.write(to: file, options: .atomic) }
        }

        guard let data = dataToDecode,
              let image = ImageEngine.safeImageFromData(data, maxDimension: maxDimension) else {
            throw NSError(domain: "ImageCache", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "图片解码失败"])
        }

        let cost = Int(image.size.width * image.size.height * 4)
        memory.setObject(image, forKey: url as NSURL, cost: cost)
        return image
    }

    /// 预取：列表首屏 / 翻页后提前把缩略图拉进缓存，滑到即显示
    func prefetch(_ urls: [URL], maxDimension: CGFloat = 640) {
        let pending = urls.filter { memory.object(forKey: $0 as NSURL) == nil }
        guard !pending.isEmpty else { return }
        Task.detached(priority: .utility) {
            await withTaskGroup(of: Void.self) { group in
                var active = 0
                for url in pending {
                    if active >= 4 {
                        await group.next()
                        active -= 1
                    }
                    group.addTask { _ = try? await ImageCacheStore.shared.load(url, maxDimension: maxDimension) }
                    active += 1
                }
            }
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}

// MARK: - 缓存图片视图

@MainActor
final class ImageLoader: ObservableObject {
    @Published var image: UIImage?
    @Published var failed = false

    private var task: Task<Void, Never>?
    private var currentURL: URL?
    private var loadingURL: URL?

    func load(_ url: URL?, maxDimension: CGFloat = 640) {
        guard let url else { return }
        // 同一张图：已显示就不再动，正在加载也不打断（否则来回进出会反复重启任务）
        if url == currentURL, image != nil || url == loadingURL { return }
        currentURL = url
        task?.cancel()
        failed = false

        // 内存缓存命中：同步恢复，返回列表时零闪烁
        if let cached = ImageCacheStore.shared.cachedImage(for: url) {
            image = cached
            loadingURL = nil
            return
        }

        loadingURL = url
        task = Task { [weak self] in
            do {
                let img = try await ImageCacheStore.shared.load(url, maxDimension: maxDimension)
                if !Task.isCancelled {
                    await MainActor.run {
                        self?.image = img
                        self?.loadingURL = nil
                    }
                }
            } catch {
                if !Task.isCancelled {
                    await MainActor.run {
                        self?.failed = true
                        self?.loadingURL = nil
                    }
                }
            }
        }
    }

    /// 滚出屏幕：只停掉未完成的下载，已解码的图继续留在内存缓存里，
    /// 这样从详情页返回列表时缩略图不会被清空（旧实现会留下空白卡面）。
    func releaseForOffscreen() {
        task?.cancel()
        task = nil
        loadingURL = nil
    }
}

struct CachedImageView: View {
    let url: URL?
    var maxDimension: CGFloat = 640
    var contentMode: ContentMode = .fill
    /// 大图未就绪前先显示已经缓存的小图（详情页秒开）
    var placeholderURL: URL? = nil

    @StateObject private var loader = ImageLoader()

    var body: some View {
        ZStack {
            if let image = loader.image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            } else if let ph = placeholderURL,
                      let fallback = ImageCacheStore.shared.cachedImage(for: ph) {
                Image(uiImage: fallback)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if loader.failed {
                Image(systemName: "photo.badge.exclamationmark")
                    .font(.title2)
                    .foregroundColor(.secondary.opacity(0.5))
            } else {
                GlassListPlaceholder()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .onAppear { loader.load(url, maxDimension: maxDimension) }
        .onDisappear { loader.releaseForOffscreen() }
    }
}

/// 列表占位：微动玻璃光泽（非纯色方块）
private struct GlassListPlaceholder: View {
    @Environment(\.colorScheme) private var scheme
    @State private var shift = false

    var body: some View {
        let base = scheme == .dark ? 0.16 : 0.08
        LinearGradient(
            colors: [
                Color.primary.opacity(base),
                Color.primary.opacity(base + 0.10),
                Color.primary.opacity(base)
            ],
            startPoint: .leading, endPoint: .trailing
        )
        .onAppear {
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { shift = true }
        }
    }
}
