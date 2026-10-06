//
//  CropView.swift
//  Vitrea
//
//  背景照片裁切：提供与卡面实际尺寸（1536 × 969）完全一致的框，
//  用户上传照片后进入此模式，可在框内平移 / 缩放自行决定保留区域，
//  确认后压平为卡面尺寸背景（填满框体）。所有编辑都只发生在这个框内部。
//

import SwiftUI

private let cropCardW: CGFloat = 1536
private let cropCardH: CGFloat = 969

/// 以卡面坐标（1536 × 969）渲染照片：aspectFill 基准 + 用户缩放 / 偏移。
/// 外层 frame 会裁掉超出卡框的部分。
struct CropLayer: View {
    let image: UIImage
    var offset: CGSize
    var scale: CGFloat

    var body: some View {
        let base = max(cropCardW / image.size.width, cropCardH / image.size.height)
        let s = base * scale
        Image(uiImage: image)
            .resizable()
            .frame(width: image.size.width * s, height: image.size.height * s)
            .offset(offset)
            .frame(width: cropCardW, height: cropCardH)
    }
}

/// 裁切交互视图：填满父级给定的卡面比例框，手势完全在框内完成。
struct CropView: View {
    let image: UIImage
    var onConfirm: (UIImage) -> Void
    var onCancel: () -> Void

    @State private var offset: CGSize = .zero
    @State private var scale: CGFloat = 1
    @State private var lastPan: CGSize = .zero
    @State private var lastMag: CGFloat = 1

    var body: some View {
        GeometryReader { geo in
            let k = geo.size.width / cropCardW
            CropLayer(image: image, offset: offset, scale: scale)
                .scaleEffect(k)
                .contentShape(Rectangle())
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
                .gesture(dragGesture(k: k))
                .gesture(zoomGesture)
        }
        .aspectRatio(cropCardW / cropCardH, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.12), radius: 16, y: 8)
        // 确认 / 取消按钮：固定在卡框底部，不随裁切裁掉，也不压到底部导航栏
        .overlay(alignment: .bottom) {
            HStack(spacing: 12) {
                Button {
                    withAnimation { onCancel() }
                } label: {
                    Label("重新选择", systemImage: "arrow.uturn.backward")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundColor(.white)

                Button {
                    confirm()
                } label: {
                    Label("确认裁切", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundColor(.white)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(Capsule().fill(.ultraThinMaterial))
            .overlay(Capsule().stroke(Color.white.opacity(0.25), lineWidth: 1))
            .padding(.bottom, 12)
        }
    }

    // MARK: 手势（坐标按显示比例 k 换算回卡面坐标）

    private func dragGesture(k: CGFloat) -> some Gesture {
        DragGesture()
            .onChanged { v in
                let dx = (v.translation.width - lastPan.width) / k
                let dy = (v.translation.height - lastPan.height) / k
                offset.width += dx
                offset.height += dy
                lastPan = v.translation
                clampOffset()
            }
            .onEnded { _ in lastPan = .zero }
    }

    private var zoomGesture: some Gesture {
        MagnificationGesture()
            .onChanged { m in
                let d = m / lastMag
                scale = min(max(scale * d, 1), 4)
                lastMag = m
                clampOffset()
            }
            .onEnded { _ in lastMag = 1 }
    }

    /// 限制偏移，使照片始终铺满卡框（不露空白）
    private func clampOffset() {
        let base = max(cropCardW / image.size.width, cropCardH / image.size.height)
        let s = base * scale
        let maxX = max(0, (image.size.width * s - cropCardW) / 2)
        let maxY = max(0, (image.size.height * s - cropCardH) / 2)
        offset.width = min(max(offset.width, -maxX), maxX)
        offset.height = min(max(offset.height, -maxY), maxY)
    }

    // MARK: 确认 → 压平为卡面尺寸背景（用 Core Graphics 精确还原框内排布）

    private func confirm() {
        let base = max(cropCardW / image.size.width, cropCardH / image.size.height)
        let s = base * scale
        let out = UIGraphicsImageRenderer(
            size: CGSize(width: cropCardW, height: cropCardH)
        ).image { ctx in
            let c = ctx.cgContext
            c.translateBy(x: cropCardW / 2 + offset.width,
                          y: cropCardH / 2 + offset.height)
            c.scaleBy(x: s, y: s)
            image.draw(in: CGRect(x: -image.size.width / 2,
                                  y: -image.size.height / 2,
                                  width: image.size.width,
                                  height: image.size.height))
        }
        onConfirm(out)
    }
}
