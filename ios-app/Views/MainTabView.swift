//
//  MainTabView.swift
//  Vitrea
//
//  主框架：底部 Tab 栏（卡面库 · 作者）。
//  编辑器不再作为 Tab：避免底部液态玻璃 Tab 栏遮住制作页按钮；
//  制作 / 编辑一律以全屏页（fullScreenCover）打开，退出用右上角叉。
//  连接 / 配对状态只在卡面库页顶栏显示，不再全局常驻。
//

import SwiftUI

enum MainTab: Int, CaseIterable {
    case gallery, authors

    var title: String {
        switch self {
        case .gallery: return "卡面库"
        case .authors: return "作者"
        }
    }

    var icon: String {
        switch self {
        case .gallery: return "square.on.square"
        case .authors: return "person.2"
        }
    }
}

struct MainTabView: View {
    @EnvironmentObject var model: AppModel
    @State private var tab: MainTab = .gallery

    var body: some View {
        TabView(selection: $tab) {
            GalleryView()
                .tabItem { Label("卡面库", systemImage: "square.on.square") }
                .tag(MainTab.gallery)

            AuthorsView()
                .tabItem { Label("作者", systemImage: "person.2") }
                .tag(MainTab.authors)
        }
        .tint(.accentColor)
    }
}
