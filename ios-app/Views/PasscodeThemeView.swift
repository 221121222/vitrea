//
//  PasscodeThemeView.swift
//  Vitrea
//
//  键盘 Tab：锁屏密码按键主题（.passthm）
//    · 主题库：主源为 Cowabunga 主题仓库（sourcelocation/Cowabunga-theme-repo），
//      预览图**已内置在 App 内**（Resources/PasscodePreviews），列表秒出、可离线；
//      点按条目一键下载 .passthm 并解析；
//    · 导入 .passthm：解出按键图后可直接应用；
//    · 自定义：上传 10 张数字按键图（0–9），实时预览并应用到锁屏键盘。
//

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

extension UTType {
    /// .passthm 主题包（zip 容器）
    static let passthm = UTType(filenameExtension: "passthm") ?? .data
}

struct PasscodeThemeView: View {

    enum Mode: String, CaseIterable, Identifiable {
        case library = "主题库"
        case custom  = "自定义"
        var id: String { rawValue }
    }

    @Environment(\.openURL) private var openURL

    @State private var mode: Mode = .library

    // 主题库
    @State private var themes: [PasscodeTheme] = []
    @State private var isLoading = false
    @State private var isRefreshing = false
    @State private var loadError: String?
    @State private var searchText = ""

    // 按键图（0–9）
    @State private var digitImages: [String: UIImage] = [:]
    @State private var importedName: String?

    // 选择图片
    @State private var editingDigit: String?
    @State private var pickedPhoto: PhotosPickerItem?

    // 导入 .passthm
    @State private var showImporter = false

    // 应用参数
    @State private var telephonyVersion = TelephonyUIVersion.current.directory
    @State private var allLocales = false

    // 主题库直链下载中
    @State private var installingSlug: String?

    // 应用状态
    @State private var applying = false
    @State private var applyLog: [String] = []
    @State private var alert: PasscodeAlert?

    private var filledCount: Int { digitImages.count }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    modePicker
                    switch mode {
                    case .library: librarySection
                    case .custom:  customSection
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("键盘").font(.headline.weight(.semibold))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await refreshFromNetwork() }
                    } label: {
                        if isRefreshing {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                    }
                    .disabled(isRefreshing || mode != .library)
                    .accessibilityLabel("从 GitHub 刷新主题目录")
                }
            }
            .task { await loadCatalogIfNeeded() }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.passthm, .zip, .data],
                          allowsMultipleSelection: false) { result in
                handleImport(result)
            }
            .photosPicker(isPresented: Binding(
                get: { editingDigit != nil },
                set: { if !$0 { editingDigit = nil } }),
                selection: $pickedPhoto,
                matching: .images)
            .onChange(of: pickedPhoto) { _, newValue in
                guard let newValue else { return }
                Task { await loadPicked(newValue) }
            }
            .alert(item: $alert, content: alertContent)
        }
    }

    // MARK: - 模式

    private var modePicker: some View {
        Picker("模式", selection: $mode) {
            ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
    }

    // MARK: - 主题库

    private var librarySection: some View {
        VStack(spacing: 14) {
            searchBar

            if isLoading && themes.isEmpty {
                loadingState
            } else if let loadError, themes.isEmpty {
                errorState(loadError)
            } else {
                importCard
                if themes.isEmpty {
                    emptyState
                } else {
                    ForEach(filteredThemes) { theme in
                        themeRow(theme)
                    }
                }
            }

            footerNotice
        }
    }

    private var filteredThemes: [PasscodeTheme] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return themes }
        return themes.filter {
            $0.title.localizedCaseInsensitiveContains(q)
                || $0.author.localizedCaseInsensitiveContains(q)
                || $0.category.localizedCaseInsensitiveContains(q)
                || $0.summary.localizedCaseInsensitiveContains(q)
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundColor(.secondary)
            TextField("搜索主题 / 作者 / 分类", text: $searchText)
                .font(.subheadline)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var importCard: some View {
        GlassCard(padding: 16, cornerRadius: 18) {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "square.and.arrow.down.on.square")
                        .font(.title3).foregroundColor(.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("导入 .passthm 主题包").font(.subheadline.weight(.semibold))
                        Text("从主题库下载主题包后，在这里导入并应用")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                GlassButton(title: "选择 .passthm 文件",
                            systemImage: "folder",
                            style: .secondary, fullWidth: true) {
                    showImporter = true
                }
            }
        }
    }

    private func themeRow(_ theme: PasscodeTheme) -> some View {
        Button {
            Task { await handleThemeTap(theme) }
        } label: {
            GlassCard(padding: 10, cornerRadius: 16) {
                HStack(spacing: 12) {
                    ThemePreviewThumb(theme: theme)
                        .frame(width: 78, height: 78)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 5) {
                            Text(theme.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(.primary).lineLimit(1)
                            if theme.isBundled {
                                Text("内置")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundColor(.accentColor)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Color.accentColor.opacity(0.14), in: Capsule())
                            }
                        }
                        if !theme.author.isEmpty {
                            Text(theme.author)
                                .font(.caption2).foregroundColor(.secondary).lineLimit(1)
                        }
                        if !theme.summary.isEmpty {
                            Text(theme.summary)
                                .font(.caption2).foregroundColor(.secondary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)

                    themeTrailing(theme)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(installingSlug == theme.slug)
    }

    @ViewBuilder
    private func themeTrailing(_ theme: PasscodeTheme) -> some View {
        if installingSlug == theme.slug {
            ProgressView().controlSize(.small)
        } else if theme.canDownloadDirectly {
            VStack(spacing: 2) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.title3).foregroundColor(.accentColor)
                Text("一键安装")
                    .font(.system(size: 9)).foregroundColor(.secondary)
            }
        } else {
            Image(systemName: "safari")
                .font(.footnote.weight(.semibold)).foregroundColor(.secondary)
        }
    }

    /// 有直链就直接下包 + 解图并跳到「自定义」；没有直链才退回浏览器
    private func handleThemeTap(_ theme: PasscodeTheme) async {
        guard theme.canDownloadDirectly else {
            openURL(theme.pageURL)
            return
        }
        guard installingSlug == nil else { return }
        installingSlug = theme.slug
        defer { installingSlug = nil }
        do {
            let local = try await PasscodeThemeApplier.download(theme: theme)
            let digits = try await PasscodeThemeApplier.extractDigits(from: local)
            try? FileManager.default.removeItem(at: local)
            await MainActor.run {
                digitImages = digits
                importedName = theme.title
                mode = .custom
                alert = .info("已下载并解析 \(digits.count) 个按键，切到「自定义」页确认后应用。")
            }
        } catch {
            await MainActor.run { alert = .error(error.localizedDescription) }
        }
    }

    // MARK: - 自定义

    private var customSection: some View {
        VStack(spacing: 14) {
            keypadPreview

            GlassCard(padding: 16, cornerRadius: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("按键图片（0–9）").font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("\(filledCount)/10")
                            .font(.caption.monospacedDigit())
                            .foregroundColor(filledCount == 10 ? .green : .secondary)
                    }
                    Text("点按任意按键上传对应图片，建议正方形、背景透明（PNG）。")
                        .font(.caption2).foregroundColor(.secondary)

                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5),
                              spacing: 8) {
                        ForEach(PasscodeKeypad.digits, id: \.self) { digit in
                            digitSlot(digit)
                        }
                    }

                    HStack(spacing: 10) {
                        GlassButton(title: "清空", systemImage: "trash",
                                    style: .secondary, fullWidth: true) {
                            digitImages.removeAll()
                            importedName = nil
                            PasscodeCustomStore.clear()
                        }
                        GlassButton(title: "保存", systemImage: "square.and.arrow.down",
                                    style: .secondary, fullWidth: true,
                                    enabled: filledCount > 0) {
                            PasscodeCustomStore.save(digitImages: digitImages)
                            alert = .info("已保存自定义主题，下次打开自动载入。")
                        }
                    }
                }
            }

            applyCard
            footerNotice
        }
        .onAppear { if digitImages.isEmpty { digitImages = PasscodeCustomStore.load() } }
    }

    private func digitSlot(_ digit: String) -> some View {
        Button {
            editingDigit = digit
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                if let image = digitImages[digit] {
                    Image(uiImage: image)
                        .resizable().scaledToFit()
                        .padding(4)
                } else {
                    Text(digit)
                        .font(.headline.weight(.semibold))
                        .foregroundColor(.secondary)
                }
            }
            .frame(height: 52)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(digitImages[digit] != nil ? Color.accentColor.opacity(0.6)
                                                            : Color.primary.opacity(0.10),
                                  lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var keypadPreview: some View {
        GlassCard(padding: 18, cornerRadius: 20) {
            VStack(spacing: 14) {
                HStack {
                    Label("锁屏键盘预览", systemImage: "lock.rotation")
                        .font(.subheadline.weight(.semibold)).foregroundColor(.secondary)
                    Spacer()
                    if let importedName {
                        Text(importedName)
                            .font(.caption2).foregroundColor(.secondary).lineLimit(1)
                    }
                }
                KeypadPreview(images: digitImages)
            }
        }
    }

    private var applyCard: some View {
        GlassCard(padding: 16, cornerRadius: 18) {
            VStack(spacing: 12) {
                HStack {
                    Text("写入目标").font(.subheadline.weight(.semibold))
                    Spacer()
                    Picker("版本", selection: $telephonyVersion) {
                        ForEach(TelephonyUIVersion.all) { info in
                            Text("\(info.directory)（\(info.osRange)）").tag(info.directory)
                        }
                    }
                    .pickerStyle(.menu)
                }

                // 目录名里的数字跟 iOS 大版本走，选错了系统根本不会读
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.caption2).foregroundColor(.secondary)
                    Text("本机（iOS \(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)）应选 \(TelephonyUIVersion.current.directory) · \(TelephonyUIVersion.current.osRange)")
                        .font(.caption2).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }

                Toggle(isOn: $allLocales) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("写入全部语言").font(.subheadline.weight(.medium))
                        Text("默认只写 en + other；开启后覆盖 17 种语言（文件更多、更慢）")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                }

                if applying {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView()
                        if let last = applyLog.last {
                            Text(last).font(.caption2).foregroundColor(.secondary).lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GlassButton(
                    title: applying ? "正在应用…" : "应用到锁屏键盘",
                    systemImage: applying ? nil : "wand.and.stars",
                    style: .primary, fullWidth: true,
                    enabled: filledCount > 0 && !applying
                ) {
                    Task { await apply() }
                }

                Text("前置条件与卡面写入一致：有效配对 + 回环隧道。写入后锁定一次屏幕即可看到效果；重启手机后系统会还原默认键盘，需要重新写入。")
                    .font(.caption2).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 状态视图

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("正在加载主题库…").font(.subheadline).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 48)
    }

    private func errorState(_ message: String) -> some View {
        GlassCard(padding: 20, cornerRadius: 18) {
            VStack(spacing: 10) {
                Image(systemName: "wifi.exclamationmark").font(.title2).foregroundColor(.orange)
                Text("主题库加载失败").font(.subheadline.weight(.semibold))
                Text(message).font(.caption).foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                Button("重试") { Task { await reloadCatalog() } }
                    .buttonStyle(.bordered).controlSize(.large)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "keyboard").font(.system(size: 40, weight: .light))
                .foregroundColor(.secondary)
            Text("没有匹配的主题").font(.headline)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 32)
    }

    private var footerNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("关于按键主题", systemImage: "info.circle")
                .font(.footnote.weight(.semibold)).foregroundColor(.secondary)
            Text("主题库来自 Cowabunga 主题仓库（sourcelocation/Cowabunga-theme-repo），主题包与预览图已全部内置在 App 内（27 个主题，打开即显示、无需联网、可离线安装）。右上角按钮可主动去 GitHub 拉取新增主题；失败时会保留内置列表。主题版权归各作者所有，写入依赖系统未公开接口，可能随系统更新失效，请自行评估风险。")
                .font(.caption2).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 数据加载

    private func loadCatalogIfNeeded() async {
        guard themes.isEmpty, !isLoading else { return }
        await reloadCatalog()
    }

    /// 首次/重试：内置清单优先，秒开且离线可用
    private func reloadCatalog() async {
        isLoading = true
        defer { isLoading = false }
        do {
            themes = try await PasscodeThemeCatalog.fetch()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// 工具栏按钮：主动去 GitHub 拉最新目录。
    /// 失败时**保留内置列表**并提示，不会把页面清空。
    private func refreshFromNetwork() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let remote = try await PasscodeThemeCatalog.fetchRemote()
            guard !remote.isEmpty else {
                alert = .error("GitHub 目录为空，已保留内置主题。")
                return
            }
            themes = remote
            loadError = nil
            alert = .info("已更新到最新目录，共 \(remote.count) 个主题。")
        } catch {
            alert = .error("在线刷新失败：\(error.localizedDescription)\n已保留内置主题，不影响使用。")
        }
    }

    private func loadPicked(_ item: PhotosPickerItem) async {
        guard let digit = editingDigit else { return }
        defer { pickedPhoto = nil; editingDigit = nil }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else { return }
        digitImages[digit] = image
        importedName = nil
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            Task {
                do {
                    let digits = try await PasscodeThemeApplier.extractDigits(from: url)
                    await MainActor.run {
                        digitImages = digits
                        importedName = url.deletingPathExtension().lastPathComponent
                        mode = .custom
                        alert = .info("已解析 \(digits.count) 个按键，切到「自定义」页确认后应用。")
                    }
                } catch {
                    await MainActor.run { alert = .error(error.localizedDescription) }
                }
            }
        case .failure(let error):
            alert = .error(error.localizedDescription)
        }
    }

    private func apply() async {
        guard filledCount > 0, !applying else { return }
        applying = true
        applyLog = []
        defer { applying = false }
        do {
            let count = try await PasscodeThemeApplier.apply(
                digitImages: digitImages,
                telephonyVersion: telephonyVersion,
                allLocales: allLocales
            ) { line in
                Task { @MainActor in applyLog.append(line) }
            }
            alert = .info("已写入 \(count) 个按键资源到 \(telephonyVersion)。\n锁定一次屏幕即可看到新键盘。")
        } catch {
            alert = .error(error.localizedDescription)
        }
    }

    private func alertContent(_ alert: PasscodeAlert) -> Alert {
        switch alert {
        case .info(let m):
            return Alert(title: Text("完成"), message: Text(m), dismissButton: .default(Text("好")))
        case .error(let m):
            return Alert(title: Text("操作未完成"), message: Text(m), dismissButton: .default(Text("好")))
        }
    }
}

// MARK: - 主题预览图
//
// 优先用内置图（秒出、可离线）；只有旧源/未内置的条目才回落到远端。

struct ThemePreviewThumb: View {
    let theme: PasscodeTheme

    @State private var remote: UIImage?
    @State private var failed = false

    private var bundled: UIImage? {
        theme.previewImageName.flatMap { PasscodePreviewStore.image(named: $0) }
    }

    var body: some View {
        ZStack {
            if let image = bundled ?? remote {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if failed || (theme.previewURL == nil && theme.previewImageName == nil) {
                Image(systemName: "keyboard")
                    .font(.title3)
                    .foregroundColor(.secondary.opacity(0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.primary.opacity(0.05))
            } else {
                Rectangle().fill(Color.primary.opacity(0.06))
                    .overlay(ProgressView().controlSize(.small))
            }
        }
        .clipped()
        .task(id: theme.id) {
            guard bundled == nil, let url = theme.previewURL else { return }
            if let hit = ImageCacheStore.shared.cachedImage(for: url) {
                remote = hit
                return
            }
            remote = try? await ImageCacheStore.shared.load(url, maxDimension: 320)
            if remote == nil { failed = true }
        }
    }
}

// MARK: - 键盘预览

struct KeypadPreview: View {
    let images: [String: UIImage]

    private let layout: [[String?]] = [
        ["1", "2", "3"],
        ["4", "5", "6"],
        ["7", "8", "9"],
        [nil, "0", nil],
    ]

    var body: some View {
        VStack(spacing: 12) {
            ForEach(Array(layout.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 20) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, digit in
                        if let digit {
                            key(digit)
                        } else {
                            Color.clear.frame(width: 64, height: 64)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func key(_ digit: String) -> some View {
        ZStack {
            Circle().fill(Color.primary.opacity(0.08))
            if let image = images[digit] {
                Image(uiImage: image)
                    .resizable().scaledToFit()
                    .clipShape(Circle())
            } else {
                Text(digit)
                    .font(.system(size: 26, weight: .light))
                    .foregroundColor(.primary)
            }
        }
        .frame(width: 64, height: 64)
        .overlay(Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
    }
}

// MARK: - 提示

private enum PasscodeAlert: Identifiable {
    case info(String)
    case error(String)

    var id: String {
        switch self {
        case .info(let m):  return "info-\(m)"
        case .error(let m): return "error-\(m)"
        }
    }
}
