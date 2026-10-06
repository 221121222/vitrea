//
//  RandomCard.swift
//  Vitrea
//
//  「随机卡面」的共用内核，**主 App 与 VitreaWidgets 扩展都会编译**。
//
//  组成：
//    · `RandomCardFetcher` —— 打 cardart.cc/api/wander 随机取一张卡面
//    · `RandomCardStore`   —— 小组件容器内的「下一张」暂存（按钮换卡用）
//    · `RandomCardLink`    —— `vitrea://card?d=<base64url(JSON)>` 深链编解码
//    · `ShuffleRandomCardIntent` —— 小组件上「换一张」按钮用的 App Intent
//
//  深链把整张卡面编进 URL，是因为站点**没有「按 id 取卡面」的接口** ——
//  只有 api/wander（随机流）与 api/search。把 JSON 塞进 URL 就能保证
//  小组件上看到的那张，点开就是那一张（而不是又随机一张）。
//

import AppIntents
import Foundation
import WidgetKit

// MARK: - 随机取一张

enum RandomCardFetcher {

    static let baseURL = URL(string: "https://cardart.cc")!

    /// 随机取一张卡面。失败抛错，调用方决定怎么兜底。
    static func fetch(session: URLSession = .shared) async throws -> GalleryCard {
        var comps = URLComponents(url: baseURL.appendingPathComponent("api/wander"),
                                  resolvingAgainstBaseURL: false)
        // 带一个随机 seed，尽量避开 CDN / 服务端缓存拿到同一张
        comps?.queryItems = [URLQueryItem(name: "seed", value: UUID().uuidString)]
        guard let url = comps?.url else { throw URLError(.badURL) }

        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        req.setValue("Vitrea/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
        req.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let wander = try JSONDecoder().decode(WanderResponse.self, from: data)
        guard !wander.cards.isEmpty else { throw URLError(.zeroByteResource) }
        // 服务端本身是随机游走，这里再随机挑一张，避免每次都拿流里第一张
        return wander.cards.randomElement() ?? wander.cards[0]
    }
}

// MARK: - 小组件容器内的暂存

/// 「换一张」按钮抽到的卡先落到这里，小组件的 TimelineProvider 优先取它，
/// 取走即清空 —— 这样按钮点下去一定换，而平时的时间线刷新又会自然轮换。
enum RandomCardStore {

    private static let key = "vitrea.randomCard.pending"
    private static let lastKey = "vitrea.randomCard.last"

    /// 小组件扩展自己的 UserDefaults（与主 App 容器无关，够用）
    private static var defaults: UserDefaults { .standard }

    static func stash(_ card: GalleryCard) {
        guard let data = try? JSONEncoder().encode(card) else { return }
        defaults.set(data, forKey: key)
    }

    /// 取出并清空
    static func takePending() -> GalleryCard? {
        guard let data = defaults.data(forKey: key),
              let card = try? JSONDecoder().decode(GalleryCard.self, from: data) else { return nil }
        defaults.removeObject(forKey: key)
        return card
    }

    /// 上一次成功展示的卡（离线时兜底用，避免小组件空白）
    static func saveLast(_ card: GalleryCard) {
        guard let data = try? JSONEncoder().encode(card) else { return }
        defaults.set(data, forKey: lastKey)
    }

    static func last() -> GalleryCard? {
        guard let data = defaults.data(forKey: lastKey),
              let card = try? JSONDecoder().decode(GalleryCard.self, from: data) else { return nil }
        return card
    }
}

// MARK: - 深链编解码

enum RandomCardLink {

    static let scheme = "vitrea"
    static let host = "card"

    /// 把整张卡面编进 URL：`vitrea://card?d=<base64url(JSON)>`
    static func url(for card: GalleryCard) -> URL? {
        guard let data = try? JSONEncoder().encode(card) else { return nil }
        let encoded = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        var comps = URLComponents()
        comps.scheme = scheme
        comps.host = host
        comps.queryItems = [URLQueryItem(name: "d", value: encoded)]
        return comps.url
    }

    static func card(from url: URL) -> GalleryCard? {
        guard url.scheme == scheme, url.host == host else { return nil }
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let raw = comps.queryItems?.first(where: { $0.name == "d" })?.value,
              !raw.isEmpty else { return nil }

        var b64 = raw.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let card = try? JSONDecoder().decode(GalleryCard.self, from: data) else { return nil }
        return card
    }
}

// MARK: - 小组件「换一张」按钮

/// 在小组件上点一下就能换一张随机卡面。
/// 小组件里的 `Button(intent:)` 由**扩展进程**执行，所以这里能直接写扩展自己的 UserDefaults，
/// 再让 TimelineProvider 立刻重载。
struct ShuffleRandomCardIntent: AppIntent {

    static var title: LocalizedStringResource = "换一张随机卡面"
    static var description = IntentDescription("重新随机抽取一张卡面并刷新小组件")
    /// 只更新小组件，不打开 App
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        if let card = try? await RandomCardFetcher.fetch() {
            RandomCardStore.stash(card)
            RandomCardStore.saveLast(card)
        }
        WidgetCenter.shared.reloadTimelines(ofKind: RandomCardWidgetKind)
        return .result()
    }
}

/// 小组件 kind 常量（主 App 想主动刷新时也用得到）
let RandomCardWidgetKind = "VitreaRandomCardWidget"
