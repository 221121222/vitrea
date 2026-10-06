//
//  GalleryView.swift
//  Vitrea
//
//  卡面库：在线浏览 cardart.cc 卡面，按分类筛选，搜索。
//  顶栏左侧是连接 / 配对状态，紧邻其右是「卡面库」标题（只在卡面库页显示）。
//

import SwiftUI

struct GalleryView: View {
    @EnvironmentObject var model: AppModel

    /// 编辑器入口：新建 / 编辑，统一由**一个** fullScreenCover 承载。
    ///
    /// 这里踩过一个坑：原先在同一个视图上叠了两个 fullScreenCover
    /// （`item: $editingCard` + `isPresented: $showNewCard`），
    /// 而 SwiftUI 一个视图只能稳定托管一个 presentation ——
    /// 结果「制作卡面」那个全屏页虽然能打开，但**关闭叉点了没反应**
    /// （dismiss 绑定的那个 binding 已经被另一个 cover 抢掉了）。
    /// 合并成一个 item 驱动的 cover 就好了。
    private enum EditorRoute: Identifiable {
        case create
        case edit(GalleryCard)

        var id: String {
            switch self {
            case .create:         return "create"
            case .edit(let card): return "edit-\(card.id)"
            }
        }
    }

    @State private var editorRoute: EditorRoute?
    /// nil = 全部；否则为 /explore 的筛选串（issuerKind=… 或 type=payment&network=…）
    @State private var selectedFilter: String? = nil
    @State private var showStatusMenu = false

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    /// 卡面库按 cardart.cc 真实分类归类：交通卡 / 身份证 / 银行卡。
    /// 筛选串直接对接 cardart.cc/explore 的 type 参数（issuerKind 服务端实际是 no-op）。
    private let browseKinds: [(name: String, filter: String)] = [
        ("交通卡", "type=transit"),
        ("身份证", "type=id"),
        ("银行卡", "type=payment"),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if !model.featuredCards.isEmpty {
                        featuredSection
                    }
                    searchBar
                    categoryChips

                    if model.searchMode {
                        resultsGrid
                    } else if model.isLoadingFeed, model.galleryCards.isEmpty {
                        loadingGrid
                    } else if let error = model.feedError, model.galleryCards.isEmpty {
                        errorView(error)
                    } else {
                        feedGrid
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .refreshable {
                if model.searchMode {
                    // 分类浏览时下拉刷新要重新拉同一类，不能去跑空关键词搜索
                    if model.exploreMode, let filter = model.exploreFilter {
                        model.loadExplore(filter: filter)
                    } else {
                        model.performSearch()
                    }
                } else {
                    await model.refreshFeed()
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    statusPill
                }
                ToolbarItem(placement: .principal) {
                    Text("卡面库")
                        .font(.headline.weight(.semibold))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { editorRoute = .create } label: {
                        // 图标 + 文字：单图标不够显眼，加上「制作」二字并给一个实心底色
                        HStack(spacing: 4) {
                            Image(systemName: "wand.and.stars")
                            Text("制作")
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.accentColor, in: Capsule())
                    }
                    .accessibilityLabel("制作卡面")
                }
            }
        }
        .fullScreenCover(item: $editorRoute) { route in
            switch route {
            case .create:
                EditorView(editing: nil, onDismiss: { editorRoute = nil })
            case .edit(let card):
                EditorView(editing: card, onDismiss: { editorRoute = nil })
            }
        }
        .confirmationDialog("连接设置", isPresented: $showStatusMenu, titleVisibility: .visible) {
            Button("重新检查连接") { model.relock(to: .vpn) }
            Button("重新配对") { model.relock(to: .pairing) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("若卡面写入异常，可回到闸门重新检查隧道或配对。")
        }
        .onAppear {
            model.loadFeatured()
            if !model.searchMode, model.galleryCards.isEmpty {
                model.loadInitialFeed()
            }
        }
    }

    // MARK: 顶栏状态（仅卡面库页显示）

    private var statusPill: some View {
        Button {
            model.refreshStatus()
            showStatusMenu = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: model.tunnelUp ? "wifi" : "wifi.slash")
                    .foregroundColor(model.tunnelUp ? .green : .orange)
                Text(model.tunnelUp ? "已连接" : "未连接")
                Rectangle()
                    .fill(Color.primary.opacity(0.15))
                    .frame(width: 1, height: 10)
                Image(systemName: model.paired ? "checkmark.seal.fill" : "exclamationmark.triangle")
                    .foregroundColor(model.paired ? .green : .orange)
                Text(model.paired ? "已配对" : "未配对")
            }
            .font(.subheadline.weight(.medium))
            .foregroundColor(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: 精选板块

    private var featuredSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .foregroundColor(.accentColor)
                Text("精选")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.primary)
                Spacer()
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(model.featuredCards) { card in
                        NavigationLink {
                            CardDetailView(card: card)
                        } label: {
                            CachedImageView(url: card.thumbURL, maxDimension: 480)
                                .aspectRatio(1536.0 / 969.0, contentMode: .fill)
                                .frame(width: 200, height: 126)
                                .background(Color(.secondarySystemBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 2)
            }
        }
    }

    // MARK: 搜索栏

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundColor(.secondary)
            TextField("搜索卡面 / 发卡机构 / 作者", text: $model.searchText)
                .font(.subheadline)
                .submitLabel(.search)
                .onSubmit { selectedFilter = nil; model.performSearch() }
            // 只在**关键词搜索**时给清除按钮。
            // 点「交通卡 / 身份证 / 银行卡」只是切分类浏览，搜索框右侧不该冒出这个叉 ——
            // 取消分类浏览请点最左边的「全部」。
            if model.searchMode && !model.exploreMode {
                Button { selectedFilter = nil; model.exitSearch() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.body)
                        .foregroundColor(.secondary)
                }
                // .plain 才能压住默认按钮样式对图标的强调色着色，保持灰色
                .buttonStyle(.plain)
                .accessibilityLabel("退出搜索")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: 分类筛选

    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("全部", icon: "square.grid.2x2.fill", active: selectedFilter == nil) {
                    selectedFilter = nil
                    model.exitSearch()
                }
                ForEach(browseKinds, id: \.filter) { kind in
                    chip(kind.name, icon: "creditcard.fill", active: selectedFilter == kind.filter) {
                        selectedFilter = kind.filter
                        model.searchText = ""
                        model.loadExplore(filter: kind.filter)
                    }
                }
            }
        }
    }

    private func chip(_ title: String, icon: String, active: Bool,
                      gold: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                Text(title).font(.subheadline.weight(.medium))
            }
            .foregroundColor(chipForeground(active: active, gold: gold))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(chipBackground(active: active, gold: gold), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func chipForeground(active: Bool, gold: Bool) -> Color {
        guard gold else { return active ? .white : .primary }
        // 金色突出显示：未选中用暗金文字，选中用金底深字
        return active ? Color(hex: "#3B2A05") : Color(hex: "#B8860B")
    }

    private func chipBackground(active: Bool, gold: Bool) -> AnyShapeStyle {
        guard gold else {
            return AnyShapeStyle(active ? Color.accentColor : Color.primary.opacity(0.08))
        }
        return AnyShapeStyle(active ? Color(hex: "#F2C14E") : Color(hex: "#F2C14E").opacity(0.16))
    }

    // MARK: 网格

    private var feedGrid: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(model.galleryCards) { card in
                cardCell(card) {
                    if card.id == model.galleryCards.last?.id { model.loadMoreFeed() }
                }
            }
            if model.isLoadingMore { placeholderCells(4) }
        }
    }

    private func cardGrid(_ cards: [GalleryCard]) -> some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(cards) { card in
                cardCell(card) { }
            }
        }
    }

    private func cardCell(_ card: GalleryCard, onLast: @escaping () -> Void) -> some View {
        GalleryCardItem(card: card, onEdit: { editorRoute = .edit(card) })
            .onAppear(perform: onLast)
    }

    private var resultsGrid: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            if model.isSearching {
                placeholderCells(4)
            } else if model.searchResults.isEmpty {
                Text("没有找到相关卡面，换个关键词试试")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .padding(.top, 40)
            } else {
                ForEach(model.searchResults) { card in
                    cardCell(card) { }
                }
            }
        }
    }

    private var loadingGrid: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            placeholderCells(6)
        }
    }

    private func placeholderCells(_ count: Int) -> some View {
        ForEach(0..<count, id: \.self) { _ in
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.primary.opacity(0.06))
                .aspectRatio(1536.0 / 969.0, contentMode: .fit)
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark").font(.largeTitle).foregroundColor(.secondary)
            Text(message).font(.footnote).foregroundColor(.secondary)
            Button { model.loadInitialFeed() } label: {
                Label("重新加载", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
        }
        .padding(.top, 60)
    }
}

// MARK: - 卡面网格项

struct GalleryCardItem: View {
    let card: GalleryCard
    let onEdit: () -> Void
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            NavigationLink {
                CardDetailView(card: card)
            } label: {
                CachedImageView(url: card.thumbURL, maxDimension: 640)
                    .aspectRatio(1536.0 / 969.0, contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .background(Color(.secondarySystemBackground))   // 防蓝椭圆透出
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                    )
            }
            .buttonStyle(.plain)

            Text(card.displayTitle)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .foregroundColor(.primary)

            if let handle = card.author?.handle, !handle.isEmpty {
                NavigationLink {
                    AuthorWorksView(handle: handle, displayName: card.authorName)
                } label: {
                    // 作者是可点进去的，但光看文字看不出来 —— 后面补一个小小的向右箭头
                    HStack(spacing: 3) {
                        Image(systemName: "person.fill").font(.system(size: 9))
                        Text(card.authorName)
                            .font(.caption2)
                            .lineLimit(1)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundColor(.accentColor)
                    }
                    .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("查看 \(card.authorName) 的作品")
            } else {
                Text(card.authorName)
                    .font(.caption2)
                    .lineLimit(1)
                    .foregroundColor(.secondary)
            }
        }
        .contextMenu {
            Section {
                Label("原作者：\(card.authorName)", systemImage: "person.fill")
            }
            Button {
                Task { await quickApply(card) }
            } label: { Label("应用卡面", systemImage: "square.and.arrow.down") }
            Button { onEdit() } label: { Label("编辑卡面", systemImage: "pencil") }
        }
    }

    private func quickApply(_ card: GalleryCard) async {
        guard let url = card.originalURL else { return }
        do {
            let data = try await CardArtAPI.shared.downloadOriginal(url)
            if let img = UIImage(data: data) {
                model.requestWrite(card: card, image: img)
            }
        } catch { }
    }
}
