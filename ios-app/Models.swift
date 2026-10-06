//
//  Models.swift
//  Vitrea
//
//  领域模型 + 卡面渲染管线。
//

import UIKit
import CoreGraphics
import SwiftUI

// MARK: - 卡面库（cardart.cc）

struct GalleryAuthor: Codable, Equatable {
    let id: String
    let name: String
    let handle: String?
    let image: String?
}

struct GalleryImages: Codable, Equatable {
    let png: String?
    let w1536: String?
    let w1024: String?
    let w640: String?
    let w480: String?
}

struct GalleryCard: Identifiable, Codable, Equatable {
    let id: String
    let title: String?
    let titleEn: String?
    let dominantColor: String?
    let images: GalleryImages
    let author: GalleryAuthor?
    let likeCount: Int?
    let downloadCount: Int?

    var displayTitle: String {
        let t = title?.trimmingCharacters(in: .whitespaces)
        if let t, !t.isEmpty { return t }
        if let e = titleEn, !e.isEmpty { return e }
        return "未命名卡面"
    }

    var authorName: String { author?.name ?? "未知作者" }

    /// 列表缩略图：w480 → w640 → w1024 逐级兜底
    var thumbURL: URL? {
        Self.resolve(images.w480 ?? images.w640 ?? images.w1024)
    }
    /// 详情大图：w1536 → w1024 → w640
    var largeURL: URL? {
        Self.resolve(images.w1536 ?? images.w1024 ?? images.w640)
    }
    /// 原图：png 优先，否则用 /c/{id}/download 端点
    var originalURL: URL? {
        if let png = images.png { return Self.resolve(png) }
        return URL(string: "https://cardart.cc/c/\(id)/download")
    }

    static func resolve(_ path: String?) -> URL? {
        guard let path else { return nil }
        return URL(string: "https://cardart.cc\(path)")
    }
}

struct WanderResponse: Codable {
    let seed: String
    let cards: [GalleryCard]
}

struct SearchResponse: Codable {
    let cards: [SearchHit]?

    struct SearchHit: Codable {
        let id: String
        let title: String?
        let titleEn: String?
        let images: GalleryImages?
        let author: GalleryAuthor?
        let dominantColor: String?
    }
}

// MARK: - 设备钱包卡（写入目标）

struct WalletCard: Identifiable, Equatable {
    let id: String                       // 卡标识 hash
    var displayName: String?
    var paymentNetwork: String?
    var isSelected: Bool = true

    var title: String {
        if let displayName, !displayName.isEmpty { return displayName }
        if let paymentNetwork, !paymentNetwork.isEmpty {
            return paymentNetwork.hasSuffix("Card") ? paymentNetwork : "\(paymentNetwork) Card"
        }
        return "支付卡"
    }

    static func cleanCardId(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "'\",()<>;[]{}"))
        if s.contains("/") { s = (s as NSString).lastPathComponent }
        for ext in [".pkpass", ".cache", ".pkcache"] where s.hasSuffix(ext) {
            s = String(s.dropLast(ext.count))
        }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "'\",()<>;[]{}. "))
        guard s.count >= 20, s.count <= 64, !s.contains("/") else { return nil }
        if s.count == 36, s.filter({ $0 == "-" }).count == 4 { return nil }
        return s
    }
}

// MARK: - 卡面渲染管线（复用上游公开方案）

enum ImageEngine {

    /// ImageIO 降维解码，避免整张位图撑爆内存
    static func safeImageFromData(_ data: Data, maxDimension: CGFloat = 2048) -> UIImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else {
            return UIImage(data: data).map { normalizeAndDownsample($0, maxDimension: maxDimension) }
        }
        let down: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension
        ]
        if let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, down as CFDictionary) {
            return UIImage(cgImage: cg)
        }
        return UIImage(data: data).map { normalizeAndDownsample($0, maxDimension: maxDimension) }
    }

    static func normalizeAndDownsample(_ image: UIImage, maxDimension: CGFloat = 2048) -> UIImage {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }
        let scale = min(1.0, maxDimension / max(size.width, size.height))
        let target = CGSize(width: floor(size.width * scale), height: floor(size.height * scale))
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1; fmt.opaque = false
        let renderer = UIGraphicsImageRenderer(size: target, format: fmt)
        return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
    }

    /// 铺成不透明底图：先填黑底，再把图片 aspect fill 画上去。
    /// 部分机型对带透明通道的卡面底图会渲染出杂色，这里统一压平。
    static func makeOpaqueFill(_ image: UIImage, size: CGSize) -> UIImage {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: fmt)
        return renderer.image { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            guard image.size.width > 0, image.size.height > 0 else { return }
            let scale = max(size.width / image.size.width, size.height / image.size.height)
            let scaled = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let origin = CGPoint(x: (size.width - scaled.width) / 2, y: (size.height - scaled.height) / 2)
            image.draw(in: CGRect(origin: origin, size: scaled))
        }
    }

    /// aspect fill 到精确尺寸
    static func resizeFill(_ image: UIImage, size: CGSize) -> Data? {
        guard image.size.width > 0, image.size.height > 0 else { return nil }
        let scale = max(size.width / image.size.width, size.height / image.size.height)
        let scaled = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let origin = CGPoint(x: (size.width - scaled.width) / 2, y: (size.height - scaled.height) / 2)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: fmt)
        let out = renderer.image { _ in image.draw(in: CGRect(origin: origin, size: scaled)) }
        return out.pngData()
    }

    /// 1536×969 主卡面
    static func prepareCardImage(from image: UIImage) -> Data? {
        let normalized = normalizeAndDownsample(image, maxDimension: 2560)
        return resizeFill(normalized, size: CGSize(width: 1536, height: 969))
    }

    /// 全套卡面：@3x(1536×969) + @2x(1024×646) + 交通卡 PDF
    static func prepareAllCardSkins(from image: UIImage) -> [String: Data] {
        let normalized = normalizeAndDownsample(image, maxDimension: 2560)
        var skins: [String: Data] = [:]

        if let d3 = resizeFill(normalized, size: CGSize(width: 1536, height: 969)) {
            skins["cardBackgroundCombined@3x.png"] = d3
            skins["diffuse@3x.png"] = d3
            skins["background@3x.png"] = d3
            skins["strip@3x.png"] = d3
        }
        if let d2 = resizeFill(normalized, size: CGSize(width: 1024, height: 646)) {
            skins["cardBackgroundCombined@2x.png"] = d2
            skins["diffuse@2x.png"] = d2
            skins["background@2x.png"] = d2
            skins["strip@2x.png"] = d2
        }

        // 交通卡（Suica / PASMO / 八达通等）矢量 PDF
        let rect = CGRect(origin: .zero, size: CGSize(width: 1536, height: 969))
        let pdf = UIGraphicsPDFRenderer(bounds: rect).pdfData { ctx in
            ctx.beginPage()
            normalized.draw(in: rect)
        }
        skins["cardBackgroundCombined.pdf"] = pdf
        skins["background.pdf"] = pdf
        skins["strip.pdf"] = pdf

        return skins
    }
}
