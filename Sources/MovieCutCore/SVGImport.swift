import Foundation
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - SVG の読み込み(#4)
//
// SVG ファイルを画像素材として取り込む。ベクターのままの編集はしない: 指定解像度で
// ラスタライズした PNG をキャッシュに書き出し、通常の画像クリップとして置く(PSD の取り込みと同じ流儀)。
//
// ラスタライズの経路(2026-11-19 に macOS 27.3 で実測):
//   - ImageIO(CGImageSource): SVG は数 0 で読めない。
//   - PDFKit(PDFDocument): SVG は開けない。
//   - AppKit の NSImage: _NSSVGImageRep が SVG を保持し、任意の大きさで CGImage 化できる。
// 外部依存は増やさず、この NSImage 経路を使う。

/// SVG の viewBox。
public struct SVGViewBox: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

/// SVG の寸法情報(ルート要素の width / height / viewBox から読む。純粋な値)。
public struct SVGInfo: Equatable, Sendable {
    /// ルートの width(絶対単位を px に直したもの。% や auto は nil)。
    public var width: Double?
    /// ルートの height(同上)。
    public var height: Double?
    public var viewBox: SVGViewBox?

    public init(width: Double? = nil, height: Double? = nil, viewBox: SVGViewBox? = nil) {
        self.width = width; self.height = height; self.viewBox = viewBox
    }

    /// 素材本来の大きさ(px)。width・height が両方あればそれ、無ければ viewBox の大きさ、
    /// 片方だけなら viewBox の縦横比で補う。どれも決まらなければ nil。
    public var intrinsicSize: CGSize? {
        if let w = width, let h = height, w > 0, h > 0 { return CGSize(width: w, height: h) }
        if let vb = viewBox, vb.width > 0, vb.height > 0 {
            if let w = width, w > 0 { return CGSize(width: w, height: w * vb.height / vb.width) }
            if let h = height, h > 0 { return CGSize(width: h * vb.width / vb.height, height: h) }
            return CGSize(width: vb.width, height: vb.height)
        }
        return nil
    }
}

public enum SVGError: Error, Equatable, CustomStringConvertible {
    case notSVG
    case unreadable
    case rasterizeFailed

    public var description: String {
        switch self {
        case .notSVG: return "SVG として読み取れませんでした"
        case .unreadable: return "ファイルを開けませんでした"
        case .rasterizeFailed: return "画像化できませんでした"
        }
    }
}

public enum SVGParser {
    /// SVG のテキストから寸法を読む。ルート要素が <svg でなければ nil。
    public static func parseInfo(_ text: String) -> SVGInfo? {
        guard let tag = rootTag(text) else { return nil }
        let attrs = attributes(tag)
        return SVGInfo(width: attrs["width"].flatMap { length($0) },
                       height: attrs["height"].flatMap { length($0) },
                       viewBox: attrs["viewbox"].flatMap { viewBox($0) })
    }

    /// ファイルから寸法を読む(開けない・SVG でなければ nil)。
    public static func info(atPath path: String) -> SVGInfo? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else { return nil }
        return parseInfo(text)
    }

    /// `<svg ...>` の開始タグ全体(属性の中の `>` は引用符内として扱う)。無ければ nil。
    static func rootTag(_ text: String) -> String? {
        var search = text[...]
        // XML 宣言・コメント・DOCTYPE を飛ばして最初の要素を探す
        while let lt = search.firstIndex(of: "<") {
            let rest = search[lt...]
            if rest.hasPrefix("<!--") {
                guard let end = rest.range(of: "-->") else { return nil }
                search = rest[end.upperBound...]
                continue
            }
            if rest.hasPrefix("<?") {
                guard let end = rest.range(of: "?>") else { return nil }
                search = rest[end.upperBound...]
                continue
            }
            if rest.hasPrefix("<!") {
                guard let end = rest.firstIndex(of: ">") else { return nil }
                search = rest[rest.index(after: end)...]
                continue
            }
            // 最初の要素タグ
            let nameEnd = rest.dropFirst().firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" || $0 == ">" || $0 == "/" }) ?? rest.endIndex
            let name = rest[rest.index(after: rest.startIndex)..<nameEnd].lowercased()
            guard name == "svg" else { return nil }
            // 引用符を意識しながら閉じ `>` まで取る
            var i = rest.startIndex
            var quote: Swift.Character? = nil
            while i < rest.endIndex {
                let ch = rest[i]
                if let q = quote { if ch == q { quote = nil } }
                else if ch == "\"" || ch == "'" { quote = ch }
                else if ch == ">" { return String(rest[...i]) }
                i = rest.index(after: i)
            }
            return nil
        }
        return nil
    }

    /// 開始タグの属性(名前は小文字化、値は引用符を外す)。
    static func attributes(_ tag: String) -> [String: String] {
        var out: [String: String] = [:]
        var s = tag.dropFirst()   // "<" を落とす
        // 要素名を落とす
        if let i = s.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" || $0 == ">" || $0 == "/" }) { s = s[i...] }
        while let eq = s.firstIndex(of: "=") {
            let rawName = s[..<eq].split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }).last.map(String.init) ?? ""
            var rest = s[s.index(after: eq)...]
            while rest.first == " " || rest.first == "\t" || rest.first == "\n" || rest.first == "\r" { rest = rest.dropFirst() }
            guard let q = rest.first, q == "\"" || q == "'" else { s = rest; continue }
            rest = rest.dropFirst()
            guard let end = rest.firstIndex(of: q) else { break }
            if !rawName.isEmpty { out[rawName.lowercased()] = String(rest[..<end]) }
            s = rest[rest.index(after: end)...]
        }
        return out
    }

    /// 長さの文字列 → px(96dpi 換算)。%・auto・単位なし以外の不明なものは nil、単位なしは px 扱い。
    static func length(_ raw: String) -> Double? {
        let t = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !t.isEmpty, t != "auto", !t.hasSuffix("%") else { return nil }
        let units: [(String, Double)] = [("px", 1), ("pt", 96.0 / 72), ("pc", 16), ("in", 96), ("cm", 96 / 2.54), ("mm", 96 / 25.4)]
        for (u, k) in units where t.hasSuffix(u) {
            guard let v = Double(t.dropLast(u.count)), v.isFinite, v > 0 else { return nil }
            return v * k
        }
        guard let v = Double(t), v.isFinite, v > 0 else { return nil }
        return v
    }

    /// viewBox の文字列(空白・カンマ区切りの 4 数)。
    static func viewBox(_ raw: String) -> SVGViewBox? {
        let parts = raw.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" || $0 == "," }).map { Double($0) }
        guard parts.count == 4, let x = parts[0], let y = parts[1], let w = parts[2], let h = parts[3],
              w > 0, h > 0 else { return nil }
        return SVGViewBox(x: x, y: y, width: w, height: h)
    }
}

public enum SVGImporter {
    /// ラスタライズの既定の上限(長い辺の px)。本来の大きさがこれを超えるときだけ縮める。
    public static let defaultMaxPixel = 2048
    /// 大きさが読めない SVG の既定の描画サイズ。
    public static let fallbackSize = CGSize(width: 512, height: 512)

    public static func isSVG(path: String) -> Bool {
        (path as NSString).pathExtension.lowercased() == "svg"
    }

    /// 本来の大きさを、長い辺が `maxPixel` 以下になるよう収めた描画サイズ(拡大はしない)。
    /// 大きさが読めなければ `fallbackSize`。
    public static func defaultPixelSize(info: SVGInfo, maxPixel: Int = defaultMaxPixel) -> CGSize {
        guard let s = info.intrinsicSize else { return fallbackSize }
        let longest = max(s.width, s.height)
        let k = longest > Double(maxPixel) ? Double(maxPixel) / longest : 1
        return CGSize(width: max(1, (s.width * k).rounded()), height: max(1, (s.height * k).rounded()))
    }

    /// 本来の大きさを `maxWidth` × `maxHeight` の枠に収めた描画サイズ(縦横比は保つ。拡大もする)。
    /// 大きさが読めなければ枠そのもの。
    public static func fittedPixelSize(info: SVGInfo, maxWidth: Int, maxHeight: Int) -> CGSize {
        guard maxWidth > 0, maxHeight > 0 else { return fallbackSize }
        guard let s = info.intrinsicSize else { return CGSize(width: maxWidth, height: maxHeight) }
        let k = min(Double(maxWidth) / s.width, Double(maxHeight) / s.height)
        return CGSize(width: max(1, (s.width * k).rounded()), height: max(1, (s.height * k).rounded()))
    }

    /// SVG を `pixelWidth` × `pixelHeight` でラスタライズする(NSImage の SVG 表現を使う)。
    /// 読めない・SVG でない・描けないときは nil。
    public static func rasterize(atPath path: String, pixelWidth: Int, pixelHeight: Int) -> CGImage? {
        guard pixelWidth > 0, pixelHeight > 0,
              let image = NSImage(contentsOfFile: path) else { return nil }
        // SVG の寸法を持たない(読めない)ファイルは NSImage でも大きさ 0 になる
        guard image.size.width > 0, image.size.height > 0 else { return nil }
        image.size = NSSize(width: pixelWidth, height: pixelHeight)
        var rect = NSRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: [.interpolation: NSImageInterpolation.high])
    }

    /// ラスタライズ結果を PNG にする。
    public static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    /// キャッシュフォルダの名前(PSD と同じ決め方 + 描画サイズ。同じファイル・同じ大きさなら同じ)。
    public static func cacheKey(path: String, modified: Date?, size: Int64?, pixelWidth: Int, pixelHeight: Int) -> String {
        PSDImporter.cacheKey(path: path, modified: modified, size: size) + "-\(pixelWidth)x\(pixelHeight)"
    }

    /// SVG を PNG にラスタライズして `cacheDir` へ書き、そのパスを返す。すでにあれば作り直さない。
    @discardableResult
    public static func prepare(atPath path: String, pixelWidth: Int, pixelHeight: Int, cacheDir: URL) throws -> String {
        let fm = FileManager.default
        let url = cacheDir.appendingPathComponent("image.png")
        if let a = try? fm.attributesOfItem(atPath: url.path), (a[.size] as? NSNumber)?.intValue ?? 0 > 0 { return url.path }
        guard SVGParser.info(atPath: path) != nil else { throw SVGError.notSVG }
        guard let img = rasterize(atPath: path, pixelWidth: pixelWidth, pixelHeight: pixelHeight) else { throw SVGError.rasterizeFailed }
        guard let data = pngData(img) else { throw SVGError.rasterizeFailed }
        try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return url.path
    }

    /// PNG 化した SVG を画像クリップとして置く(置き方は `ClipEditing.place` と同じ)。置いたクリップの id を返す。
    @discardableResult
    public static func place(pngPath: String, at start: Double, duration: Double = ClipEditing.defaultMediaDuration,
                             in project: inout Project) -> [String] {
        ClipEditing.place(media: [(path: pngPath, kind: .image, duration: duration)], at: start, in: &project)
    }
}
