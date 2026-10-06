//
//  EditorView.swift
//  Vitrea
//
//  原生卡面编辑器：
//  画布 1536×969 → 相册背景 → 在线素材 + 文字图层 → 所见即所得导出 → 一键写入。
//

import SwiftUI
import PhotosUI
import UIKit

// MARK: - 清单模型

struct StickerItem: Codable {
    let category: String
    let name: String
    let file: String
    /// 素材清单里记录的高宽比（h/w），在线图未到之前就能按真实比例摆放
    let aspect: Double?

    enum CodingKeys: String, CodingKey { case category, name, file, aspect }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        category = try c.decode(String.self, forKey: .category)
        name = try c.decode(String.self, forKey: .name)
        file = try c.decode(String.self, forKey: .file)
        aspect = try c.decodeIfPresent(Double.self, forKey: .aspect)
    }

    init(category: String, name: String, file: String, aspect: Double?) {
        self.category = category
        self.name = name
        self.file = file
        self.aspect = aspect
    }
}

enum BgKind: Equatable {
    case empty
    case photo
}

enum ElementKind: Equatable {
    case sticker(file: String, aspect: CGFloat)
    case text(content: String)
}

struct CanvasElement: Identifiable {
    let id = UUID()
    var kind: ElementKind
    var center: CGPoint = CGPoint(x: 0.5, y: 0.5)  // 画布单位坐标
    var baseWidth: CGFloat = 0.30                    // 相对画布宽度
    var scale: CGFloat = 1
    var rotation: Double = 0
    var fontSize: CGFloat = 0.055                    // 相对画布高度
    var color: String = "#FFFFFF"
    var weight: Int = 2                              // 0...3
}

// MARK: - 编辑器主视图

struct EditorView: View {
    var editing: GalleryCard?
    /// 退出回调：由调用方提供（关掉 fullScreenCover）。不提供时回退到系统 dismiss。
    var onDismiss: (() -> Void)? = nil

    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    enum ToolPanel { case background, sticker, text }

    @State private var panel: ToolPanel = .background
    @State private var bgImage: UIImage?
    @State private var elements: [CanvasElement] = []
    @State private var selectedID: UUID?
    @State private var isLoadingOriginal = false

    @State private var stickers: [StickerItem] = []
    @State private var stickerCategory = "networks"
    @State private var stickerFilter = ""
    @State private var stickerCache: [String: UIImage] = [:]

    @State private var photoItem: PhotosPickerItem?

    // 裁切流程状态：选完照片先进入框内裁切，确认后才成为背景
    @State private var isCropping = false
    @State private var cropImage: UIImage?

    @State private var textContent = "CARD"
    @State private var textColor = "#FFFFFF"
    @State private var textSize = 0.055
    @State private var textWeight = 2

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 10) {
                topBar
                canvasArea
                inspector
                Spacer(minLength: 0)
                toolPanel
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)
            // 始终为底部安全区（Home 指示条 / Tab 栏）留出余量，避免工具面板文字与之重合
            .padding(.bottom, 20 + geo.safeAreaInsets.bottom)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let img = ImageEngine.safeImageFromData(data, maxDimension: 2048) {
                        // 进入框内裁切模式，确认后才写入背景
                        cropImage = img
                        isCropping = true
                    }
                }
            }
            .task {
                loadManifests()
                if let editing, bgImage == nil, !isLoadingOriginal {
                    isLoadingOriginal = true
                    if let url = editing.originalURL,
                       let data = try? await CardArtAPI.shared.downloadOriginal(url),
                       let img = ImageEngine.safeImageFromData(data, maxDimension: 2048) {
                        bgImage = img
                    }
                    isLoadingOriginal = false
                }
            }
        }
        .background(
            LinearGradient(
                colors: [Color(uiColor: .systemGroupedBackground), Color(uiColor: .systemBackground)],
                startPoint: .top, endPoint: .bottom
            ).ignoresSafeArea()
        )
    }

    // MARK: 顶栏

    private var topBar: some View {
        HStack(spacing: 10) {
            if onDismiss != nil {
                Button {
                    // 直接用调用方回调关闭全屏页，避免 fullScreenCover 里 dismiss() 失效
                    if let onDismiss { onDismiss() } else { dismiss() }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundColor(.secondary)
                        // 热区放大到约 40pt：之前只有图标本身那么大，不太好点中
                        .padding(9)
                        .contentShape(Rectangle())
                }
                // 默认按钮样式会把图标染成强调色，这里压成原样
                .buttonStyle(.plain)
                .accessibilityLabel("关闭")
            }
            Text(editing != nil ? "编辑卡面" : "制作卡面")
                .font(.headline)
            Spacer()
            GlassButton(title: "写入", systemImage: "bolt.fill", style: .primary, enabled: bgImage != nil) {
                exportAndWrite()
            }
        }
    }

    // MARK: 画布（与卡面实际尺寸 1536×969 完全一致的框）

    private var canvasArea: some View {
        ZStack {
            if isCropping, let img = cropImage {
                // 裁切模式：在卡面框内自行选择保留区域
                CropView(image: img,
                         onConfirm: { cropped in
                            bgImage = cropped
                            isCropping = false
                         },
                         onCancel: {
                            isCropping = false
                         })
            } else {
                GeometryReader { g in
                    // 关键：按可用空间把画布缩放到「能放下的最大卡面尺寸」再渲染，
                    // 不能再用固定的 1536×969（那会把整页撑爆、把工具面板挤出屏幕）。
                    let size = cardFitSize(in: g.size)
                    ZStack {
                        CanvasArt(width: size.width, height: size.height,
                                  bgImage: bgImage,
                                  stickerCache: stickerCache,
                                  elements: elements, selectedID: selectedID,
                                  onSelect: { selectedID = $0 },
                                  onMove: { id, point in update(id) { $0.center = point } },
                                  onPinch: { id, scale in
                                      update(id) { $0.scale = max(0.3, min(5, $0.scale * scale)) }
                                  })
                        .frame(width: size.width, height: size.height)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18)
                                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.12), radius: 16, y: 8)

                        if bgImage == nil {
                            VStack(spacing: 6) {
                                Image(systemName: "photo.on.rectangle.angled")
                                    .font(.title2)
                                Text("先在下方「背景」里从相册选一张图片")
                                    .font(.caption)
                            }
                            .foregroundColor(.secondary)
                        }
                    }
                    .frame(width: size.width, height: size.height)
                    .frame(width: g.size.width, height: g.size.height)   // 在可用区内居中
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 在给定区域内，求 1536:969 卡面能放下的最大尺寸（等比缩放）
    private func cardFitSize(in available: CGSize) -> CGSize {
        let ratio = 1536.0 / 969.0
        guard available.width > 1, available.height > 1 else {
            return CGSize(width: 320, height: 320 / ratio)
        }
        let byWidth = CGSize(width: available.width, height: available.width / ratio)
        if byWidth.height <= available.height { return byWidth }
        return CGSize(width: available.height * ratio, height: available.height)
    }

    private func update(_ id: UUID, _ work: (inout CanvasElement) -> Void) {
        guard let idx = elements.firstIndex(where: { $0.id == id }) else { return }
        work(&elements[idx])
    }

    private func removeBackground() {
        bgImage = nil
    }

    /// 重新进入框内裁切（基于当前已裁好的背景再调整）
    private func reCrop() {
        guard let bgImage else { return }
        cropImage = bgImage
        isCropping = true
    }

    // MARK: 选中元素检查器

    @ViewBuilder
    private var inspector: some View {
        if let id = selectedID, let idx = elements.firstIndex(where: { $0.id == id }) {
            GlassContainer(tier: .regular, cornerRadius: 18) {
                VStack(spacing: 8) {
                    HStack {
                        Label("已选中", systemImage: "hand.point.up.left.fill")
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Button {
                            elements.remove(at: idx)
                            selectedID = nil
                        } label: {
                            Label("删除", systemImage: "trash.fill")
                                .font(.caption).foregroundColor(.orange)
                        }
                    }
                    .foregroundColor(.primary)

                    HStack {
                        Text("大小").font(.caption2)
                        Slider(value: Binding(
                            get: { elements[idx].scale },
                            set: { elements[idx].scale = $0 }
                        ), in: 0.3...3)
                        Text("旋转").font(.caption2)
                        Slider(value: Binding(
                            get: { elements[idx].rotation },
                            set: { elements[idx].rotation = $0 }
                        ), in: -90...90)
                    }
                    .foregroundColor(.primary)

                    if case .text = elements[idx].kind {
                        TextField("文字内容", text: Binding(
                            get: {
                                if case .text(let c) = elements[idx].kind { return c }
                                return ""
                            },
                            set: { nv in elements[idx].kind = .text(content: nv) }
                        ))
                        .font(.caption)
                        .textFieldStyle(.plain)
                        .foregroundColor(.primary)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(.primary.opacity(0.08)))

                        HStack {
                            Text("字号").font(.caption2)
                            Slider(value: Binding(
                                get: { elements[idx].fontSize },
                                set: { elements[idx].fontSize = $0 }
                            ), in: 0.02...0.2)
                            colorDot(elements[idx].color)
                        }
                        .foregroundColor(.primary)
                    }
                }
                .padding(12)
            }
        }
    }

    // MARK: 工具面板切换

    private var toolPanel: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "slider.horizontal.3")
                Text("制作过程")
                    .font(.caption2.weight(.semibold))
                Spacer()
            }
            .foregroundColor(.secondary)

            HStack(spacing: 8) {
                panelButton(.background, "背景", "photo.on.rectangle")
                panelButton(.sticker, "素材", "lanyardcard.fill")
                panelButton(.text, "文字", "textformat")
            }

            GlassContainer(tier: .thick, cornerRadius: 22) {
                Group {
                    switch panel {
                    case .background: backgroundPanel
                    case .sticker:    stickerPanel
                    case .text:       textPanel
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .frame(height: 178)
        }
    }

    private func panelButton(_ p: ToolPanel, _ title: String, _ icon: String) -> some View {
        let selected = panel == p
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { panel = p }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                Text(title).font(.caption.weight(.semibold))
            }
            .foregroundColor(.primary)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(
                Capsule().fill(
                    selected ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.1)
                )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: 背景面板（只保留从相册选择背景）

    private var backgroundPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            PhotosPicker(selection: $photoItem, matching: .images) {
                Label("从相册选择背景", systemImage: "photo.on.rectangle")
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)

            HStack(spacing: 10) {
                if let bgImage {
                    Image(uiImage: bgImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 84, height: 53)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Text("已选好背景，可继续添加素材与文字")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button { reCrop() } label: {
                        Label("重新裁切", systemImage: "crop.rotate")
                            .font(.caption2).foregroundColor(.accentColor)
                    }
                    Button { removeBackground() } label: {
                        Label("移除", systemImage: "xmark")
                            .font(.caption2).foregroundColor(.orange)
                    }
                } else {
                    Text("卡面尺寸 1536 × 969，建议选横向图片，可在框内自行裁切填满。")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: 素材面板

    private var stickerPanel: some View {
        VStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(categoryList, id: \.self) { cat in
                        Button { stickerCategory = cat } label: {
                            Text(categoryName(cat))
                                .font(.caption2.weight(.medium))
                                .foregroundColor(.primary)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(Capsule().fill(
                                    stickerCategory == cat ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.08)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            TextField("筛选素材", text: $stickerFilter)
                .font(.caption)
                .textFieldStyle(.plain)
                .foregroundColor(.primary)
                .padding(7)
                .background(Capsule().fill(.primary.opacity(0.08)))

            let items = filteredStickers
            if items.isEmpty {
                VStack(spacing: 6) {
                    ProgressView()
                    Text("素材清单加载中…").font(.caption2).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 58), spacing: 8)], spacing: 8) {
                        ForEach(items, id: \.file) { item in
                            Button { addSticker(item) } label: {
                                RemoteStickerImage(file: item.file, size: 54)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(item.name)
                        }
                    }
                }
            }
        }
    }

    private var categoryList: [String] {
        ["network", "bank", "transit", "tier", "airline", "car", "school", "other"]
    }

    private func categoryName(_ c: String) -> String {
        ["network": "卡组织", "bank": "银行", "transit": "交通卡", "tier": "卡等级",
         "airline": "航司", "car": "车标", "school": "学校", "other": "其他"][c] ?? c
    }

    private var filteredStickers: [StickerItem] {
        let inCat = stickers.filter { $0.category == stickerCategory }
        let f = stickerFilter.trimmingCharacters(in: .whitespaces)
        guard !f.isEmpty else { return inCat }
        return inCat.filter { $0.name.localizedCaseInsensitiveContains(f) }
    }

    private func addSticker(_ item: StickerItem) {
        let aspect = CGFloat(item.aspect ?? 0.6)
        let element = CanvasElement(
            kind: .sticker(file: item.file, aspect: aspect),
            baseWidth: 0.28
        )
        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
            elements.append(element)
            selectedID = element.id
        }
        // 在线取回素材后写入缓存，画布随即显示
        Task {
            if let img = await StickerService.shared.loadSticker(item.file) {
                stickerCache[item.file] = img
                if let idx = elements.firstIndex(where: { $0.id == element.id }) {
                    elements[idx].kind = .sticker(file: item.file,
                                                  aspect: img.size.height / max(img.size.width, 1))
                }
            }
        }
    }

    // MARK: 文字面板

    private var textPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("输入文字", text: $textContent)
                .font(.subheadline)
                .textFieldStyle(.plain)
                .foregroundColor(.primary)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(.primary.opacity(0.08)))

            HStack {
                Text("字号").font(.caption2)
                Slider(value: $textSize, in: 0.02...0.18)
            }
            .foregroundColor(.primary)

            HStack(spacing: 8) {
                ForEach(["#FFFFFF", "#000000", "#FFD166", "#EF476F", "#06D6A0", "#118AB2"], id: \.self) { hex in
                    Circle()
                        .fill(Color(hex: hex))
                        .frame(width: 26, height: 26)
                        .overlay(Circle().stroke(textColor == hex ? Color.accentColor : Color.primary.opacity(0.3), lineWidth: 2))
                        .onTapGesture { textColor = hex }
                }
            }

            Picker("", selection: $textWeight) {
                Text("常规").tag(0)
                Text("中等").tag(1)
                Text("加粗").tag(2)
                Text("特粗").tag(3)
            }
            .pickerStyle(.segmented)

            GlassButton(title: "添加文字", systemImage: "plus", fullWidth: true) {
                let element = CanvasElement(
                    kind: .text(content: textContent),
                    fontSize: textSize, color: textColor, weight: textWeight
                )
                withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                    elements.append(element)
                    selectedID = element.id
                }
            }
        }
    }

    // MARK: 导出

    private func exportAndWrite() {
        guard let source = bgImage else { return }
        // 先把背景压成不透明底图，避免透明区域在部分机型上被渲染成杂色
        let base = ImageEngine.makeOpaqueFill(source, size: CGSize(width: 1536, height: 969))
        let art = CanvasArt(width: 1536, height: 969,
                            bgImage: base,
                            stickerCache: stickerCache,
                            elements: elements, selectedID: nil,
                            onSelect: { _ in }, onMove: { _, _ in }, onPinch: { _, _ in })
            .frame(width: 1536, height: 969)

        let renderer = ImageRenderer(content: art)
        renderer.scale = 1
        guard let img = renderer.uiImage else { return }
        let title = editing?.displayTitle ?? "自制卡面"
        model.requestWrite(editorImage: img, title: title)
    }

    // MARK: 清单加载（仅 JSON 清单嵌入，素材图全部在线加载）

    private func loadManifests() {
        guard stickers.isEmpty else { return }
        if let list = StickerService.loadManifest("stickers", as: [StickerItem].self) {
            stickers = list
        }
    }
}

// MARK: - 画布渲染（交互 & 导出共用，WYSIWYG）

struct CanvasArt: View {
    let width: CGFloat
    let height: CGFloat
    let bgImage: UIImage?
    let stickerCache: [String: UIImage]
    let elements: [CanvasElement]
    let selectedID: UUID?
    let onSelect: (UUID?) -> Void
    let onMove: (UUID, CGPoint) -> Void
    let onPinch: (UUID, CGFloat) -> Void

    var body: some View {
        ZStack {
            background
            ForEach(elements) { el in
                elementView(el)
            }
        }
        .frame(width: width, height: height)
        .clipped()
        .contentShape(Rectangle())
        .onTapGesture { onSelect(nil) }
    }

    // MARK: 背景（只能是相册图片）

    @ViewBuilder
    private var background: some View {
        if let bgImage {
            Image(uiImage: bgImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: width, height: height)
                .clipped()
        } else {
            Color(uiColor: .secondarySystemBackground)
        }
    }

    // MARK: 元素

    private func elementView(_ el: CanvasElement) -> some View {
        let w = width * el.baseWidth * el.scale
        let selected = el.id == selectedID

        return Group {
            switch el.kind {
            case .sticker(let file, _):
                if let img = stickerCache[file] {
                    Image(uiImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                }
            case .text(let content):
                Text(content)
                    .font(.system(size: height * el.fontSize * el.scale,
                                  weight: fontWeight(el.weight)))
                    .foregroundColor(Color(hex: el.color))
                    .lineLimit(1)
                    .minimumScaleFactor(0.3)
            }
        }
        .frame(width: w, height: nil)
        .rotationEffect(.degrees(el.rotation))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(selected ? Color.accentColor : .clear,
                              style: StrokeStyle(lineWidth: 1.5, dash: [5]))
        )
        .position(x: el.center.x * width, y: el.center.y * height)
        .gesture(
            DragGesture()
                .onChanged { v in
                    let x = min(max(v.location.x / width, 0), 1)
                    let y = min(max(v.location.y / height, 0), 1)
                    onMove(el.id, CGPoint(x: x, y: y))
                }
        )
        .simultaneousGesture(
            MagnificationGesture()
                .onChanged { scale in onPinch(el.id, scale) }
        )
        .onTapGesture { onSelect(el.id) }
    }

    private func fontWeight(_ raw: Int) -> Font.Weight {
        switch raw {
        case 0: return .regular
        case 1: return .medium
        case 3: return .black
        default: return .bold
        }
    }
}

// MARK: - 辅助

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if s.count == 6 { s += "FF" }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        self.init(.sRGB,
                  red: Double((v >> 24) & 0xFF) / 255,
                  green: Double((v >> 16) & 0xFF) / 255,
                  blue: Double((v >> 8) & 0xFF) / 255,
                  opacity: Double(v & 0xFF) / 255)
    }
}

private func colorDot(_ hex: String) -> some View {
    Circle()
        .fill(Color(hex: hex))
        .frame(width: 22, height: 22)
        .overlay(Circle().stroke(.primary.opacity(0.3), lineWidth: 1))
}
