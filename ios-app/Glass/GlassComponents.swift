//
//  GlassComponents.swift
//  Vitrea
//
//  液态玻璃控件库 —— 基于苹果官方 UIVisualEffectView 材质。
//  四层结构：① 真实材质模糊 ② 顶部内高光 ③ 1px 分隔描边 ④ 底部投影。
//  文字使用 .primary / .secondary，保证在浅 / 深背景上都清晰可读。
//

import SwiftUI
import UIKit

// MARK: - 真实材质模糊视图

struct GlassBlurView: UIViewRepresentable {
    let tier: GlassTier

    func makeUIView(context: Context) -> UIVisualEffectView {
        let view = UIVisualEffectView(effect: nil)
        view.backgroundColor = .clear
        view.contentView.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        applyEffect(to: view)
        return view
    }

    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {
        applyEffect(to: uiView)
    }

    private func applyEffect(to view: UIVisualEffectView) {
        // 苹果官方材质：thin → ultraThin / regular → material / thick → thick
        view.effect = UIBlurEffect(style: tier.materialStyle)
    }
}

// MARK: - 玻璃容器

struct GlassContainer<Content: View>: View {
    let tier: GlassTier
    var cornerRadius: CGFloat? = nil
    var showsShadow: Bool = true
    @ViewBuilder var content: () -> Content

    @Environment(\.colorScheme) private var scheme

    private var radius: CGFloat { cornerRadius ?? tier.cornerRadius }

    var body: some View {
        content()
            .background(
                ZStack {
                    // ① 真实材质（模糊 + 系统 vibrancy）
                    GlassBlurView(tier: tier)
                    // ② 顶部内高光
                    LinearGradient(
                        colors: [
                            Color.white.opacity(scheme == .dark ? 0.10 : 0.55),
                            Color.white.opacity(0)
                        ],
                        startPoint: .top,
                        endPoint: UnitPoint(x: 0.5, y: 0.5)
                    )
                    .allowsHitTesting(false)
                }
            )
            // ③ 1px 分隔描边
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(scheme == .dark ? 0.18 : 0.10), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            // ④ 底部投影
            .shadow(
                color: Color.black.opacity(scheme == .dark ? 0.40 : 0.10),
                radius: showsShadow ? tier.shadowRadius : 0,
                x: 0,
                y: showsShadow ? tier.shadowY : 0
            )
    }
}

// MARK: - 玻璃卡片（列表项）

struct GlassCard<Content: View>: View {
    var padding: CGFloat = 16
    var cornerRadius: CGFloat? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        GlassContainer(tier: .thin, cornerRadius: cornerRadius) {
            content().padding(padding)
        }
    }
}

// MARK: - 玻璃按钮

struct GlassButton: View {
    enum Style {
        case primary, secondary, ghost

        var tier: GlassTier {
            switch self {
            case .primary:   return .regular
            case .secondary: return .thin
            case .ghost:     return .thin
            }
        }
    }

    let title: String
    var systemImage: String? = nil
    var style: Style = .primary
    var fullWidth: Bool = false
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
                    .fontWeight(.semibold)
            }
            .foregroundColor(foreground)
            .padding(.horizontal, 20)
            .padding(.vertical, 13)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .background(background)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(enabled ? 0 : 0.12), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    /// 禁用时不要把品牌色整体降透明度（那会变成一坨"灰按钮"），
    /// 而是换成中性底 + 次要文字，一眼能看出是「还没满足条件」而不是「坏了」。
    private var foreground: Color {
        if !enabled { return .secondary }
        return style == .primary ? .white : .primary
    }

    @ViewBuilder
    private var background: some View {
        if style == .primary {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(enabled ? Color.accentColor : Color.primary.opacity(0.08))
        } else {
            GlassContainer(tier: style.tier, cornerRadius: 14, showsShadow: false) {
                Color.clear
            }
            .opacity(enabled ? 1 : 0.6)
        }
    }
}

// MARK: - 玻璃圆形头像

struct GlassAvatar: View {
    let image: Image
    var size: CGFloat = 72

    var body: some View {
        image
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
            .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
    }
}

// MARK: - 玻璃分隔线

struct GlassHairline: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 0.5)
    }
}
