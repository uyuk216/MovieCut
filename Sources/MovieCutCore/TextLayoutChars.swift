import Foundation
import CoreText
import CoreGraphics

// 縦書きと、1 文字ずつ動かす文字のための「文字ごとの配置」。
// どちらも、字形の輪郭を 1 文字ずつ取り出して並べる(影・グラデーション・縁は、横書きと同じ `Renderer.paintLine` で塗る)。

/// 配置済みの 1 文字。座標は y 上向き。`path` と `center` は `origin`(描くときに ctx を移す点)からの相対。
struct PlacedChar {
    /// 字形の輪郭。絵文字などカラー字形は輪郭が無く、空になる。
    var path: CGPath
    /// 動きの中心(拡大の基準)。
    var center: CGPoint
    /// 改行を除いた通し番号。
    var index: Int
}

/// 縦書きの文字配置(CoreText の縦書き用字形 `kCTVerticalFormsAttributeName` を使う)。
/// 列は右から左へ、列の中は上から下へ。句読点・かぎ括弧・長音・波ダッシュなどは縦書き用の字形に置き換わる。
/// 半角の英数字は読みやすいよう横向きのまま、1 文字ずつ升目の中央に置く。
enum VerticalText {
    struct Layout {
        var chars: [PlacedChar]
        /// 全体の枠(列の数 × 列の幅、一番長い列 × 1 文字の高さ)。
        var width: Double
        var height: Double
        var columnCount: Int
    }

    /// 横向きのまま置く文字(半角の英数字)。
    static func isUpright(_ ch: Swift.Character) -> Bool {
        guard ch.unicodeScalars.count == 1, let u = ch.unicodeScalars.first else { return false }
        return u.isASCII && (u.properties.isAlphabetic || (u.value >= 0x30 && u.value <= 0x39))
    }

    /// 全体の大きさだけ(字形を作らない)。`text` は改行で列に分ける。
    static func blockSize(_ text: String, size: Double, spacing: Double, lineHeight: Double) -> CGSize {
        let cols = text.components(separatedBy: "\n")
        let longest = cols.map(\.count).max() ?? 0
        let cell = size + spacing
        let h = longest > 0 ? Double(longest) * cell - spacing : 0
        return CGSize(width: Double(cols.count) * size * lineHeight, height: h)
    }

    /// 列は右端から数える(最初の行 = いちばん右の列)。枠の中心が原点。
    static func layout(_ text: String, font f: TextFont, size: Double, spacing: Double, lineHeight: Double, align: TextStyle.Align) -> Layout {
        let cols = text.components(separatedBy: "\n")
        let pitch = size * lineHeight
        let cell = size + spacing
        let blockW = Double(cols.count) * pitch
        let longest = cols.map(\.count).max() ?? 0
        let blockH = longest > 0 ? Double(longest) * cell - spacing : 0
        var out: [PlacedChar] = []
        var index = 0
        for (j, col) in cols.enumerated() {
            let chars = Array(col)
            let colH = chars.isEmpty ? 0 : Double(chars.count) * cell - spacing
            let cx = blockW / 2 - pitch * (Double(j) + 0.5)
            // 画面の上端(y 下向き)から数えた、列の先頭の位置
            let top: Double
            switch align {
            case .left: top = -blockH / 2
            case .center: top = -colH / 2
            case .right: top = blockH / 2 - colH
            }
            for (k, ch) in chars.enumerated() {
                defer { index += 1 }
                // 升目の中心(y 上向きに直す)
                let cyDown = top + cell * Double(k) + size / 2
                let cy = -cyDown
                let g = glyph(ch, font: f, size: size)
                guard !g.path.isEmpty else {
                    out.append(PlacedChar(path: CGMutablePath(), center: CGPoint(x: cx, y: cy), index: index))
                    continue
                }
                let t: CGAffineTransform
                if g.upright {
                    // 横向きの字形: 横は字の幅の中央、縦は「middle」の基準線(横書きと同じ)
                    t = CGAffineTransform(translationX: CGFloat(cx - g.advance / 2), y: CGFloat(cy - (f.ascent - f.descent) / 2))
                } else {
                    // 縦書き用の字形は、升目の上辺の中央が原点
                    t = CGAffineTransform(translationX: CGFloat(cx), y: CGFloat(cy + size / 2))
                }
                var tt = t
                let p = g.path.copy(using: &tt) ?? g.path
                out.append(PlacedChar(path: p, center: CGPoint(x: cx, y: cy), index: index))
            }
        }
        return Layout(chars: out, width: blockW, height: blockH, columnCount: cols.count)
    }

    // MARK: 字形のキャッシュ

    private static let lock = NSLock()
    private static var cache: [String: (path: CGPath, upright: Bool, advance: Double)] = [:]

    static func glyph(_ ch: Swift.Character, font f: TextFont, size: Double) -> (path: CGPath, upright: Bool, advance: Double) {
        let key = "\(CTFontCopyPostScriptName(f.ct) as String)|\(size)|\(f.regular ? "r" : "b")|\(ch)"
        lock.lock()
        if let g = cache[key] { lock.unlock(); return g }
        lock.unlock()
        let upright = isUpright(ch)
        let r = f.singleCharPath(String(ch), vertical: !upright)
        let g = (path: r.path as CGPath, upright: upright, advance: r.advance)
        lock.lock()
        if cache.count > 1024 { cache.removeAll() }
        cache[key] = g
        lock.unlock()
        return g
    }
}

extension TextFont {
    /// 1 文字の輪郭。`vertical` なら縦書き用の字形(原点は升目の上辺の中央)。横向きなら原点は基準線の左端。
    func singleCharPath(_ s: String, vertical: Bool) -> (path: CGPath, advance: Double) {
        var attrs: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): ct]
        if vertical { attrs[NSAttributedString.Key(kCTVerticalFormsAttributeName as String)] = true }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
        let path = CGMutablePath()
        for run in (CTLineGetGlyphRuns(line) as? [CTRun]) ?? [] {
            let n = CTRunGetGlyphCount(run)
            guard n > 0 else { continue }
            let rf = ((CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName as String] as! CTFont?) ?? ct
            var glyphs = [CGGlyph](repeating: 0, count: n)
            var pos = [CGPoint](repeating: .zero, count: n)
            CTRunGetGlyphs(run, CFRange(location: 0, length: n), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: n), &pos)
            for i in 0..<n {
                if let gp = CTFontCreatePathForGlyph(rf, glyphs[i], nil) {
                    path.addPath(gp, transform: CGAffineTransform(translationX: pos[i].x, y: pos[i].y))
                }
            }
        }
        return (path, CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    /// 横書き 1 行を、文字(Character)ごとの輪郭に分ける。原点 = 基準線の左端、y 上向き。
    /// 字間・斜体は `layout` と同じ。戻りの幅も `layout` と同じ(行末の字間を引く)。
    func perCharLayout(_ s: String, spacing: Double = 0, italic: Bool = false) -> (chars: [CGPath], width: Double) {
        let attr = NSAttributedString(string: s, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): ct, NSAttributedString.Key(kCTKernAttributeName as String): spacing])
        let line = CTLineCreateWithAttributedString(attr)
        // UTF-16 の位置 → 何文字目か
        var charOf: [Int] = []
        for (i, ch) in s.enumerated() { charOf.append(contentsOf: Array(repeating: i, count: String(ch).utf16.count)) }
        let parts = (0..<s.count).map { _ in CGMutablePath() }
        for run in (CTLineGetGlyphRuns(line) as? [CTRun]) ?? [] {
            let n = CTRunGetGlyphCount(run)
            guard n > 0 else { continue }
            let rf = ((CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName as String] as! CTFont?) ?? ct
            var glyphs = [CGGlyph](repeating: 0, count: n)
            var pos = [CGPoint](repeating: .zero, count: n)
            var idx = [CFIndex](repeating: 0, count: n)
            CTRunGetGlyphs(run, CFRange(location: 0, length: n), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: n), &pos)
            CTRunGetStringIndices(run, CFRange(location: 0, length: n), &idx)
            for i in 0..<n {
                guard idx[i] >= 0, idx[i] < charOf.count, let gp = CTFontCreatePathForGlyph(rf, glyphs[i], nil) else { continue }
                parts[charOf[idx[i]]].addPath(gp, transform: CGAffineTransform(translationX: pos[i].x, y: pos[i].y))
            }
        }
        var w = CTLineGetTypographicBounds(line, nil, nil, nil)
        if spacing != 0, !s.isEmpty { w -= spacing }
        var out: [CGPath] = parts
        if italic {
            var shear = CGAffineTransform(a: 1, b: 0, c: CGFloat(tan(12.0 * .pi / 180)), d: 1, tx: 0, ty: 0)
            out = parts.map { $0.copy(using: &shear) ?? $0 }
        }
        return (out, w)
    }
}
