//
//  AuthorWorksView.swift
//  Vitrea
//
//  作者作品页：列出某个作者在 cardart.cc 上传的所有卡面。
//  从 GalleryCardItem 点作者名进入。
//

import SwiftUI

struct AuthorWorksView: View {
    let handle: String
    let displayName: String

    @EnvironmentObject var model: AppModel
    @State private var cards: [GalleryCard] = []
    @State private var isLoading = true

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if isLoading {
                    ProgressView()
                        .padding(.top, 60)
                } else if cards.isEmpty {
                    Text("该作者暂无作品")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .padding(.top, 60)
                } else {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(cards) { card in
                            GalleryCardItem(card: card, onEdit: {})
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .navigationTitle(displayName)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let loaded = await model.loadAuthorWorks(handle: handle)
            cards = loaded
            isLoading = false
        }
    }
}
