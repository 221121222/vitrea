//
//  CardDetailView.swift
//  Vitrea
//
//  卡面详情：大图预览 + 原作者 + 应用 / 编辑。
//  大图未就绪时先用列表里已缓存的缩略图占位，进入详情页不再白屏等待。
//

import SwiftUI

struct CardDetailView: View {
    let card: GalleryCard
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @State private var isPreparing = false
    @State private var prepareError: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                cardPreview

                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(card.displayTitle)
                            .font(.title3.weight(.semibold))

                        // 详情页原本作者只是纯文本，完全点不进去；这里补成和列表一致的作者入口
                        if let handle = card.author?.handle, !handle.isEmpty {
                            NavigationLink {
                                AuthorWorksView(handle: handle, displayName: card.authorName)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "person.fill")
                                        .font(.system(size: 11))
                                    Text(card.authorName)
                                        .font(.subheadline)
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundColor(.accentColor)
                                }
                                .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("查看 \(card.authorName) 的作品")
                        } else {
                            Text(card.authorName)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    GlassHairline()

                    VStack(spacing: 12) {
                        Button {
                            Task { await apply() }
                        } label: {
                            HStack {
                                Image(systemName: "square.and.arrow.down.fill")
                                Text(isPreparing ? "正在准备卡面…" : "应用卡面")
                                    .fontWeight(.semibold)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(.blue, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .foregroundColor(.white)
                        }
                        .buttonStyle(.plain)
                        .disabled(isPreparing)

                        Button { editing = true } label: {
                            HStack {
                                Image(systemName: "pencil.and.scribble")
                                Text("编辑此卡面")
                                    .fontWeight(.semibold)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .foregroundColor(.primary)
                        }
                        .buttonStyle(.plain)
                    }

                    if let prepareError {
                        Text(prepareError)
                            .font(.caption)
                            .foregroundColor(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 4)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .navigationTitle("卡面预览")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .fullScreenCover(item: Binding(
            get: { editing ? card : nil },
            set: { if $0 == nil { editing = false } }
        )) { card in
            EditorView(editing: card, onDismiss: { editing = false })
        }
    }

    // MARK: 卡面大图（先用缩略图秒开）

    private var cardPreview: some View {
        CachedImageView(url: card.largeURL, maxDimension: 1536,
                        placeholderURL: card.thumbURL)
            .aspectRatio(1536.0 / 969.0, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.12), radius: 16, y: 8)
    }

    // MARK: 应用：下载原图 → 写入流程

    private func apply() async {
        isPreparing = true
        prepareError = nil
        defer { isPreparing = false }

        guard let url = card.originalURL else {
            prepareError = "原图地址不可用，请稍后重试"
            return
        }
        do {
            let data = try await CardArtAPI.shared.downloadOriginal(url)
            guard let image = UIImage(data: data) else {
                prepareError = "原图解码失败"
                return
            }
            model.requestWrite(card: card, image: image)
        } catch {
            prepareError = "原图下载失败：\(error.localizedDescription)"
        }
    }
}
