//
//  MainTabView.swift
//  Vitrea
//
//  主框架：底部 Tab 栏（卡面库 · 键盘 · 清理 · 作者）。
//  编辑器不再作为 Tab：避免底部液态玻璃 Tab 栏遮住制作页按钮；
//  制作 / 编辑一律以全屏页（fullScreenCover）打开。
//  连接 / 配对状态只在卡面库页顶栏显示，不再全局常驻。
//
//  另外这里负责「随机卡面」的落地：
//    · 小组件 / 深链 `vitrea://card?d=…` → onOpenURL
//    · 快捷指令「随机卡面」→ RandomCardInbox
//  两者汇到同一个 sheet，展示 CardDetailView。
//

import SwiftUI

enum MainTab: Int, CaseIterable {
    case gallery, keyboard, cleaner, authors

    var title: String {
        switch self {
        case .gallery:  return "卡面库"
        case .keyboard: return "键盘"
        case .cleaner:  return "清理"
        case .authors:  return "作者"
        }
    }

    var icon: String {
        switch self {
        case .gallery:  return "square.on.square"
        case .keyboard: return "keyboard"
        case .cleaner:  return "trash"
        case .authors:  return "person.2"
        }
    }
}

struct MainTabView: View {
    @EnvironmentObject var model: AppModel
    @State private var tab: MainTab = .gallery

    /// 随机卡面：深链与快捷指令都投到这里
    @StateObject private var inbox = RandomCardInbox.shared
    /// 「换一张」时的加载态
    @State private var shuffling = false

    var body: some View {
        TabView(selection: $tab) {
            GalleryView()
                .tabItem { Label("卡面库", systemImage: "square.on.square") }
                .tag(MainTab.gallery)

            PasscodeThemeView()
                .tabItem { Label("键盘", systemImage: "keyboard") }
                .tag(MainTab.keyboard)

            CleanerView()
                .tabItem { Label("清理", systemImage: "trash") }
                .tag(MainTab.cleaner)

            AuthorsView()
                .tabItem { Label("作者", systemImage: "person.2") }
                .tag(MainTab.authors)
        }
        .tint(.accentColor)
        // 小组件点进来：深链里带着整张卡面，所以看到的就是点的那一张
        .onOpenURL { url in
            guard let card = RandomCardLink.card(from: url) else { return }
            inbox.deliver(card)
        }
        .sheet(item: $inbox.pending) { card in
            NavigationStack {
                CardDetailView(card: card)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("关闭") { inbox.pending = nil }
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                Task { await shuffle() }
                            } label: {
                                if shuffling {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Label("换一张", systemImage: "shuffle")
                                }
                            }
                            .disabled(shuffling)
                        }
                    }
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
    }

    /// 再抽一张，直接替换当前 sheet 的内容
    private func shuffle() async {
        guard !shuffling else { return }
        shuffling = true
        defer { shuffling = false }
        if let card = try? await RandomCardFetcher.fetch() {
            inbox.deliver(card)
        }
    }
}
