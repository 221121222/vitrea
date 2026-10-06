//
//  GalleryCard.swift
//  Vitrea
//
//  卡面库（cardart.cc）的领域模型。
//
//  ⚠️ 放在 `Shared/` 下，**主 App 与 VitreaWidgets 扩展都会编译它** ——
//  随机卡面小组件需要自己解码 `api/wander` 的响应，共用同一份模型可以避免两边各写一套。
//  所以这里只能依赖 Foundation，不能引入 UIKit。
//

import Foundation

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
        if path.hasPrefix("http"), let url = URL(string: path) { return url }
        return URL(string: "https://cardart.cc\(path)")
    }
}

struct WanderResponse: Codable {
    let seed: String
    let cards: [GalleryCard]
}
