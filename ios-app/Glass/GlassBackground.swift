//
//  GlassBackground.swift
//  Vitrea
//
//  全 App 根背景：简洁纯色（浅色纯白 / 深色近黑）。
//  液态玻璃材质由各控件自身的 UIVisualEffectView 承担。
//

import SwiftUI

struct GlassBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            if scheme == .dark {
                Color(uiColor: .systemBackground)
            } else {
                Color(uiColor: .systemBackground)
            }
        }
        .ignoresSafeArea()
    }
}
