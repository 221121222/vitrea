//
//  SVGRenderer.swift
//  Vitrea
//
//  素材库（cardart.cc/maker）现在是纯 SVG，iOS 原生 UIImage 不认矢量数据，
//  这里用 CoreGraphics 直接把 SVG 栅格化成位图，保证素材仍然全在线加载。
//  覆盖站点素材实际用到的子集：svg / g / path、viewBox、transform、fill、fill-rule。
//

import UIKit
import CoreGraphics

enum SVGRenderer {

    /// 把 SVG 数据栅格化成 UIImage。targetWidth 为输出宽度，高度按 viewBox 比例推算。
    static func image(from data: Data, targetWidth: CGFloat = 512) -> UIImage? {
        let parser = SVGParser()
        let xml = XMLParser(data: data)
        xml.delegate = parser
        guard xml.parse(), let doc = parser.document else { return nil }
        return render(doc, targetWidth: targetWidth)
    }

    // MARK: - 渲染

    private static func render(_ doc: SVGDocument, targetWidth: CGFloat) -> UIImage? {
        let vb = doc.viewBox
        guard vb.width > 0, vb.height > 0, !doc.shapes.isEmpty else { return nil }

        let scale = targetWidth / vb.width
        let size = CGSize(width: max(1, round(vb.width * scale)),
                          height: max(1, round(vb.height * scale)))

        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.opaque = false

        let renderer = UIGraphicsImageRenderer(size: size, format: fmt)
        return renderer.image { ctx in
            // SVG 用户坐标与 UIKit 坐标同为 y 向下，只需平移 + 缩放，无需翻转
            ctx.cgContext.translateBy(x: -vb.minX * scale, y: -vb.minY * scale)
            ctx.cgContext.scaleBy(x: scale, y: scale)

            for shape in doc.shapes {
                guard let color = shape.color else { continue }
                ctx.cgContext.saveGState()
                ctx.cgContext.concatenate(shape.transform)
                ctx.cgContext.addPath(shape.path)
                ctx.cgContext.restoreGState()
                ctx.cgContext.setFillColor(color.cgColor)
                ctx.cgContext.fillPath(using: shape.rule)
            }
        }
    }
}

// MARK: - 文档模型

private struct SVGShape {
    let path: CGPath
    let color: UIColor?
    let rule: CGPathFillRule
    let transform: CGAffineTransform
}

private struct SVGDocument {
    var viewBox: CGRect = .zero
    var shapes: [SVGShape] = []
}

// MARK: - XML 解析

private final class SVGParser: NSObject, XMLParserDelegate {
    private(set) var document: SVGDocument?

    private var doc = SVGDocument()
    private var transformStack: [CGAffineTransform] = [.identity]
    private var transform = CGAffineTransform.identity
    private var rootDone = false
    private var failed = false

    func parser(_ parser: XMLParser, parseErrorOccurred error: Error) { failed = true }

    func parser(_ parser: XMLParser, didStartElement name: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes: [String: String] = [:]) {
        switch name {
        case "svg":
            // 根 svg：确定最终 viewBox
            if !rootDone {
                let vb = parseViewBox(attributes["viewBox"])
                let w = parseLength(attributes["width"])
                let h = parseLength(attributes["height"])
                if let vb { doc.viewBox = vb }
                else if let w, let h { doc.viewBox = CGRect(x: 0, y: 0, width: w, height: h) }
                rootDone = true
            } else if let vb = parseViewBox(attributes["viewBox"]) {
                // 嵌套 svg：把自身 viewBox 映射到父坐标（x/y/width/height + transform）
                let w = parseLength(attributes["width"]) ?? vb.width
                let h = parseLength(attributes["height"]) ?? vb.height
                let sx = vb.width > 0 ? w / vb.width : 1
                let sy = vb.height > 0 ? h / vb.height : 1
                let x = parseLength(attributes["x"]) ?? 0
                let y = parseLength(attributes["y"]) ?? 0
                var t = CGAffineTransform(translationX: x, y: y)
                t = t.scaledBy(x: sx, y: sy)
                t = t.translatedBy(x: -vb.minX, y: -vb.minY)
                transformStack.append(transform)
                transform = transform.concatenating(t)
            }
            if let tr = attributes["transform"] { transform = transform.concatenating(parseTransform(tr)) }

        case "g":
            transformStack.append(transform)
            if let tr = attributes["transform"] { transform = transform.concatenating(parseTransform(tr)) }

        case "path":
            guard let d = attributes["d"], let path = SVGPathBuilder.build(d) else { break }
            let color = parseColor(attributes["fill"]) ?? .black
            let rule: CGPathFillRule = attributes["fill-rule"] == "evenodd" ? .evenOdd : .winding
            let t = attributes["transform"].map { transform.concatenating(parseTransform($0)) } ?? transform
            doc.shapes.append(SVGShape(path: path, color: color, rule: rule, transform: t))

        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        if name == "svg" || name == "g" {
            transform = transformStack.popLast() ?? .identity
        }
    }

    func parserDidEndDocument(_ parser: XMLParser) {
        if !failed { document = doc }
    }

    // MARK: 属性

    private func parseViewBox(_ raw: String?) -> CGRect? {
        guard let raw else { return nil }
        let nums = raw.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0) }
        guard nums.count == 4 else { return nil }
        return CGRect(x: nums[0], y: nums[1], width: nums[2], height: nums[3])
    }

    private func parseLength(_ raw: String?) -> CGFloat? {
        guard var s = raw?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        for unit in ["px", "pt", "em"] where s.hasSuffix(unit) { s = String(s.dropLast(unit.count)) }
        return Double(s).map { CGFloat($0) }
    }

    private func parseColor(_ raw: String?) -> UIColor? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if raw == "none" { return nil }
        if raw.hasPrefix("#") { return UIColor(hexCSS: raw) }
        switch raw {
        case "black": return .black
        case "white": return .white
        case "red": return .red
        case "gray", "grey": return .gray
        default: return .black
        }
    }

    private func parseTransform(_ raw: String) -> CGAffineTransform {
        var result = CGAffineTransform.identity
        let pattern = "(matrix|translate|scale|rotate|skewX|skewY)\\s*\\(([^)]*)\\)"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return result }
        let range = NSRange(raw.startIndex..., in: raw)
        for m in re.matches(in: raw, range: range) {
            guard let nameRange = Range(m.range(at: 1), in: raw),
                  let argRange = Range(m.range(at: 2), in: raw) else { continue }
            let name = String(raw[nameRange])
            let args = raw[argRange]
                .split(whereSeparator: { $0 == " " || $0 == "," })
                .compactMap { Double($0) }
            switch name {
            case "matrix" where args.count == 6:
                result = result.concatenating(CGAffineTransform(a: CGFloat(args[0]), b: CGFloat(args[1]),
                                                                c: CGFloat(args[2]), d: CGFloat(args[3]),
                                                                tx: CGFloat(args[4]), ty: CGFloat(args[5])))
            case "translate":
                let tx = args.count > 0 ? CGFloat(args[0]) : 0
                let ty = args.count > 1 ? CGFloat(args[1]) : 0
                result = result.translatedBy(x: tx, y: ty)
            case "scale":
                let sx = args.count > 0 ? CGFloat(args[0]) : 1
                let sy = args.count > 1 ? CGFloat(args[1]) : sx
                result = result.scaledBy(x: sx, y: sy)
            case "rotate":
                let a = args.count > 0 ? CGFloat(args[0]) : 0
                if args.count == 3 {
                    let cx = CGFloat(args[1]), cy = CGFloat(args[2])
                    result = result.translatedBy(x: cx, y: cy)
                        .rotated(by: a * .pi / 180)
                        .translatedBy(x: -cx, y: -cy)
                } else {
                    result = result.rotated(by: a * .pi / 180)
                }
            case "skewX" where args.count == 1:
                result = result.concatenating(CGAffineTransform(a: 1, b: 0,
                                                                c: tan(CGFloat(args[0]) * .pi / 180),
                                                                d: 1, tx: 0, ty: 0))
            case "skewY" where args.count == 1:
                result = result.concatenating(CGAffineTransform(a: 1, b: tan(CGFloat(args[0]) * .pi / 180),
                                                                c: 0, d: 1, tx: 0, ty: 0))
            default:
                break
            }
        }
        return result
    }
}

// MARK: - path d 解析

private struct SVGPathBuilder {

    private enum Command {
        case move, line, horizontal, vertical, cubic, smoothCubic,
             quadratic, smoothQuadratic, arc, close

        init?(_ c: Character) {
            switch c.uppercased().first {
            case "M": self = .move
            case "L": self = .line
            case "H": self = .horizontal
            case "V": self = .vertical
            case "C": self = .cubic
            case "S": self = .smoothCubic
            case "Q": self = .quadratic
            case "T": self = .smoothQuadratic
            case "A": self = .arc
            case "Z": self = .close
            default: return nil
            }
        }
    }

    // MARK: 状态

    private var tokens: [String] = []
    private var index = 0
    private var current = CGPoint.zero
    private var start = CGPoint.zero
    private var lastControl: CGPoint?
    private var lastCommand: Character = "M"
    private var valid = false
    private var path = CGMutablePath()

    static func build(_ d: String) -> CGPath? {
        var b = SVGPathBuilder()
        b.tokens = SVGPathBuilder.tokenize(d)
        b.run()
        return b.valid ? b.path : nil
    }

    private mutating func run() {
        while index < tokens.count {
            let raw = tokens[index]
            guard let first = raw.first, first.isLetter else {
                // 隐含重复上一条命令（M 之后按 L 处理）
                let repeatCmd: Character = (lastCommand == "M" || lastCommand == "m") ? "L" : lastCommand
                guard let cmd = Command(repeatCmd) else { index += 1; continue }
                if !apply(cmd, isRelative: repeatCmd.isLowercase) { index += 1; continue }
                continue
            }
            index += 1
            guard let cmd = Command(first) else { continue }
            if !apply(cmd, isRelative: first.isLowercase) { continue }
            lastCommand = first
        }
    }

    private mutating func nextNumber() -> CGFloat? {
        while index < tokens.count {
            let t = tokens[index]
            index += 1
            if let v = Double(t) { return CGFloat(v) }
        }
        return nil
    }

    private mutating func point(isRelative: Bool) -> CGPoint? {
        guard let x = nextNumber(), let y = nextNumber() else { return nil }
        return isRelative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
    }

    private func hasMoreNumbers() -> Bool {
        index < tokens.count && Double(tokens[index]) != nil
    }

    private mutating func apply(_ cmd: Command, isRelative: Bool) -> Bool {
        switch cmd {
        case .move:
            guard let p = point(isRelative: isRelative) else { return false }
            current = p; start = p; lastControl = nil
            path.move(to: p)
            while hasMoreNumbers(), let extra = point(isRelative: isRelative) {
                current = extra; path.addLine(to: extra)
            }
            valid = true
        case .line:
            guard let p = point(isRelative: isRelative) else { return false }
            current = p; lastControl = nil; path.addLine(to: p)
            while hasMoreNumbers(), let extra = point(isRelative: isRelative) {
                current = extra; path.addLine(to: extra)
            }
            valid = true
        case .horizontal:
            guard let x = nextNumber() else { return false }
            current = CGPoint(x: isRelative ? current.x + x : x, y: current.y)
            lastControl = nil; path.addLine(to: current)
            while hasMoreNumbers(), let nx = nextNumber() {
                current = CGPoint(x: isRelative ? current.x + nx : nx, y: current.y)
                path.addLine(to: current)
            }
            valid = true
        case .vertical:
            guard let y = nextNumber() else { return false }
            current = CGPoint(x: current.x, y: isRelative ? current.y + y : y)
            lastControl = nil; path.addLine(to: current)
            while hasMoreNumbers(), let ny = nextNumber() {
                current = CGPoint(x: current.x, y: isRelative ? current.y + ny : ny)
                path.addLine(to: current)
            }
            valid = true
        case .cubic:
            guard let c1 = point(isRelative: isRelative),
                  let c2 = point(isRelative: isRelative),
                  let p = point(isRelative: isRelative) else { return false }
            path.addCurve(to: p, control1: c1, control2: c2)
            lastControl = c2; current = p
            while hasMoreNumbers(),
                  let a1 = point(isRelative: isRelative),
                  let a2 = point(isRelative: isRelative),
                  let ap = point(isRelative: isRelative) {
                path.addCurve(to: ap, control1: a1, control2: a2)
                lastControl = a2; current = ap
            }
            valid = true
        case .smoothCubic:
            guard let c2 = point(isRelative: isRelative),
                  let p = point(isRelative: isRelative) else { return false }
            let c1 = lastControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
            path.addCurve(to: p, control1: c1, control2: c2)
            lastControl = c2; current = p
            while hasMoreNumbers(),
                  let a2 = point(isRelative: isRelative),
                  let ap = point(isRelative: isRelative) {
                let a1 = CGPoint(x: 2 * current.x - a2.x, y: 2 * current.y - a2.y)
                path.addCurve(to: ap, control1: a1, control2: a2)
                lastControl = a2; current = ap
            }
            valid = true
        case .quadratic:
            guard let c = point(isRelative: isRelative),
                  let p = point(isRelative: isRelative) else { return false }
            path.addQuadCurve(to: p, control: c)
            lastControl = c; current = p
            while hasMoreNumbers(),
                  let ac = point(isRelative: isRelative),
                  let ap = point(isRelative: isRelative) {
                path.addQuadCurve(to: ap, control: ac)
                lastControl = ac; current = ap
            }
            valid = true
        case .smoothQuadratic:
            guard let p = point(isRelative: isRelative) else { return false }
            let c = lastControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
            path.addQuadCurve(to: p, control: c)
            lastControl = c; current = p
            while hasMoreNumbers(), let ap = point(isRelative: isRelative) {
                let ac = CGPoint(x: 2 * current.x - ap.x, y: 2 * current.y - ap.y)
                path.addQuadCurve(to: ap, control: ac)
                lastControl = ac; current = ap
            }
            valid = true
        case .arc:
            // 站点素材不使用圆弧命令，退化为直线，避免整条路径失效
            _ = nextNumber(); _ = nextNumber(); _ = nextNumber()
            _ = nextNumber(); _ = nextNumber()
            guard let p = point(isRelative: isRelative) else { return false }
            path.addLine(to: p)
            current = p; lastControl = nil
            valid = true
        case .close:
            path.closeSubpath()
            current = start; lastControl = nil
            valid = true
        }
        return true
    }

    /// 拆成命令字母与数字（支持省略空格、负号、科学计数法）
    private static func tokenize(_ d: String) -> [String] {
        var tokens: [String] = []
        var buf = ""
        let scalars = Array(d)
        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            if c.isLetter {
                if !buf.isEmpty { tokens.append(buf); buf = "" }
                tokens.append(String(c))
                i += 1
                continue
            }
            if c == "-" || c == "+" || c == "." || c.isNumber || c == "e" || c == "E" {
                // 负号/正号作为新数字起点
                if (c == "-" || c == "+") && !buf.isEmpty && !buf.hasSuffix("e") && !buf.hasSuffix("E") {
                    tokens.append(buf); buf = ""
                }
                buf.append(c)
                i += 1
                continue
            }
            if !buf.isEmpty { tokens.append(buf); buf = "" }
            i += 1
        }
        if !buf.isEmpty { tokens.append(buf) }
        return tokens
    }
}

// MARK: - 颜色

private extension UIColor {
    convenience init(hexCSS raw: String) {
        var s = raw.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if s.count == 3 {
            s = s.map { "\($0)\($0)" }.joined()
        }
        if s.count == 6 { s += "FF" }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        self.init(red: CGFloat((v >> 24) & 0xFF) / 255,
                  green: CGFloat((v >> 16) & 0xFF) / 255,
                  blue: CGFloat((v >> 8) & 0xFF) / 255,
                  alpha: CGFloat(v & 0xFF) / 255)
    }
}
