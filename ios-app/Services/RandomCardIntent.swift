//
//  RandomCardIntent.swift
//  Vitrea
//
//  随机卡面的「App 侧接线」：
//    · `RandomCardInbox`        —— 待展示的随机卡面（深链 / 快捷指令都往这里投）
//    · `OpenRandomCardIntent`   —— 快捷指令 / Siri：「随机卡面」，会打开 App 并跳到该卡
//    · `VitreaShortcuts`        —— 把上面这个 intent 暴露到快捷指令 App 与 Siri
//
//  另外小组件上那个「换一张」按钮用的是 `ShuffleRandomCardIntent`（在 Shared/RandomCard.swift），
//  它只在扩展里跑、不打开 App。
//

import AppIntents
import Foundation
import UIKit

// MARK: - 待展示 / 待应用的随机卡面

@MainActor
final class RandomCardInbox: ObservableObject {

    static let shared = RandomCardInbox()

    /// 非 nil 时 UI 会弹出这张卡面的详情（小组件点卡面 / 深链）
    @Published var pending: GalleryCard?

    /// 快捷指令「随机卡面」专用：已下好原图，进写入面板后自动应用并退回后台。
    /// 用 (card, image) 而非只存 card，是因为原图直接在这里下好，省得面板再下一遍。
    @Published var autoApply: (card: GalleryCard, image: UIImage)?

    private init() {}

    /// 小组件点卡面 / 深链 → 弹详情页
    func deliver(_ card: GalleryCard) {
        pending = card
    }

    /// 快捷指令「随机卡面」→ 自动写入并退回后台
    func enqueueAutoApply(card: GalleryCard, image: UIImage) {
        autoApply = (card, image)
    }
}

// MARK: - 快捷指令：随机卡面

struct OpenRandomCardIntent: AppIntent {

    static var title: LocalizedStringResource = "随机卡面"
    static var description = IntentDescription("从卡面库随机抽一张卡面，下载原图后自动写入并退回后台。")
    /// 需要打开 App 才能下载原图并触发写入流程
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let card = try await RandomCardFetcher.fetch()

        // 把原图先下好，写入面板直接拿来用
        guard let url = card.originalURL else {
            throw IntentError("原图地址不可用，请稍后重试")
        }
        let data = try await CardArtAPI.shared.downloadOriginal(url)
        guard let image = UIImage(data: data) else {
            throw IntentError("原图解码失败")
        }

        RandomCardInbox.shared.enqueueAutoApply(card: card, image: image)
        return .result(value: card.displayTitle)
    }
}

struct IntentError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - 暴露给「快捷指令」与 Siri

struct VitreaShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenRandomCardIntent(),
            phrases: [
                "用 \(.applicationName) 随机一张卡面",
                "\(.applicationName) 抽一张卡面",
                "\(.applicationName) 随机卡面",
            ],
            shortTitle: "随机卡面",
            systemImageName: "wand.and.stars"
        )
    }
}
