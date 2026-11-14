import Foundation
import CoreGraphics

// ルビ(ふりがな)の描画。横書きの通常経路(`Renderer.drawText`)からだけ呼ばれる。
// 読みは親文字の 0.5 倍の大きさで、親文字の真上に置く。読みの幅が親文字の区間より狭ければ、
// 読みの文字を区間いっぱいに均等に広げる(日本語のルビの並べ方)。広ければ区間の中央にそのまま置く。
// 描き方は本体の行と同じ(輪郭をビットマップ化してキャッシュする経路と、直接塗る経路)。
// 座標は本体の行と同じ流儀: 輪郭は「行の左端・読みの基準線」を原点にした局所座標で組み、
// 呼び出し側が原点をキャンバスへ移してから塗る。

extension Renderer {
    /// `line` の中にあるルビを描く。`segments` は行頭から数えた Character 単位の (開始, 終わり, 読み)。
    /// `lineLeftX` は行の左端(キャンバス座標・y 下向き)、`baseline` は親文字の基準線の y。
    func drawRubyReadings(_ segments: [(start: Int, end: Int, reading: String)], line: String,
                           fontName: String, size: Double, lineLeftX: Double, baseline: Double,
                           fill: CGColor, outline: CGColor, ctx: CGContext, cacheable: Bool, style: TextStyle?) {
        guard !segments.isEmpty else { return }
        let spacing = style?.letterSpacingOrDefault ?? 0
        let italic = style?.italicOrDefault ?? false
        let bold = style?.boldOrDefault ?? true
        let f = TextCache.font(name: fontName, size: size, bold: bold)
        let rsize = size * RubyText.sizeRatio
        let rf = TextCache.font(name: fontName, size: rsize, bold: bold)
        // 読みの基準線: 読みの下端が、親文字の上端より少し上に来る位置
        let rBaseline = baseline - f.ascent - size * 0.06 - rf.descent
        let chars = Array(line)
        func prefixWidth(_ n: Int) -> Double {
            guard n > 0 else { return 0 }
            return TextCache.layout(f, font: fontName, line: String(chars[0..<min(n, chars.count)]), spacing: spacing, italic: italic).width
        }
        let lineStyle: TextStyle? = (style?.affectsLine ?? false) ? style : nil
        for seg in segments {
            let x0 = prefixWidth(seg.start)
            let x1 = prefixWidth(seg.end)
            guard x1 > x0 else { continue }
            // 読みの輪郭(原点 = 行の左端・読みの基準線、y 上向き)
            let path = rubyPath(seg.reading, rf: rf, italic: italic, x0: x0, x1: x1)
            guard !path.isEmpty else { continue }
            let item = (path: path, width: x1 - x0)
            if cacheable {
                let ix = floor(lineLeftX), iy = floor(rBaseline)
                let fx = lineLeftX - ix, fy = rBaseline - iy
                let key = "R|\(fontName)|\(rsize)|\(seg.reading)|\((x1 - x0).rounded())|\(fx)|\(fy)|\(bold)|\(lineStyle?.lineKey ?? "")"
                let build = { Renderer.rasterizeLine(item, rf, size: rsize, fill: fill, outline: outline, fx: fx, fy: fy, style: lineStyle) }
                if let bm = TextCache.bitmap(key: key, build: build) {
                    drawCG(ctx, bm.image, CGRect(x: ix + bm.x, y: iy + bm.y, width: Double(bm.image.width) / bm.k, height: Double(bm.image.height) / bm.k))
                }
                continue
            }
            ctx.saveGState()
            ctx.translateBy(x: CGFloat(lineLeftX), y: CGFloat(rBaseline))
            Renderer.paintLine(item, rf, size: rsize, fill: fill, outline: outline, ctx: ctx, style: lineStyle)
            ctx.restoreGState()
        }
    }

    /// 読みの輪郭を、区間 [x0, x1](行の左端から測った x)に合わせて組む。y は読みの基準線が 0(y 上向き)。
    private func rubyPath(_ reading: String, rf: TextFont, italic: Bool, x0: Double, x1: Double) -> CGPath {
        let segW = x1 - x0
        let whole = rf.layout(reading, spacing: 0, italic: italic)
        let out = CGMutablePath()
        if whole.width <= segW, reading.count > 1 {
            // 区間より狭い: 1 文字ずつ、区間いっぱいに均等に置く
            let parts = rf.perCharLayout(reading, spacing: 0, italic: italic).chars
            let n = parts.count
            for (i, p) in parts.enumerated() where !p.isEmpty {
                let bb = p.boundingBoxOfPath
                let center = x0 + segW * (Double(i) + 0.5) / Double(n)
                var t = CGAffineTransform(translationX: CGFloat(center - bb.midX), y: 0)
                if let moved = p.copy(using: &t) { out.addPath(moved) }
            }
        } else {
            // 区間より広い(または 1 文字): 区間の中央にそのまま置く
            var t = CGAffineTransform(translationX: CGFloat(x0 + (segW - whole.width) / 2), y: 0)
            if let moved = whole.path.copy(using: &t) { out.addPath(moved) }
        }
        return out
    }
}
