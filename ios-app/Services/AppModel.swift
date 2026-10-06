//
//  AppModel.swift
//  Vitrea
//
//  全局状态：闸门 / 卡面库 / 精选 / 设备钱包卡 / 写入上下文。
//

import SwiftUI
import UIKit

enum GateStage: Int {
    case vpn = 1, pairing = 2, done = 3
}

/// 触发写入流程的上下文（由卡面库详情或编辑器产出）
struct WriteContext: Identifiable {
    let id = UUID()
    let image: UIImage
    let sourceTitle: String
    let sourceAuthor: String?      // 原作者署名
    let targets: [WalletCard]?     // nil 时在写入面板里选目标
}

@MainActor
final class AppModel: ObservableObject {

    // MARK: 闸门

    /// 已走完且状态正常才为 true。持久化；启动时重新验活，断了就重新拦。
    @Published var gateUnlocked: Bool = false
    @Published var gateStage: GateStage = .vpn
    @Published var tunnelUp: Bool = false
    @Published var paired: Bool = false

    private let unlockedKey = "gate.unlocked"
    private let stageKey = "gate.stage"

    // MARK: 卡面库

    @Published var galleryCards: [GalleryCard] = []
    @Published var feedSeed: String? = nil
    @Published var isLoadingFeed = false
    @Published var isLoadingMore = false
    @Published var feedError: String?
    @Published var endOfFeed = false

    @Published var searchText = ""
    @Published var searchResults: [GalleryCard] = []
    @Published var isSearching = false
    @Published var searchMode = false

    // MARK: 精选

    @Published var featuredCards: [GalleryCard] = []
    private var featuredLoaded = false

    // MARK: 设备钱包卡 / 卡识别

    @Published var walletCards: [WalletCard] = []
    @Published var isScanning = false
    @Published var scanStatus = ""

    // MARK: 写入

    @Published var writeContext: WriteContext?
    @Published var writeLogs: [WriteLogEntry] = WriteEngine.shared.logs

    // MARK: 作者页

    @Published var showAuthors = false

    init() {
        gateUnlocked = UserDefaults.standard.bool(forKey: unlockedKey)
        gateStage = GateStage(rawValue: UserDefaults.standard.integer(forKey: stageKey)) ?? .vpn
    }

    // MARK: 启动验活

    /// 已解锁过的用户：只验状态，正常直接放行；隧道断/配对失效则回到对应步骤拦截。
    func startupProbe() {
        refreshStatus()
        guard gateUnlocked else {
            gateStage = tunnelUp ? .pairing : .vpn
            return
        }
        if tunnelUp && paired {
            gateStage = .done
        } else {
            gateUnlocked = false
            gateStage = tunnelUp ? .pairing : .vpn
            persistGate()
        }
    }

    func refreshStatus() {
        tunnelUp = WriteEngine.shared.isTunnelUp
        paired = WriteEngine.shared.isPaired
    }

    func advanceGate(to stage: GateStage) {
        withAnimation(.spring(response: GlassTheme.morphResponse, dampingFraction: GlassTheme.morphDamping)) {
            gateStage = stage
        }
        UserDefaults.standard.set(stage.rawValue, forKey: stageKey)
    }

    func completeGate() {
        refreshStatus()
        guard tunnelUp, paired else { return }
        withAnimation(.spring(response: GlassTheme.morphResponse, dampingFraction: GlassTheme.morphDamping)) {
            gateStage = .done
            gateUnlocked = true
        }
        persistGate()
    }

    /// 主页手动「重新检查 / 重新配对」：清状态回闸门
    func relock(to stage: GateStage) {
        withAnimation(.spring(response: GlassTheme.morphResponse, dampingFraction: GlassTheme.morphDamping)) {
            gateUnlocked = false
            gateStage = stage
        }
        UserDefaults.standard.set(false, forKey: unlockedKey)
        UserDefaults.standard.set(stage.rawValue, forKey: stageKey)
    }

    private func persistGate() {
        UserDefaults.standard.set(gateUnlocked, forKey: unlockedKey)
        UserDefaults.standard.set(gateStage.rawValue, forKey: stageKey)
    }

    // MARK: 卡面库加载

    func loadInitialFeed() {
        guard !isLoadingFeed else { return }
        isLoadingFeed = true
        feedError = nil

        Task {
            do {
                let resp = try await CardArtAPI.shared.wander(seed: nil)
                self.feedSeed = resp.seed
                self.galleryCards = resp.cards
                self.endOfFeed = resp.cards.isEmpty
                self.prefetchThumbs(resp.cards)
            } catch {
                self.feedError = error.localizedDescription
            }
            self.isLoadingFeed = false
        }
    }

    func loadMoreFeed() {
        guard !isLoadingMore, !endOfFeed, let seed = feedSeed else { return }
        isLoadingMore = true

        Task {
            do {
                let resp = try await CardArtAPI.shared.wander(seed: seed)
                self.feedSeed = resp.seed
                let existing = Set(self.galleryCards.map(\.id))
                let fresh = resp.cards.filter { !existing.contains($0.id) }
                self.galleryCards.append(contentsOf: fresh)
                self.endOfFeed = fresh.isEmpty
                self.prefetchThumbs(fresh)
            } catch {
                // 翻页失败保留旧 seed，滑回来可重试
            }
            self.isLoadingMore = false
        }
    }

    func refreshFeed() async {
        do {
            let resp = try await CardArtAPI.shared.wander(seed: nil)
            self.feedSeed = resp.seed
            withAnimation { self.galleryCards = resp.cards }
            self.endOfFeed = resp.cards.isEmpty
            self.feedError = nil
            self.prefetchThumbs(resp.cards)
        } catch {
            self.feedError = error.localizedDescription
        }
    }

    /// 提前把缩略图拉进缓存，滑到即显示、详情页返回也不闪空
    private func prefetchThumbs(_ cards: [GalleryCard]) {
        let urls = cards.prefix(16).compactMap { $0.thumbURL }
        guard !urls.isEmpty else { return }
        ImageCacheStore.shared.prefetch(urls, maxDimension: 640)
    }

    // MARK: 精选

    func loadFeatured() {
        guard !featuredLoaded else { return }
        featuredLoaded = true
        Task {
            let cards = (try? await CardArtAPI.shared.featuredCards())
                ?? FeaturedCards.makeCards()
            await MainActor.run {
                self.featuredCards = cards
                ImageCacheStore.shared.prefetch(cards.compactMap { $0.thumbURL }, maxDimension: 640)
            }
        }
    }

    func refreshFeatured() {
        Task {
            let cards = (try? await CardArtAPI.shared.featuredCards())
                ?? FeaturedCards.makeCards()
            await MainActor.run {
                withAnimation { self.featuredCards = cards }
                ImageCacheStore.shared.prefetch(cards.compactMap { $0.thumbURL }, maxDimension: 640)
            }
        }
    }

    // MARK: 作者作品

    func loadAuthorWorks(handle: String) async -> [GalleryCard] {
        do {
            let cards = try await CardArtAPI.shared.authorWorks(handle: handle)
            ImageCacheStore.shared.prefetch(cards.compactMap { $0.thumbURL }, maxDimension: 640)
            return cards
        } catch {
            return []
        }
    }

    // MARK: 搜索

    func performSearch() {
        let keyword = searchText.trimmingCharacters(in: .whitespaces)
        guard !keyword.isEmpty else { return }
        isSearching = true
        searchMode = true

        Task {
            do {
                let results = try await CardArtAPI.shared.search(keyword)
                self.searchResults = results
                self.prefetchThumbs(results)
            } catch {
                self.searchResults = []
            }
            self.isSearching = false
        }
    }

    func exitSearch() {
        searchMode = false
        searchText = ""
        searchResults = []
    }

    /// 按站点真实浏览分类（卡组织 / 发卡机构）拉取卡面，结果复用搜索网格展示。
    func loadExplore(filter: String) {
        isSearching = true
        searchMode = true
        Task {
            do {
                let results = try await CardArtAPI.shared.exploreCards(filter: filter)
                self.searchResults = results
                self.prefetchThumbs(results)
            } catch {
                self.searchResults = []
            }
            self.isSearching = false
        }
    }

    // MARK: 卡识别

    func startScanning() {
        guard !isScanning else { return }
        isScanning = true
        WriteEngine.shared.startScanner(
            onCard: { [weak self] id, network in
                self?.registerWalletCard(id: id, network: network)
            },
            onStatus: { [weak self] status in
                self?.scanStatus = status
            }
        )
    }

    func stopScanning() {
        WriteEngine.shared.stopScanner()
        isScanning = false
        scanStatus = ""
    }

    private func registerWalletCard(id: String, network: String?) {
        if let idx = walletCards.firstIndex(where: { $0.id == id }) {
            if walletCards[idx].paymentNetwork == nil, let network {
                walletCards[idx].paymentNetwork = network
            }
            return
        }
        walletCards.append(WalletCard(id: id, displayName: nil, paymentNetwork: network))
        scanStatus = "识别到卡片：\(id.prefix(12))…"
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
    }

    func removeWalletCard(at offsets: IndexSet) {
        walletCards.remove(atOffsets: offsets)
    }

    func selectAllWalletCards(_ selected: Bool) {
        walletCards = walletCards.map {
            var c = $0; c.isSelected = selected; return c
        }
    }

    // MARK: 发起写入

    func requestWrite(card: GalleryCard, image: UIImage) {
        writeContext = WriteContext(
            image: image,
            sourceTitle: card.displayTitle,
            sourceAuthor: card.authorName,
            targets: nil
        )
    }

    func requestWrite(editorImage: UIImage, title: String) {
        writeContext = WriteContext(
            image: editorImage,
            sourceTitle: title,
            sourceAuthor: nil,    // 自制卡面
            targets: nil
        )
    }

    func refreshLogs() {
        writeLogs = WriteEngine.shared.logs
    }
}
