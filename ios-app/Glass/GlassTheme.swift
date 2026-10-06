//
//  GlassTheme.swift
//  Vitrea
//
//  液态玻璃设计系统 —— 三档层级令牌 + 转场。
//  thin（列表项）/ regular（按钮 / 卡片）/ thick（Tab 栏 / 模态 / 封面）。
//

import SwiftUI
import UIKit

enum GlassTier {
    case thin, regular, thick

    /// 圆角
    var cornerRadius: CGFloat {
        switch self {
        case .thin:     return 16
        case .regular:  return 20
        case .thick:    return 28
        }
    }

    /// 苹果官方材质
    var materialStyle: UIBlurEffect.Style {
        switch self {
        case .thin:     return .systemUltraThinMaterial
        case .regular:  return .systemMaterial
        case .thick:    return .systemThickMaterial
        }
    }

    /// 底部投影
    var shadowRadius: CGFloat {
        switch self {
        case .thin:     return 10
        case .regular:  return 16
        case .thick:    return 24
        }
    }

    var shadowY: CGFloat {
        switch self {
        case .thin:     return 5
        case .regular:  return 8
        case .thick:    return 12
        }
    }
}

// MARK: - 主题

enum GlassTheme {
    /// 玻璃形变转场时长
    static let morphResponse: Double = 0.42
    static let morphDamping: Double = 0.82

    /// 玻璃形变转场
    /// 注意：不可在此转场中使用 .blur —— SwiftUI 转场结束后 blur 滤镜可能残留，
    /// 造成整屏模糊 bug（全屏模糊即源于此）。仅用透明度 + 缩放表达形变。
    static let morphTransition: AnyTransition = .asymmetric(
        insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .top)),
        removal: .opacity.combined(with: .scale(scale: 0.96, anchor: .top))
    )
}

// MARK: - 玻璃形变 Modifier（保留供非转场动画使用，禁用 blur）

struct GlassMorphModifier: ViewModifier {
    let progress: Double
    let isOut: Bool

    func body(content: Content) -> some View {
        let p = isOut ? (1 - progress) : progress
        let scale = 0.92 + 0.08 * p
        let dy = (1 - p) * 20
        return content
            .scaleEffect(scale, anchor: .top)
            .offset(y: dy)
            .opacity(0.4 + 0.6 * p)
    }
}
