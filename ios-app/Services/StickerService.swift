//
//  StickerService.swift
//  Vitrea
//
//  卡面素材（贴纸）全部走在线加载，来自 cardart.cc/maker。
//  站点素材现为 SVG，iOS 不认矢量数据，故下载后就地栅格化并缓存（内存 + 磁盘）。
//

import UIKit
import SwiftUI

final class StickerService {
    static let shared = StickerService()

    /// 素材在线地址（可通过 UserDefaults 覆盖，方便换源）
    private var baseURL: String {
        UserDefaults.standard.string(forKey: "stickerBaseURL")
            ?? "https://cardart.cc/maker/"
    }

    /// 栅格化结果缓存（SVG 解析有成本，避免每次滚动重复解码）
    private let rasterCache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 300
        return c
    }()

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        // 与清理服务共用同一实例：CleanerService 需要拿到它才能清空响应与磁盘
        cfg.urlCache = AppHTTPCache.stickers
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        cfg.timeoutIntervalForRequest = 25
        cfg.httpMaximumConnectionsPerHost = 8
        return URLSession(configuration: cfg)
    }()

    private init() {}

    /// 贴纸的远程 URL
    func stickerURL(for file: String) -> URL? {
        let trimmed = file.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let base = baseURL.hasSuffix("/") ? baseURL : baseURL + "/"
        return URL(string: base + trimmed)
    }

    /// 加载贴纸图：在线取回 → SVG 就地栅格化 → 缓存。失败返回 nil。
    func loadSticker(_ file: String, targetWidth: CGFloat = 512) async -> UIImage? {
        if let cached = rasterCache.object(forKey: file as NSString) { return cached }
        guard let url = stickerURL(for: file) else { return nil }

        do {
            let (data, _) = try await session.data(from: url)
            let image: UIImage?
            if file.lowercased().hasSuffix(".svg") {
                image = SVGRenderer.image(from: data, targetWidth: targetWidth)
            } else {
                image = UIImage(data: data)
            }
            if let image {
                rasterCache.setObject(image, forKey: file as NSString)
            }
            return image
        } catch {
            return nil
        }
    }

    /// 加载贴纸清单与材质清单（嵌入在 App 内，仅几百 KB）
    static func loadManifest<T: Decodable>(_ name: String, as type: T.Type) -> T? {
        guard let path = Bundle.main.path(forResource: "Manifests/\(name)", ofType: "json"),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - 贴纸图片视图（在线加载 + 占位）

struct RemoteStickerImage: View {
    let file: String
    var size: CGFloat = 58

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else if failed {
                Image(systemName: "photo")
                    .font(.caption)
                    .foregroundColor(.secondary.opacity(0.35))
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: size, height: size)
        .background(Color.primary.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .task(id: file) {
            if let cached = StickerService.shared.cached(file) { image = cached; return }
            image = nil
            failed = false
            if let img = await StickerService.shared.loadSticker(file) {
                image = img
            } else {
                failed = true
            }
        }
    }
}

extension StickerService {
    /// 已栅格化的贴纸（用于视图重建时秒显）
    func cached(_ file: String) -> UIImage? {
        rasterCache.object(forKey: file as NSString)
    }

    /// 释放栅格化内存缓存（清理页调用；磁盘缓存由 CleanerService 处理）
    func purgeMemory() {
        rasterCache.removeAllObjects()
    }
}
