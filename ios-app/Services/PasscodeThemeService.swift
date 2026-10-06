//
//  PasscodeThemeService.swift
//  Vitrea
//
//  锁屏密码按键主题（.passthm）：
//    1. **主题包与预览图全部内置**（`ios-app/Resources/PasscodeThemes`，27 个主题 + `themes.json` 清单，
//       以及 `PasscodePreviews` 里的预览图）。主题库秒开、可离线安装 —— 不再依赖 raw.githubusercontent.com。
//       网络源只在「内置清单缺失」时回退，或由工具栏按钮手动刷新。
//    2. 也支持导入本地 .passthm。
//    3. 用 10 张数字按键图生成 iOS 需要的「多语言 × 标准/粗体」缓存位图文件名集合。
//    4. 经开发者配对 + 回环隧道，用 al_exploit_write_dir 写入
//       /var/mobile/Library/Caches/TelephonyUI-10（iOS 18+；15–17 为 -9，更早为 -8）。
//
//  文件名规则（与 AirCard 后端一致）：
//    {lang}-{digit}-{subtext}--white{bold}.png
//    空 subtext 写作 {lang}-{digit}---white.png（即 `-` + `--white`）。
//

import Foundation
import UIKit
import AirliftFFI

// MARK: - 目录模型

struct PasscodeTheme: Identifiable, Hashable {
    let slug: String
    let title: String
    let author: String
    let category: String
    let summary: String
    /// 远端预览图（内置图缺失时的兜底）
    let previewURL: URL?
    /// 内置预览图文件名（不含扩展名）；命中时直接读 bundle，不再走网络
    let previewImageName: String?
    /// 内置主题包文件名（`Resources/PasscodeThemes/<name>.passthm`）；命中则安装时无需联网
    let bundledPackageName: String?
    /// 主题包直链；为 nil 时只能走 pageURL 浏览（旧源）
    let downloadURL: URL?
    let pageURL: URL

    var id: String { slug }

    /// 能直接装：内置包或远端直链都算
    var canDownloadDirectly: Bool { bundledPackageName != nil || downloadURL != nil }

    /// 随 App 打包，离线可用
    var isBundled: Bool { bundledPackageName != nil }

    /// 优先内置，其次远端
    var hasLocalPreview: Bool { previewImageName != nil }
}

// MARK: - 适配的 iOS 版本

/// `TelephonyUI-*` 缓存目录与系统版本的对应关系。
/// 目录名里的数字跟 iOS 大版本走，选错目录等于写了个系统不会读的地方。
enum TelephonyUIVersion {

    struct Info: Identifiable, Hashable {
        let directory: String
        let osRange: String
        let note: String
        var id: String { directory }
    }

    static let all: [Info] = [
        Info(directory: "TelephonyUI-10", osRange: "iOS 18 及更高", note: "推荐"),
        Info(directory: "TelephonyUI-9",  osRange: "iOS 15 – 17",   note: ""),
        Info(directory: "TelephonyUI-8",  osRange: "iOS 14 及更低", note: ""),
    ]

    /// 当前设备最该用的那个目录
    static var current: Info {
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        if major >= 18 { return all[0] }
        if major >= 15 { return all[1] }
        return all[2]
    }

    static func info(for directory: String) -> Info? {
        all.first { $0.directory == directory }
    }

    /// 「TelephonyUI-10 · iOS 18+」这种一行说明
    static func label(for directory: String) -> String {
        guard let info = info(for: directory) else { return directory }
        return "\(info.directory) · \(info.osRange)"
    }

    static var directories: [String] { all.map(\.directory) }
}

// MARK: - 错误


enum PasscodeThemeError: LocalizedError {
    case network(String)
    case noImages
    case notPaired
    case tunnelDown
    case ffi(String)

    var errorDescription: String? {
        switch self {
        case .network(let m):  return "主题目录加载失败：\(m)"
        case .noImages:        return "没有解析到任何按键图片。请确认这是一个有效的 .passthm 主题包。"
        case .notPaired:       return "未检测到有效配对记录，请先完成本机配对。"
        case .tunnelDown:      return "回环隧道未连接，无法写入设备。"
        case .ffi(let m):      return m
        }
    }
}

// MARK: - 按键命名规则

enum PasscodeKeypad {

    static let digits = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"]

    /// 标准按键副文本（0–9）
    static let subtexts: [String: String] = [
        "0": "+",
        "1": "",
        "2": "A B C",
        "3": "D E F",
        "4": "G H I",
        "5": "J K L",
        "6": "M N O",
        "7": "P Q R S",
        "8": "T U V",
        "9": "W X Y Z",
    ]

    /// 全部语言标识
    static let allLocales = ["en", "other", "ru", "uk", "es", "fr", "de", "it",
                             "pt", "tr", "pl", "nl", "ja", "ko", "zh", "ar", "he"]

    /// 精简语言（默认写入）：en + other，兼容绝大多数系统
    static let baseLocales = ["en", "other"]

    private static let cyrillicRU: [String: String] = [
        "2": "А Б В Г", "3": "Д Е Ж З", "4": "И Й К Л", "5": "М Н О П",
        "6": "Р С Т У", "7": "Ф Х Ц Ч", "8": "Ш Щ Ъ Ы", "9": "Ь Э Ю Я",
    ]
    private static let cyrillicUK: [String: String] = [
        "2": "А Б В Г", "3": "Д Е Ж З", "4": "І Ї Й К", "5": "Л М Н О",
        "6": "П Р С Т", "7": "У Ф Х Ц", "8": "Ч Ш Щ Ь", "9": "Ю Я",
    ]

    static var telephonyVersions: [String] { TelephonyUIVersion.directories }

    /// 生成「目标文件名 -> PNG 数据」。digitImages 键为 "0"…"9"。
    static func renderSet(digitImages: [String: UIImage],
                          locales: [String],
                          includeBold: Bool) -> [String: Data] {
        let boldVariants = includeBold ? ["", "-bold"] : [""]
        var out: [String: Data] = [:]

        for digit in digits {
            guard let image = digitImages[digit], let data = image.pngData() else { continue }
            let std = subtexts[digit] ?? ""
            for lang in locales {
                for bold in boldVariants {
                    // 空副文本变体
                    out["\(lang)-\(digit)---white\(bold).png"] = data
                    // 标准拉丁副文本
                    if !std.isEmpty {
                        out["\(lang)-\(digit)-\(std)--white\(bold).png"] = data
                        let compact = std.replacingOccurrences(of: " ", with: "")
                        if compact != std {
                            out["\(lang)-\(digit)-\(compact)--white\(bold).png"] = data
                        }
                    }
                    // 西里尔副文本（俄语 / 乌克兰语）
                    if lang == "ru", let cyr = cyrillicRU[digit] {
                        out["\(lang)-\(digit)-\(cyr)--white\(bold).png"] = data
                    }
                    if lang == "uk", let cyr = cyrillicUK[digit] {
                        out["\(lang)-\(digit)-\(cyr)--white\(bold).png"] = data
                    }
                }
            }
        }
        return out
    }

    /// 从任意图片文件名解析按键数字（0–9），失败返回 nil
    static func digit(fromFileName name: String) -> String? {
        let stem = (name as NSString).deletingPathExtension
        var clean = stem
        if let r = clean.range(of: "--?white(-bold)?$", options: [.regularExpression, .caseInsensitive]) {
            clean = String(clean[clean.startIndex..<r.lowerBound])
        }
        guard let re = try? NSRegularExpression(pattern: "^(?:([a-zA-Z]+)-)?([0-9*#])(?:-([^-\\n]+))?") else {
            return nil
        }
        let range = NSRange(clean.startIndex..<clean.endIndex, in: clean)
        guard let m = re.firstMatch(in: clean, range: range),
              m.numberOfRanges > 2,
              let r = Range(m.range(at: 2), in: clean) else { return nil }
        let d = String(clean[r])
        return digits.contains(d) ? d : nil
    }
}

// MARK: - 内置预览图
//
// 预览图已随 App 打包（`ios-app/Resources/PasscodePreviews/<名字>.jpg`，
// 由 Cowabunga 仓库的 `passcode-theme-previews/*.png` 等比压缩而来，420px 长边 / JPEG q78）。
// 这样列表滚动时不再逐个请求 raw.githubusercontent.com —— 秒出图，且离线可用。

enum PasscodePreviewStore {

    /// bundle 内的子目录名（folder reference 会原样拷进 App）
    static let folder = "PasscodePreviews"

    private static let cache = NSCache<NSString, UIImage>()

    /// 由主题条目取内置预览图（未内置时返回 nil）
    static func image(for theme: PasscodeTheme) -> UIImage? {
        guard let name = theme.previewImageName else { return nil }
        return image(named: name)
    }

    static func image(named name: String) -> UIImage? {
        if let hit = cache.object(forKey: name as NSString) { return hit }
        guard let path = bundledPath(named: name),
              let image = UIImage(contentsOfFile: path) else { return nil }
        cache.setObject(image, forKey: name as NSString)
        return image
    }

    /// 只查文件在不在，不解码（目录抓取时逐条调用，避免无谓解码）
    static func bundledPath(named name: String) -> String? {
        Bundle.main.path(forResource: "\(folder)/\(name)", ofType: "jpg")
    }

    /// 从清单里的 preview 路径推出内置文件名：
    /// `passcode-theme-previews/among_us.png` → `among_us`
    static func bundledName(for previewPath: String?) -> String? {
        guard let previewPath, !previewPath.isEmpty else { return nil }
        let stem = ((previewPath as NSString).lastPathComponent as NSString).deletingPathExtension
        guard !stem.isEmpty, bundledPath(named: stem) != nil else { return nil }
        return stem
    }
}

// MARK: - 主题目录抓取

/// 主题目录。
///
/// **内置优先**：27 个主题包（`.passthm`）+ 预览图都随 App 打包，清单读
/// `Resources/PasscodeThemes/themes.json`。这样主题库秒开、完全离线可用 ——
/// 之前每次进页面都去 raw.githubusercontent.com 拉清单，网络一抖就「加载失败」。
///
/// 网络源保留为**回退**（内置清单缺失时）与**手动刷新**（工具栏按钮，可拿到仓库新增的主题）。
enum PasscodeThemeCatalog {

    /// 内置资源目录名（folder reference 会原样拷进 App）
    static let bundledFolder = "PasscodeThemes"
    static let bundledManifest = "themes"

    /// Cowabunga-theme-repo 的 raw 根
    static let repoRaw = URL(string: "https://raw.githubusercontent.com/sourcelocation/Cowabunga-theme-repo/main/")!
    static let manifestURL = repoRaw.appendingPathComponent("passcode-themes.json")
    /// 仓库主页（用于「在 GitHub 打开」）
    static let repoPage = URL(string: "https://github.com/sourcelocation/Cowabunga-theme-repo/tree/main/passcode-themes")!

    /// 旧源（回退用）
    static let legacyBaseURL = URL(string: "https://aircardios.github.io/pass-themes/")!

    // MARK: 内置主题包路径

    /// 取内置 `.passthm` 的绝对路径（不存在返回 nil）
    static func bundledPackagePath(named file: String) -> String? {
        guard let res = Bundle.main.resourceURL else { return nil }
        let url = res.appendingPathComponent("\(bundledFolder)/\(file)")
        return FileManager.default.fileExists(atPath: url.path) ? url.path : nil
    }

    // MARK: 主入口

    /// 内置清单优先；没有才走网络
    static func fetch() async throws -> [PasscodeTheme] {
        let bundled = loadBundled()
        if !bundled.isEmpty { return bundled }
        return try await fetchRemote()
    }

    /// 只走网络（工具栏「刷新目录」用）
    static func fetchRemote() async throws -> [PasscodeTheme] {
        if let themes = try? await fetchCowabunga(), !themes.isEmpty { return themes }
        let fallback = try await fetchLegacy()
        guard !fallback.isEmpty else {
            throw PasscodeThemeError.network("主源与备源都没有返回主题")
        }
        return fallback
    }

    // MARK: 内置（JSON 清单 + 本地包）

    private struct BundledEntry: Decodable {
        let name: String
        let description: String?
        let file: String
        let preview: String?
        let version: String?
        let contact: [String: String]?
    }

    static func loadBundled() -> [PasscodeTheme] {
        guard let res = Bundle.main.resourceURL else { return [] }
        let manifest = res.appendingPathComponent("\(bundledFolder)/\(bundledManifest).json")
        guard let data = try? Data(contentsOf: manifest),
              let entries = try? JSONDecoder().decode([BundledEntry].self, from: data) else {
            return []
        }

        return entries.compactMap { entry -> PasscodeTheme? in
            // 清单里列了但包里没有 → 跳过，避免装出个空主题
            guard bundledPackagePath(named: entry.file) != nil else { return nil }

            let author = entry.contact?.map { "\($0.key) \($0.value)" }.sorted().first ?? ""
            let previewName = entry.preview.flatMap { name in
                PasscodePreviewStore.bundledPath(named: name) != nil ? name : nil
            }

            return PasscodeTheme(
                slug: (entry.file as NSString).deletingPathExtension,
                title: entry.name,
                author: author,
                category: entry.version.map { "v\($0)" } ?? "",
                summary: entry.description ?? "",
                previewURL: nil,
                previewImageName: previewName,
                bundledPackageName: entry.file,
                downloadURL: nil,
                pageURL: repoPage
            )
        }
    }

    // MARK: Cowabunga（JSON + 直链）

    private struct CowabungaEntry: Decodable {
        let name: String
        let description: String?
        let url: String
        let preview: String?
        let version: String?
        let contact: [String: String]?

        enum CodingKeys: String, CodingKey {
            case name, description, url, preview, version, contact
        }
    }

    private static func fetchCowabunga() async throws -> [PasscodeTheme] {
        var req = URLRequest(url: manifestURL)
        req.timeoutInterval = 20
        req.setValue("Vitrea/1.0 (iOS)", forHTTPHeaderField: "User-Agent")

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw PasscodeThemeError.network("清单 HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
        }

        let entries = try JSONDecoder().decode([CowabungaEntry].self, from: data)

        return entries.compactMap { entry -> PasscodeTheme? in
            guard let packageURL = URL(string: entry.url, relativeTo: repoRaw) else { return nil }
            let preview = entry.preview.flatMap { URL(string: $0, relativeTo: repoRaw) }
            let slug = (entry.url as NSString).lastPathComponent
                .replacingOccurrences(of: ".passthm", with: "")
            let author = entry.contact?.map { "\($0.key) \($0.value)" }.sorted().first ?? ""
            let category = (entry.version.map { "v\($0)" }) ?? ""
            // 远端清单里的条目，若本地已内置同名包，照样标成内置（安装走本地，更快）
            let localFile = (entry.url as NSString).lastPathComponent
            return PasscodeTheme(
                slug: slug,
                title: entry.name,
                author: author,
                category: category,
                summary: entry.description ?? "",
                previewURL: preview,
                previewImageName: PasscodePreviewStore.bundledName(for: entry.preview),
                bundledPackageName: bundledPackagePath(named: localFile) != nil ? localFile : nil,
                downloadURL: packageURL,
                pageURL: repoPage
            )
        }
    }

    // MARK: 旧源（HTML）

    private static func fetchLegacy() async throws -> [PasscodeTheme] {
        var req = URLRequest(url: legacyBaseURL)
        req.timeoutInterval = 20
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")

        let html: String
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw PasscodeThemeError.network("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
            }
            html = String(data: data, encoding: .utf8) ?? ""
        } catch let e as PasscodeThemeError {
            throw e
        } catch {
            throw PasscodeThemeError.network(error.localizedDescription)
        }

        let blocks = html.components(separatedBy: "class=\"theme-card-item\"").dropFirst()
        var themes: [PasscodeTheme] = []

        for block in blocks {
            guard let href = firstMatch("href=\"([^\"]+\\.html)\"", in: block) else { continue }
            let slug = href.replacingOccurrences(of: ".html", with: "")
            let title = firstMatch("<h3[^>]*>\\s*([^<]+?)\\s*</h3>", in: block)
                ?? firstMatch("alt=\"([^\"]*)\"", in: block)
                ?? slug
            let author = firstMatch(">\\s*@([^<]+?)\\s*<", in: block) ?? ""
            let category = firstMatch("data-category=\"([^\"]*)\"", in: block) ?? ""
            let summary = firstMatch("<p class=\"text-xs[^>]*>\\s*([^<]+?)\\s*</p>", in: block) ?? ""
            let img = firstMatch("<img src=\"([^\"]+)\"", in: block)

            themes.append(PasscodeTheme(
                slug: slug,
                title: decodeEntities(title),
                author: decodeEntities(author),
                category: decodeEntities(category),
                summary: decodeEntities(summary),
                previewURL: img.flatMap { URL(string: $0) },
                previewImageName: PasscodePreviewStore.bundledName(for: img),
                bundledPackageName: nil,
                downloadURL: nil,        // 该站点走光鸭网盘，无直链
                pageURL: legacyBaseURL.appendingPathComponent(href)
            ))
        }
        return themes
    }

    private static func firstMatch(_ pattern: String, in text: String, group: Int = 1) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let m = re.firstMatch(in: text, range: range),
              m.numberOfRanges > group,
              let r = Range(m.range(at: group), in: text) else { return nil }
        return String(text[r])
    }

    private static func decodeEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - 解包 / 写入

enum PasscodeThemeApplier {

    /// FFI 是阻塞调用：统一走专用串行队列
    private static let queue = DispatchQueue(label: "cc.cardart.workshop.passthm", qos: .userInitiated)

    // MARK: 环境

    static func environmentIssue() -> WriteErrorKind? {
        WriteEngine.shared.checkEnvironment()
    }

    // MARK: 解出 .passthm 里的按键图

    /// 取到本地 `.passthm`：内置包直接拷一份，否则联网下载
    static func download(theme: PasscodeTheme,
                         onProgress: ((Double) -> Void)? = nil) async throws -> URL {
        let dst = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(theme.slug).passthm")
        try? FileManager.default.removeItem(at: dst)

        // ① 内置包：离线、瞬时
        if let bundled = theme.bundledPackageName,
           let path = PasscodeThemeCatalog.bundledPackagePath(named: bundled) {
            try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: dst)
            onProgress?(1)
            return dst
        }

        // ② 远端直链
        guard let remote = theme.downloadURL else {
            throw PasscodeThemeError.network("该主题没有直链，请到来源页面下载后手动导入")
        }
        var req = URLRequest(url: remote)
        req.timeoutInterval = 60
        req.setValue("Vitrea/1.0 (iOS)", forHTTPHeaderField: "User-Agent")

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw PasscodeThemeError.network("下载失败 HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        guard !data.isEmpty else { throw PasscodeThemeError.network("下载到的主题包为空") }

        try data.write(to: dst, options: .atomic)
        onProgress?(1)
        return dst
    }

    /// 返回 数字 -> UIImage（0–9）
    static func extractDigits(from archive: URL) async throws -> [String: UIImage] {
        try await onQueue { try performExtract(archive: archive) }
    }

    private static func performExtract(archive: URL) throws -> [String: UIImage] {
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("passthm_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dest) }

        let rc = archive.path.withCString { src in
            dest.path.withCString { dst in
                al_passthm_extract(src, dst)
            }
        }
        guard rc == 0 else {
            throw PasscodeThemeError.ffi("解压主题包失败（错误码 \(rc)）")
        }

        let files = (try? FileManager.default.contentsOfDirectory(at: dest,
                                                                  includingPropertiesForKeys: nil)) ?? []
        var digits: [String: UIImage] = [:]
        for file in files {
            let ext = file.pathExtension.lowercased()
            guard ["png", "jpg", "jpeg"].contains(ext) else { continue }
            guard let digit = PasscodeKeypad.digit(fromFileName: file.lastPathComponent) else { continue }
            guard let image = UIImage(contentsOfFile: file.path) else { continue }
            // 同数字多文件时保留第一张（通常为 1x 原图）
            if digits[digit] == nil { digits[digit] = image }
        }
        guard !digits.isEmpty else { throw PasscodeThemeError.noImages }
        return digits
    }

    // MARK: 应用

    /// 把 10 张按键图写入设备。返回写入文件数。
    @discardableResult
    static func apply(digitImages: [String: UIImage],
                      telephonyVersion: String,
                      allLocales: Bool,
                      onLog: @escaping (String) -> Void) async throws -> Int {
        if let issue = environmentIssue() {
            throw (issue == .notPaired) ? PasscodeThemeError.notPaired : PasscodeThemeError.tunnelDown
        }

        let locales = allLocales ? PasscodeKeypad.allLocales : PasscodeKeypad.baseLocales
        let files = PasscodeKeypad.renderSet(digitImages: digitImages,
                                             locales: locales,
                                             includeBold: true)
        guard !files.isEmpty else { throw PasscodeThemeError.noImages }

        onLog("正在生成 \(files.count) 个按键资源…")

        return try await onQueue {
            let stage = FileManager.default.temporaryDirectory
                .appendingPathComponent("passthm_out_\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: stage) }

            for (name, data) in files {
                try? data.write(to: stage.appendingPathComponent(name))
            }

            let target = "/var/mobile/Library/Caches/\(telephonyVersion)"
            onLog("正在写入 \(target)…")

            syncHosts()
            let pairingPath = PairingController.pairingFilePath()
            var outError: UnsafeMutablePointer<CChar>?

            let rc = pairingPath.withCString { pairC in
                stage.path.withCString { srcC in
                    target.withCString { tgtC in
                        al_exploit_write_dir(pairC, srcC, tgtC, nil, nil, &outError)
                    }
                }
            }

            if let p = outError {
                let msg = String(cString: p)
                al_string_free(p)
                if rc != 0 { throw PasscodeThemeError.ffi(msg.isEmpty ? "写入失败" : msg) }
            }
            guard rc == 0 else { throw PasscodeThemeError.ffi("写入失败（错误码 \(rc)）") }

            onLog("写入完成，共 \(files.count) 个文件。")
            return files.count
        }
    }

    /// 触发一次 respring，让锁屏键盘立即刷新（可选）
    static func respring() async {
        _ = try? await onQueue {
            let pairingPath = PairingController.pairingFilePath()
            var outError: UnsafeMutablePointer<CChar>?
            _ = pairingPath.withCString { pairC in
                al_device_respring(pairC, nil, nil, &outError)
            }
            if let p = outError { al_string_free(p) }
        }
    }

    // MARK: - 内部

    private static func onQueue<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            queue.async {
                do { cont.resume(returning: try body()) }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    /// 与 WriteEngine 一致：同步隧道候选地址到 Rust 核心
    private static func syncHosts() {
        let deviceIP = "10.7.0.1"
        _ = deviceIP.withCString { al_set_target_host($0) }
        var candidates: [String] = [deviceIP]
        for cand in NetworkStatus.tunnelHostCandidates() where !candidates.contains(cand) {
            candidates.append(cand)
        }
        let cStrings = candidates.map { strdup($0) }
        defer { cStrings.forEach { free($0) } }
        var ptrs = cStrings.map { UnsafePointer($0) }
        ptrs.withUnsafeBufferPointer { buf in
            if let base = buf.baseAddress { _ = al_set_target_hosts(base, buf.count) }
        }
    }
}

// MARK: - 自定义主题持久化（保存用户上传的 10 张按键图）

enum PasscodeCustomStore {

    private static var dir: URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("passcode_custom", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func save(digitImages: [String: UIImage]) {
        for (digit, image) in digitImages {
            guard let data = image.pngData() else { continue }
            try? data.write(to: dir.appendingPathComponent("\(digit).png"))
        }
    }

    static func load() -> [String: UIImage] {
        var out: [String: UIImage] = [:]
        for digit in PasscodeKeypad.digits {
            let url = dir.appendingPathComponent("\(digit).png")
            if let image = UIImage(contentsOfFile: url.path) { out[digit] = image }
        }
        return out
    }

    static func clear() {
        try? FileManager.default.removeItem(at: dir)
    }
}
