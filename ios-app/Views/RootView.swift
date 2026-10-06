//
//  RootView.swift
//  Vitrea
//
//  根容器：纯色背景 + 闸门 / 主界面切换 + 写入面板。
//  作者页仅通过底栏 Tab 进入，不再在右上角常驻。
//

import SwiftUI

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            GlassBackground()

            if !OSGate.isAllowed {
                OSGateView()
            } else if model.gateUnlocked {
                MainTabView()
                    .transition(GlassTheme.morphTransition)
            } else {
                GateView()
                    // .blurReplace 同样会在转场后残留 blur（全屏模糊 bug 来源之一），改用纯透明度
                    .transition(.opacity)
            }
        }
        .animation(.spring(response: GlassTheme.morphResponse,
                          dampingFraction: GlassTheme.morphDamping),
                   value: model.gateUnlocked)
        // 写入面板
        .sheet(item: $model.writeContext) { ctx in
            WriteSheet(context: ctx)
                .presentationBackground(.clear)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.refreshStatus() }
        }
    }
}

// MARK: - Credits 图片加载（folder reference 资源）

struct CreditsImage: View {
    let name: String
    var body: some View {
        if let path = Bundle.main.path(forResource: "credits/\(name)", ofType: "jpg"),
           let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let img = UIImage(data: data) {
            Image(uiImage: img).resizable().scaledToFill()
        } else {
            Color.gray
        }
    }
}
