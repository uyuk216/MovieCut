import Foundation
import CoreGraphics

/// 1 文字ずつ動かす描き方の指定(時刻・基準の濃さ)。
struct CharAnimSpec {
    var anim: TextAnim
    /// クリップの頭からの秒。
    var rel: Double
    /// 呼び出し側の濃さ(フェード・トランジション)。文字ごとの濃さに掛ける。
    var baseAlpha: Double = 1
}

extension Renderer {
    /// 縦書きの文字、または 1 文字ずつ動いている文字を描く。位置は全文字ぶんで決めるので、文字が増えても動かない。
    /// 動いていない縦書きは、全体の輪郭をひとまとめにして 1 枚のビットマップにし、横書きと同じようにキャッシュする。
    func drawTextChars(_ text: String, x: Double, y: Double, size: Double, color: String, font: String, outline: String, ctx: CGContext,
                       cacheable: Bool, style: TextStyle?, visible: Int?, charAnim: CharAnimSpec?) {
        let fillC = parseHexColor(color) ?? parseHexColor("#ffffff")!
        let outC = parseHexColor(outline) ?? parseHexColor("#000000")!
        let f = TextCache.font(name: font, size: size, bold: style?.boldOrDefault ?? true)
        let spacing = style?.letterSpacingOrDefault ?? 0
        let lineHeight = style?.lineHeightOrDefault ?? TextStyle.defaultLineHeight
        let align = style?.alignOrDefault ?? .center
        let vertical = style?.verticalOrDefault ?? false

        // 配置(文字ごとの輪郭と、ctx を移す点)
        var items: [(ch: PlacedChar, origin: CGPoint)] = []
        let boxW: Double, boxH: Double
        if vertical {
            let lay = VerticalText.layout(text, font: f, size: size, spacing: spacing, lineHeight: lineHeight, align: align)
            items = lay.chars.map { ($0, CGPoint(x: x, y: y)) }
            boxW = lay.width; boxH = lay.height
        } else {
            let italic = style?.italicOrDefault ?? false
            let lines = text.components(separatedBy: "\n")
            let pitch = size * lineHeight
            let widths = lines.map { TextCache.layout(f, font: font, line: $0, spacing: spacing, italic: italic).width }
            let blockW = widths.max() ?? 0
            var index = 0
            for (i, ln) in lines.enumerated() {
                let yy = y + (Double(i) - Double(lines.count - 1) / 2) * pitch
                let baseline = yy + (f.ascent - f.descent) / 2
                let ox: Double
                switch align {
                case .center: ox = x - widths[i] / 2
                case .left: ox = x - blockW / 2
                case .right: ox = x + blockW / 2 - widths[i]
                }
                let parts = f.perCharLayout(ln, spacing: spacing, italic: italic).chars
                for p in parts {
                    let bb = p.boundingBoxOfPath
                    let cx = (bb.isNull || bb.isInfinite) ? 0 : bb.midX
                    items.append((PlacedChar(path: p, center: CGPoint(x: cx, y: (f.ascent - f.descent) / 2), index: index), CGPoint(x: ox, y: baseline)))
                    index += 1
                }
            }
            boxW = blockW; boxH = Double(lines.count) * pitch
        }
        Renderer.drawTextBox(style?.box, x: x, y: y, blockW: boxW, blockH: boxH, ctx: ctx)

        // 動いている: 文字ごとに、遅れ・拡大・濃さ・ずれを付けて直接描く
        if let ca = charAnim {
            for it in items {
                if let v = visible, it.ch.index >= v { continue }
                guard !it.ch.path.isEmpty else { continue }
                let r = TextAnimMath.charState(ca.anim, index: it.ch.index, rel: ca.rel, size: size)
                if r.hidden { continue }
                let st = r.state
                ctx.saveGState()
                if st.alpha != 1 || ca.baseAlpha != 1 { ctx.setAlpha(CGFloat(ca.baseAlpha * st.alpha)) }
                ctx.translateBy(x: CGFloat(it.origin.x + st.dx), y: CGFloat(it.origin.y + st.dy))
                if st.scale != 1 {
                    // 文字の中心を基準に拡大(中心は y 上向きの値なので、ctx では符号を反転)
                    ctx.translateBy(x: CGFloat(it.ch.center.x), y: CGFloat(-it.ch.center.y))
                    ctx.scaleBy(x: CGFloat(st.scale), y: CGFloat(st.scale))
                    ctx.translateBy(x: CGFloat(-it.ch.center.x), y: CGFloat(it.ch.center.y))
                }
                Renderer.paintLine((it.ch.path, 0), f, size: size, fill: fillC, outline: outC, ctx: ctx, style: style)
                ctx.restoreGState()
            }
            return
        }

        // 動いていない縦書き: 見える文字の輪郭を 1 つにまとめて、ビットマップにキャッシュして貼る
        let all = CGMutablePath()
        for it in items {
            if let v = visible, it.ch.index >= v { continue }
            if !it.ch.path.isEmpty { all.addPath(it.ch.path) }
        }
        guard !all.isEmpty else { return }
        let line = (path: all as CGPath, width: boxW)
        let ix = floor(x), iy = floor(y)
        let fx = x - ix, fy = y - iy
        let k = cacheable ? 1.0 : min(4, max(1, Double(hypot(ctx.ctm.a, ctx.ctm.b))))
        let lineStyle: TextStyle? = (style?.affectsLine ?? false) ? style : nil
        let build = { Renderer.rasterizeLine(line, f, size: size, fill: fillC, outline: outC, fx: fx, fy: fy, style: lineStyle, k: k) }
        let key = "V|\(font)|\(size)|\(text)|\(visible ?? -1)|\(color)|\(outline)|\(fx)|\(fy)|\(lineHeight)|\(align.rawValue)|\(spacing)|\(style?.boldOrDefault ?? true)|\(lineStyle?.lineKey ?? "")"
        if let bm = cacheable ? TextCache.bitmap(key: key, build: build) : build() {
            drawCG(ctx, bm.image, CGRect(x: ix + bm.x, y: iy + bm.y, width: Double(bm.image.width) / bm.k, height: Double(bm.image.height) / bm.k))
        }
    }

    /// 字幕(ボイスの文字)。画面下の中央、縦書きのときは右端に寄せる。文字クリップと同じアニメーション(1 文字ずつも)が使える。
    func drawSubtitle(_ c: Clip, t: Double, outline: String, ctx: CGContext, W: Double, H: Double) {
        let text = ExpressionTag.body(c.text ?? "")
        let size = c.fontSize ?? 64
        let style = c.textStyle
        var x = W / 2, y = H * 0.88
        if style?.verticalOrDefault == true {
            let b = textBlockSize(text, size: size, font: c.fontOrDefault, style: style)
            x = W - max(size * 0.6, W * 0.03) - b.width / 2
            y = H / 2
        }
        var visible: Int?
        var charAnim: CharAnimSpec?
        var scale = 1.0, alpha = 1.0, moving = false
        if let a = c.textAnim, let kind = a.known, kind != .none, !kind.isScroll {
            let rel = t - c.start
            if a.perCharOrNil != nil {
                if TextAnimMath.perCharActive(a, count: text.filter { $0 != "\n" }.count, rel: rel) { charAnim = CharAnimSpec(anim: a, rel: rel) }
            } else {
                let st = TextAnimMath.state(a, text: text, rel: rel, size: size)
                if st.active {
                    visible = st.visible; scale = st.scale; alpha = st.alpha; moving = true
                    x += st.dx; y += st.dy
                }
            }
        }
        ctx.saveGState()
        if alpha != 1 { ctx.setAlpha(CGFloat(alpha)) }
        if scale != 1 {
            ctx.translateBy(x: CGFloat(x), y: CGFloat(y)); ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale)); ctx.translateBy(x: CGFloat(-x), y: CGFloat(-y))
        }
        let animating = moving || charAnim != nil
        drawText(text, x: x, y: y, size: size, color: "#ffffff", font: c.fontOrDefault, outline: outline, ctx: ctx, cacheable: !animating, style: style, visible: visible, charAnim: charAnim)
        ctx.restoreGState()
    }
}
