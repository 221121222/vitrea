//
//  CardArtAPI.swift
//  Vitrea
//
//  cardart.cc 公开只读接口：wander 卡面流 / search 搜索。
//  不做点赞、收藏、关注等需要登录态的交互，也不做批量抓取。
//

import Foundation

enum CardArtAPIError: LocalizedError {
    case badStatus(Int)
    case decodeFailed
    case empty

    var errorDescription: String? {
        switch self {
        case .badStatus(let c): return "服务异常（HTTP \(c)），请稍后重试"
        case .decodeFailed:    return "卡面数据解析失败"
        case .empty:           return "没有找到相关卡面"
        }
    }
}

final class CardArtAPI {
    static let shared = CardArtAPI()

    private let base = URL(string: "https://cardart.cc")!
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()

    private init() {}

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = [], as type: T.Type) async throws -> T {
        guard var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw CardArtAPIError.badStatus(0)
        }
        if !query.isEmpty { comps.queryItems = query }
        let (data, resp) = try await session.data(from: comps.url!)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CardArtAPIError.badStatus((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw CardArtAPIError.decodeFailed
        }
    }

    /// 随机游走卡面流。seed 为游标：首页传 nil，翻页传上一次返回的 seed。
    func wander(seed: String?) async throws -> WanderResponse {
        let q = seed.map { [URLQueryItem(name: "seed", value: $0)] } ?? []
        return try await get("api/wander", query: q, as: WanderResponse.self)
    }

    /// 搜索（标题 / tag / 作者名）
    func search(_ keyword: String) async throws -> [GalleryCard] {
        let resp: SearchResponse = try await get(
            "api/search",
            query: [URLQueryItem(name: "q", value: keyword)],
            as: SearchResponse.self
        )
        let hits = resp.cards ?? []
        return hits.compactMap { hit -> GalleryCard? in
            guard let images = hit.images else { return nil }
            return GalleryCard(
                id: hit.id,
                title: hit.title,
                titleEn: hit.titleEn,
                dominantColor: hit.dominantColor,
                images: images,
                author: hit.author,
                likeCount: nil,
                downloadCount: nil
            )
        }
    }

    /// 按站点真实浏览分类拉取卡面（卡组织 / 发卡机构）。
    /// filter 形如 "issuerKind=bank" 或 "type=payment&network=visa"。
    /// 站点没有开放按分类的 JSON 接口，这里解析 /explore 页 SSR 渲染的卡片网格。
    func exploreCards(filter: String) async throws -> [GalleryCard] {
        guard var comps = URLComponents(url: base.appendingPathComponent("explore"),
                                        resolvingAgainstBaseURL: false) else {
            throw CardArtAPIError.badStatus(0)
        }
        comps.query = filter
        let (data, resp) = try await session.data(from: comps.url!)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CardArtAPIError.badStatus((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw CardArtAPIError.decodeFailed
        }
        return Self.parseExploreHTML(html)
    }

    // MARK: - explore 页 HTML 解析

    private static func parseExploreHTML(_ html: String) -> [GalleryCard] {
        guard let tileRegex = try? NSRegularExpression(
            pattern: #"<article class="ca-tile"[^>]*>.*?</article>"#,
            options: [.dotMatchesLineSeparators]) else { return [] }
        let full = NSRange(html.startIndex..., in: html)
        let tiles = tileRegex.matches(in: html, range: full)
        var out: [GalleryCard] = []
        for t in tiles {
            guard let r = Range(t.range, in: html) else { continue }
            if let card = parseTile(String(html[r])) { out.append(card) }
        }
        return out
    }

    private static func parseTile(_ block: String) -> GalleryCard? {
        guard let id = firstMatch(block, #"href="/c/([A-Za-z0-9]+)""#) else { return nil }
        let name = firstMatch(block, #"<span class="ca-tile-name">([^<]+)</span>"#)
        let dom = firstMatch(block, #"--ca-dom:(#[0-9a-fA-F]{6})"#)
        let srcSet = firstMatch(block, #"srcSet="([^"]+)""#) ?? ""
        var w480: String?, w640: String?, w1024: String?, w1536: String?
        for part in srcSet.components(separatedBy: ", ") where !part.isEmpty {
            let comps = part.components(separatedBy: " ")
            guard comps.count == 2,
                  let w = Int(comps[1].replacingOccurrences(of: "w", with: "")) else { continue }
            switch w {
            case 480:  w480 = comps[0]
            case 640:  w640 = comps[0]
            case 1024: w1024 = comps[0]
            case 1536: w1536 = comps[0]
            default:   break
            }
        }
        let author = parseAuthor(block)
        let images = GalleryImages(png: nil, w1536: w1536, w1024: w1024,
                                   w640: w640, w480: w480)
        return GalleryCard(id: id, title: name, titleEn: nil, dominantColor: dom,
                           images: images, author: author, likeCount: nil, downloadCount: nil)
    }

    private static func parseAuthor(_ block: String) -> GalleryAuthor? {
        // 作者链接形如 title="昵称" href="/u/昵称"，名字在 title 属性里
        guard let re = try? NSRegularExpression(
            pattern: #"title="([^"]+)"[^>]*href="/u/([A-Za-z0-9_]+)""#) else { return nil }
        guard let r = re.firstMatch(in: block, range: NSRange(block.startIndex..., in: block)),
              r.numberOfRanges > 2,
              let nameRange = Range(r.range(at: 1), in: block),
              let handleRange = Range(r.range(at: 2), in: block) else { return nil }
        let handle = String(block[handleRange])
        let name = String(block[nameRange])
        return GalleryAuthor(id: handle, name: name, handle: handle, image: nil)
    }

    private static func firstMatch(_ s: String, _ pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        guard let r = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              r.numberOfRanges > 1, let range = Range(r.range(at: 1), in: s) else { return nil }
        return String(s[range])
    }

    /// 下载原图（写入 / 编辑用）
    func downloadOriginal(_ url: URL) async throws -> Data {
        let (data, resp) = try await session.data(from: url)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CardArtAPIError.badStatus((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return data
    }

    /// 首页精选卡面：解析 https://cardart.cc/ 的 ca-tile 网格
    func featuredCards() async throws -> [GalleryCard] {
        let (data, resp) = try await session.data(from: base)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CardArtAPIError.badStatus((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw CardArtAPIError.decodeFailed
        }
        return Self.parseExploreHTML(html)
    }

    /// 作者主页所有作品：解析 https://cardart.cc/u/<handle>
    func authorWorks(handle: String) async throws -> [GalleryCard] {
        let url = base.appendingPathComponent("u/\(handle)")
        let (data, resp) = try await session.data(from: url)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CardArtAPIError.badStatus((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw CardArtAPIError.decodeFailed
        }
        return Self.parseExploreHTML(html)
    }
}
