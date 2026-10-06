//
//  RandomCardWidget.swift
//  VitreaWidgets
//
//  随机卡面小组件（主屏幕）：
//    · 每次时间线刷新随机换一张卡面
//    · 左下角「换一张」按钮 → 立即重抽（不打开 App）
//    · 点卡面本身 → 通过 vitrea:// 深链打开 App 的卡面详情
//

import AppIntents
import SwiftUI
import UIKit
import WidgetKit

// MARK: - 时间线条目

struct RandomCardEntry: TimelineEntry {
    let date: Date
    let card: GalleryCard?
    let image: UIImage?
}

// MARK: - Provider

struct RandomCardProvider: TimelineProvider {

    /// 首次/占位：先给个灰底，别让系统预览空着
    func placeholder(in context: Context) -> RandomCardEntry {
        RandomCardEntry(date: Date(), card: nil, image: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (RandomCardEntry) -> Void) {
        // 预览/组件库场景不要打网络
        if context.isPreview {
            completion(RandomCardEntry(date: Date(), card: nil, image: nil))
            return
        }
        Task { completion(await Self.loadEntry()) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RandomCardEntry>) -> Void) {
        Task {
            let entry = await Self.loadEntry()
            // 30 分钟自然轮换一张；用户点「换一张」会立刻重载
            let next = Date().addingTimeInterval(30 * 60)
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }

    // MARK: 取一张 + 下好图

    private static func loadEntry() async -> RandomCardEntry {
        // ① 用户点过「换一张」→ 用暂存的那张
        if let stashed = RandomCardStore.takePending() {
            let image = await downloadImage(for: stashed)
            return RandomCardEntry(date: Date(), card: stashed, image: image)
        }

        // ② 正常刷新 → 随机取一张
        if let card = try? await RandomCardFetcher.fetch() {
            RandomCardStore.saveLast(card)
            let image = await downloadImage(for: card)
            return RandomCardEntry(date: Date(), card: card, image: image)
        }

        // ③ 断网 → 用上一次成功的那张兜底，别显示空白
        if let last = RandomCardStore.last() {
            let image = await downloadImage(for: last)
            return RandomCardEntry(date: Date(), card: last, image: image)
        }

        return RandomCardEntry(date: Date(), card: nil, image: nil)
    }

    private static func downloadImage(for card: GalleryCard) async -> UIImage? {
        guard let url = card.largeURL ?? card.thumbURL else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return nil }
        return UIImage(data: data)
    }
}

// MARK: - 视图

struct RandomCardWidgetView: View {

    let entry: RandomCardEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if let card = entry.card {
                cardBody(card)
            } else {
                emptyBody
            }
        }
        .containerBackground(for: .widget) { Color.black }
        // 点卡面 → 打开 App 看这张（深链里带着整张卡面，所以点开的正是这一张）
        .widgetURL(entry.card.flatMap { RandomCardLink.url(for: $0) })
    }

    private func cardBody(_ card: GalleryCard) -> some View {
        ZStack(alignment: .bottomLeading) {
            if let image = entry.image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // 图没下下来（断网/超时）也不要转圈圈一辈子 —— 用卡面主色兜底，
                // 至少是个有质感的色块而不是「假死」的 spinner
                dominantBackdrop(for: card)
            }

            // 底部压一层渐变，保证文字在任何卡面上都读得清
            LinearGradient(colors: [.clear, .black.opacity(0.75)],
                           startPoint: .center, endPoint: .bottom)

            VStack(alignment: .leading, spacing: 4) {
                Text(card.displayTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Text(card.authorName)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    // 小组件里的按钮由扩展进程执行，点了直接换一张、不打开 App
                    Button(intent: ShuffleRandomCardIntent()) {
                        Label("换一张", systemImage: "shuffle")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(.white.opacity(0.22), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(family == .systemSmall ? 10 : 12)
        }
    }

    private var emptyBody: some View {
        VStack(spacing: 8) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.title2)
                .foregroundStyle(.white.opacity(0.7))
            Text("点「换一张」抽卡")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.7))
            Button(intent: ShuffleRandomCardIntent()) {
                Label("换一张", systemImage: "shuffle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.white.opacity(0.22), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // 卡面主色兜底：图没下到时给个有质感的色块，而不是空白/假死 spinner
    private func dominantBackdrop(for card: GalleryCard) -> some View {
        let base = Self.color(from: card.dominantColor) ?? Color(white: 0.18)
        return LinearGradient(colors: [base, base.opacity(0.5)],
                              startPoint: .topLeading, endPoint: .bottomTrailing)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 把站点返回的 dominantColor（#RRGGBB）转成 SwiftUI Color；解析失败返回 nil
    private static func color(from hex: String?) -> Color? {
        guard let hex, hex.count >= 6 else { return nil }
        let s = hex.trimmingCharacters(in: .alphanumerics.inverted)
        let cleaned = s.hasPrefix("#") ? String(s.dropFirst()) : s
        guard cleaned.count == 6 || cleaned.count == 8,
              let v = UInt64(cleaned, radix: 16) else { return nil }
        let r = Double((v >> 16) & 0xFF) / 255
        let g = Double((v >> 8) & 0xFF) / 255
        let b = Double(v & 0xFF) / 255
        return Color(red: r, green: g, blue: b)
    }
}

// MARK: - 小组件声明

struct RandomCardWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: RandomCardWidgetKind, provider: RandomCardProvider()) { entry in
            RandomCardWidgetView(entry: entry)
        }
        .configurationDisplayName("随机卡面")
        .description("随机换一张卡面：点「换一张」立即重抽，点卡面打开 App 看详情。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
