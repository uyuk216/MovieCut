import Foundation
import CoreText
import CoreGraphics

// 文字制御タグ(装飾タグ)の描画。タグのあるテキストだけがこの経路を通る。
// タグの無いテキストは従来の `Renderer.drawText` の経路のままで、描画結果は変わらない。
//
// 描き方の考え方は横書きの通常経路と同じ(字形の輪郭を `paintLine` で塗る)が、
// 行の中でフォント・サイズ・色が変わるため、行を文字単位に配置してから
// 同じ塗りのまとまりごとに塗る。ビットマップキャッシュは使わず直接描く。

extension TextMarkup {
    /// タグがあるときだけプレーンな文を返す(アニメーションの文字数え用)。タグが無ければ入力そのまま。
    public static func plainIfTagged(_ text: String, baseSize: Double, baseLetterSpacing: Double) -> String {
        guard mightContainTags(text) else { return text }
        let p = parse(text, baseSize: baseSize, baseLetterSpacing: baseLetterSpacing)
        return p.hasTags ? p.plain : text
    }
}

/// 配置済みの 1 文字(行の左端・基準線が原点、y 上向き)。
struct StyledCharGeom {
    var x: Double
    var advance: Double
    var path: CGPath
    var font: TextFont
    var size: Double
}

struct StyledLineGeom {
    var chars: [StyledCharGeom]
    /// 行の文字の全域インデックス(プレーン全体の通し番号。改行も数える)。
    var startIndex: Int
    var width: Double
    var maxSize: Double
    var pitch: Double
}

extension Renderer {
    /// マークアップのルビと、クリップのルビ(プレーンに対して解決したもの)を合わせる。
    static func mergedRubies(_ parsed: MarkupParsed, clipRuby: [RubySpan]) -> [MarkupRuby] {
        var out = parsed.rubies
        out += RubyText.resolve(clipRuby, in: parsed.plain).map {
            MarkupRuby(start: $0.start, end: $0.end, reading: $0.reading)
        }
        return out.sorted { $0.start < $1.start }
    }

    /// 縦書きでルビを出すときの実効の行間(列ピッチ)。ルビの分だけ列を広げる。
    /// 描画(`drawTextChars`)と枠の計測(`textBlockSize`)で必ず同じ値を使う。
    static func verticalEffectiveLineHeight(_ style: TextStyle?, rubies: [MarkupRuby]) -> Double {
        let base = style?.lineHeightOrDefault ?? TextStyle.defaultLineHeight
        guard let maxRatio = rubies.map(\.sizeRatio).max() else { return base }
        return base + maxRatio + 0.15
    }

    // MARK: - 配置

    /// 1 区間(同じフォント・字間が続く文字列)の文字ごとの輪郭と送り幅。
    /// `TextFont.perCharLayout` と同じ流儀で、送り幅も返す。
    static func styledSegment(_ f: TextFont, _ s: String, spacing: Double, italic: Bool)
        -> (paths: [CGPath], xs: [Double], advances: [Double]) {
        let n = s.count
        guard n > 0 else { return ([], [], []) }
        let attr = NSAttributedString(string: s, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): f.ct,
                                                              NSAttributedString.Key(kCTKernAttributeName as String): spacing])
        let line = CTLineCreateWithAttributedString(attr)
        var charOf: [Int] = []
        for (i, ch) in s.enumerated() { charOf.append(contentsOf: Array(repeating: i, count: String(ch).utf16.count)) }
        var parts = (0..<n).map { _ in CGMutablePath() }
        var firstX = [Double?](repeating: nil, count: n)
        for run in (CTLineGetGlyphRuns(line) as? [CTRun]) ?? [] {
            let cnt = CTRunGetGlyphCount(run)
            guard cnt > 0 else { continue }
            let rf = ((CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName as String] as! CTFont?) ?? f.ct
            var glyphs = [CGGlyph](repeating: 0, count: cnt)
            var pos = [CGPoint](repeating: .zero, count: cnt)
            var idx = [CFIndex](repeating: 0, count: cnt)
            CTRunGetGlyphs(run, CFRange(location: 0, length: cnt), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: cnt), &pos)
            CTRunGetStringIndices(run, CFRange(location: 0, length: cnt), &idx)
            for i in 0..<cnt {
                guard idx[i] >= 0, idx[i] < charOf.count else { continue }
                let ci = charOf[idx[i]]
                if firstX[ci] == nil { firstX[ci] = Double(pos[i].x) }
                if let gp = CTFontCreatePathForGlyph(rf, glyphs[i], nil) {
                    parts[ci].addPath(gp, transform: CGAffineTransform(translationX: pos[i].x, y: pos[i].y))
                }
            }
        }
        let bounds = CTLineGetTypographicBounds(line, nil, nil, nil)
        var xs = [Double](repeating: 0, count: n)
        var advances = [Double](repeating: 0, count: n)
        var cursor = 0.0
        for i in 0..<n {
            xs[i] = firstX[i] ?? cursor
            cursor = max(cursor, xs[i])
        }
        for i in 0..<n {
            let next = i + 1 < n ? xs[i + 1] : bounds
            advances[i] = max(0, next - xs[i])
        }
        var paths: [CGPath] = parts
        if italic {
            var shear = CGAffineTransform(a: 1, b: 0, c: CGFloat(tan(12.0 * .pi / 180)), d: 1, tx: 0, ty: 0)
            paths = parts.map { $0.copy(using: &shear) ?? $0 }
        }
        return (paths, xs, advances)
    }

    /// 全行の配置。`buildPaths` が false のときは計測だけ(輪郭を作らない)。
    static func styledLayout(_ parsed: MarkupParsed, rubies: [MarkupRuby], baseSize: Double, fontName: String,
                             style: TextStyle?, buildPaths: Bool) -> (lines: [StyledLineGeom], width: Double, height: Double) {
        let plain = parsed.plain
        let plainChars = Array(plain)
        let styles = parsed.stylesByChar()
        let baseSpacing = style?.letterSpacingOrDefault ?? 0
        let baseItalic = style?.italicOrDefault ?? false
        let lineHeight = style?.lineHeightOrDefault ?? TextStyle.defaultLineHeight
        // 行に分ける(全域インデックスを保つ)
        var lineRanges: [(start: Int, indices: [Int])] = []
        var cur: [Int] = []
        var curStart = 0
        for (i, ch) in plain.enumerated() {
            if ch == "\n" {
                lineRanges.append((curStart, cur)); cur = []; curStart = i + 1
            } else {
                if cur.isEmpty { curStart = i }
                cur.append(i)
            }
        }
        lineRanges.append((curStart, cur))

        var lines: [StyledLineGeom] = []
        var blockW = 0.0
        var totalH = 0.0
        for (lineStart, indices) in lineRanges {
            var geoms: [StyledCharGeom] = []
            var cursor = 0.0
            var maxSize = baseSize
            // 同じ配置条件が続く区間ごとにレイアウトする
            var segStart = 0
            func layoutKey(_ gi: Int) -> String {
                let st = styles[gi]
                return "\(st.fontName ?? "")|\(st.size ?? -1)|\(st.bold as Bool?)|\(st.italic as Bool?)|\(st.letterSpacing ?? -1)"
            }
            while segStart < indices.count {
                var segEnd = segStart + 1
                while segEnd < indices.count, layoutKey(indices[segEnd]) == layoutKey(indices[segStart]) { segEnd += 1 }
                let segIndices = indices[segStart..<segEnd]
                let st = styles[indices[segStart]]
                let effSize = st.size ?? baseSize
                let effName = st.fontName ?? fontName
                let effBold = st.bold ?? (style?.boldOrDefault ?? true)
                let effItalic = st.italic ?? baseItalic
                let effSpacing = st.letterSpacing ?? baseSpacing
                maxSize = max(maxSize, effSize)
                let f = TextCache.font(name: effName, size: effSize, bold: effBold, weight: style?.weightValue)
                let segText = String(segIndices.map { plainChars[$0] })
                if buildPaths {
                    let seg = styledSegment(f, segText, spacing: effSpacing, italic: effItalic)
                    for (k, _) in segIndices.enumerated() {
                        // 輪郭は文字の左端を原点に直す(グリフ位置は seg.xs 側で持つ。二重に数えない)
                        var t = CGAffineTransform(translationX: CGFloat(-seg.xs[k]), y: 0)
                        let p = seg.paths[k].copy(using: &t) ?? seg.paths[k]
                        geoms.append(StyledCharGeom(x: cursor + seg.xs[k], advance: seg.advances[k], path: p, font: f, size: effSize))
                    }
                    cursor += seg.advances.reduce(0, +)
                } else {
                    // 計測だけ: CTLine の送り幅だけを使う
                    let attr = NSAttributedString(string: segText, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): f.ct,
                                                                                 NSAttributedString.Key(kCTKernAttributeName as String): effSpacing])
                    let w = CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attr), nil, nil, nil)
                    for _ in segIndices { geoms.append(StyledCharGeom(x: cursor, advance: 0, path: CGMutablePath(), font: f, size: effSize)) }
                    cursor += w
                }
                segStart = segEnd
            }
            // 行幅は「最後の文字の字間」を引く(従来の layout と同じ)
            var lineWidth = cursor
            if let last = indices.last {
                let sp = styles[last].letterSpacing ?? baseSpacing
                lineWidth = max(0, cursor - sp)
            }
            // ルビの余白: その行にルビがあれば、読みの高さぶん pitch を広げる
            var reserve = 0.0
            for r in rubies where r.start >= lineStart && r.start < lineStart + indices.count + 1 && indices.contains(r.start) {
                let baseCharSize = styles[r.start].size ?? baseSize
                reserve = max(reserve, baseCharSize * r.sizeRatio + baseCharSize * 0.12)
            }
            let pitch = maxSize * lineHeight + reserve
            lines.append(StyledLineGeom(chars: geoms, startIndex: lineStart, width: lineWidth, maxSize: maxSize, pitch: pitch))
            blockW = max(blockW, lineWidth)
            totalH += pitch
        }
        return (lines, blockW, totalH)
    }

    /// マークアップ付きテキストの枠(描画と一致させる)。
    static func styledBlockSize(_ parsed: MarkupParsed, rubies: [MarkupRuby], baseSize: Double, fontName: String, style: TextStyle?) -> CGSize {
        let l = styledLayout(parsed, rubies: rubies, baseSize: baseSize, fontName: fontName, style: style, buildPaths: false)
        return CGSize(width: l.width, height: l.height)
    }

    // MARK: - 描画

    /// タグ付きテキストの描画(横書き・静止画経路)。座標・引数の流儀は `drawText` と同じ。
    func drawStyledText(_ parsed: MarkupParsed, rubies: [MarkupRuby], x: Double, y: Double, size: Double,
                        color: String, font: String, outline: String, ctx: CGContext,
                        style: TextStyle?, visible: Int?) {
        guard size > 0 else { return }
        let plain = parsed.plain
        let styles = parsed.stylesByChar()
        let plainChars = Array(plain)
        let layout = Self.styledLayout(parsed, rubies: rubies, baseSize: size, fontName: font, style: style, buildPaths: true)
        Renderer.drawTextBox(style?.box, x: x, y: y, blockW: layout.width, blockH: layout.height, ctx: ctx)
        let fillBase = parseHexColor(color) ?? parseHexColor("#ffffff")!
        let outBase = parseHexColor(outline) ?? parseHexColor("#000000")!
        let align = style?.alignOrDefault ?? .center

        var remaining = visible
        var yCursor = y - layout.height / 2
        for line in layout.lines {
            let yy = yCursor + line.pitch / 2
            yCursor += line.pitch
            // 行の基準線: 行内で一番大きい文字のフォントで中央寄せする
            let bigFont = line.chars.max(by: { $0.size < $1.size })?.font ?? TextCache.font(name: font, size: size, bold: style?.boldOrDefault ?? true, weight: style?.weightValue)
            let baseline = yy + (bigFont.ascent - bigFont.descent) / 2
            let lineLeft: Double
            switch align {
            case .center: lineLeft = x - line.width / 2
            case .left: lineLeft = x - layout.width / 2
            case .right: lineLeft = x + layout.width / 2 - line.width
            }
            // 見えている文字だけ(visible は改行を除く通し数え)
            var visibleInLine: [Bool] = []
            for _ in line.chars {
                if let rem = remaining {
                    visibleInLine.append(rem > 0)
                    remaining = rem - 1
                } else { visibleInLine.append(true) }
            }
            // 塗りのまとまりごとに描く
            struct GroupKey: Equatable {
                var color: String?; var colorAlpha: Double; var outlineColor: String?; var outlineAlpha: Double
                var size: Double; var fontName: String; var regular: Bool; var faceKey: String
                var offsetX: Double; var offsetY: Double; var rotation: Double
            }
            var gi = 0
            while gi < line.chars.count {
                let gIdx = line.startIndex + gi
                let st = styles[gIdx]
                func key(_ s: MarkupRunStyle, _ g: StyledCharGeom) -> GroupKey {
                    GroupKey(color: s.color, colorAlpha: s.colorAlpha, outlineColor: s.outlineColor, outlineAlpha: s.outlineAlpha,
                             size: g.size, fontName: s.fontName ?? font, regular: g.font.regular, faceKey: g.font.faceKey,
                             offsetX: s.offsetX, offsetY: s.offsetY, rotation: s.rotation)
                }
                let k0 = key(st, line.chars[gi])
                var gj = gi + 1
                while gj < line.chars.count, key(styles[line.startIndex + gj], line.chars[gj]) == k0 { gj += 1 }
                // まとまりの輪郭(見えている文字だけ)
                let combined = CGMutablePath()
                var anyVisible = false
                for m in gi..<gj where visibleInLine[m] {
                    anyVisible = true
                    let g = line.chars[m]
                    if !g.path.isEmpty {
                        var t = CGAffineTransform(translationX: CGFloat(g.x + k0.offsetX), y: 0)
                        if let moved = g.path.copy(using: &t) { combined.addPath(moved) }
                    }
                }
                if anyVisible {
                    let gFont = line.chars[gi].font
                    let fill = (st.color.flatMap { parseHexColor($0) } ?? fillBase).copy(alpha: CGFloat(st.colorAlpha)) ?? fillBase
                    let out = (st.outlineColor.flatMap { parseHexColor($0) } ?? outBase).copy(alpha: CGFloat(st.outlineAlpha)) ?? outBase
                    var path: CGPath = combined
                    if k0.rotation != 0, !combined.isEmpty {
                        let bb = combined.boundingBoxOfPath
                        var t = CGAffineTransform(translationX: bb.midX, y: bb.midY)
                            .rotated(by: CGFloat(-k0.rotation * .pi / 180))
                            .translatedBy(x: -bb.midX, y: -bb.midY)
                        if let rotated = combined.copy(using: &t) { path = rotated }
                    }
                    if path.isEmpty {
                        // 輪郭の無い文字(絵文字など)は CoreText で描く
                        let segText = String(plainChars[line.startIndex + gi..<line.startIndex + gj])
                        if segText.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation }) {
                            Renderer.drawColorGlyphs(segText, f: gFont, spacing: st.letterSpacing ?? (style?.letterSpacingOrDefault ?? 0),
                                                     italic: st.italic ?? (style?.italicOrDefault ?? false),
                                                     x: lineLeft + line.chars[gi].x + k0.offsetX, baseline: baseline + k0.offsetY, ctx: ctx)
                        }
                    } else {
                        ctx.saveGState()
                        ctx.translateBy(x: CGFloat(lineLeft), y: CGFloat(baseline + k0.offsetY))
                        Renderer.paintLine((path: path, width: line.width), gFont, size: k0.size, fill: fill, outline: out, ctx: ctx, style: style)
                        ctx.restoreGState()
                    }
                }
                gi = gj
            }
            // 下線・打ち消し線
            for (m, g) in line.chars.enumerated() where visibleInLine[m] {
                let st = styles[line.startIndex + m]
                guard st.underline || st.strikethrough else { continue }
                let fill = (st.color.flatMap { parseHexColor($0) } ?? fillBase).copy(alpha: CGFloat(st.colorAlpha)) ?? fillBase
                ctx.saveGState()
                ctx.setFillColor(fill)
                let rx = lineLeft + g.x + st.offsetX
                let h = max(1, g.size * 0.05)
                if st.underline {
                    ctx.fill(CGRect(x: rx, y: baseline + st.offsetY + g.size * 0.16, width: g.advance, height: h))
                }
                if st.strikethrough {
                    ctx.fill(CGRect(x: rx, y: baseline + st.offsetY - g.size * 0.25, width: g.advance, height: h))
                }
                ctx.restoreGState()
            }
            // ルビ
            for r in rubies where r.start >= line.startIndex && r.start < line.startIndex + line.chars.count && r.end <= line.startIndex + line.chars.count {
                let local = r.start - line.startIndex
                guard visibleInLine[local] else { continue }
                let g0 = line.chars[local]
                let g1 = line.chars[r.end - 1 - line.startIndex]
                let st0 = styles[r.start]
                let x0 = g0.x + st0.offsetX
                let x1 = g1.x + g1.advance + styles[r.end - 1].offsetX
                guard x1 > x0 else { continue }
                let rsize = g0.size * r.sizeRatio
                guard rsize > 0 else { continue }
                let rf = TextCache.font(name: r.fontName ?? (st0.fontName ?? font), size: rsize, bold: r.bold ?? (style?.boldOrDefault ?? true))
                let rBaseline = baseline + st0.offsetY - g0.font.ascent - g0.size * 0.06 - rf.descent + r.dy
                let path = rubyPath(r.reading, rf: rf, italic: r.italic ?? (style?.italicOrDefault ?? false), x0: x0, x1: x1)
                guard !path.isEmpty else { continue }
                let fill = (r.color.flatMap { parseHexColor($0) } ?? st0.color.flatMap { parseHexColor($0) } ?? fillBase)
                let out = (r.outlineColor.flatMap { parseHexColor($0) } ?? st0.outlineColor.flatMap { parseHexColor($0) } ?? outBase)
                let lineStyle: TextStyle? = (style?.affectsLine ?? false) ? style : nil
                ctx.saveGState()
                ctx.translateBy(x: CGFloat(lineLeft + r.dx), y: CGFloat(rBaseline))
                Renderer.paintLine((path: path, width: x1 - x0), rf, size: rsize, fill: fill, outline: out, ctx: ctx, style: lineStyle)
                ctx.restoreGState()
            }
        }
    }
}
