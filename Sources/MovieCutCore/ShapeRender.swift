import Foundation
import CoreGraphics

// MARK: - 図形の描画(Renderer の拡張)
//
// 中心(x・y)・幅と高さ(w・h、キャンバスに対する割合)・回転(度)・不透明度・反転で置く。
// 塗りと線が両方あって不透明度が 1 未満のときは透明レイヤーで重ね、重なった所で不透明度が二重にかからないようにする。
// 太さ・先の長さは 1080p の画素で決めて、書き出しの高さに比例させる(プレビューと書き出しで同じ見た目)。

extension Renderer {
    /// 図形を描く(左上原点の ctx)。素材を持たないので、画像の変形・効果・トランジションは通らない。
    func drawShape(_ c: Clip, t: Double, ctx: CGContext, W: Double, H: Double) {
        let r = t - c.start
        let cx = Animation.value(of: "x", in: c, at: r) * W, cy = Animation.value(of: "y", in: c, at: r) * H
        let bw = Animation.value(of: "w", in: c, at: r) * W, bh = Animation.value(of: "h", in: c, at: r) * H
        guard bw > 0, bh > 0 else { return }
        let opacity = min(max(Animation.value(of: "opacity", in: c, at: r), 0), 1)
        guard opacity > 0 else { return }
        let rot = Animation.value(of: "rotation", in: c, at: r)
        let f = c.figureOrDefault
        let kind = f.figureKind
        let unit = H / 1080.0
        let sw = f.strokeWidthOrDefault * unit
        let fillHex = f.fillOrDefault, strokeHex = f.strokeOrDefault
        let fillColor: CGColor? = fillHex == Figure.noneColor ? nil : parseHexColor(fillHex)
        let strokeColor: CGColor? = strokeHex == Figure.noneColor ? nil : parseHexColor(strokeHex)
        // 角丸は短い辺の割合(FigureGeometry が掛ける)。先の長さは線の太さか短い辺の 1/5 の大きい方。
        let head = max(sw * 4, min(bw, bh) * 0.2)
        let path = FigureGeometry.path(kind: kind, w: bw, h: bh, corner: f.cornerOrDefault, headLength: head)

        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.translateBy(x: CGFloat(cx), y: CGFloat(cy))
        if rot != 0 { ctx.rotate(by: CGFloat(rot * .pi / 180)) }
        if c.flipHOrDefault || c.flipVOrDefault {
            ctx.scaleBy(x: c.flipHOrDefault ? -1 : 1, y: c.flipVOrDefault ? -1 : 1)
        }
        // 塗りと線が両方あって重なるときだけ透明レイヤーを使う(不透明度を重なりごとに掛けない)。
        // 一種類しか描かないときは、そのまま不透明度を掛ける。レイヤーは図形の周りだけに絞る。
        let bothPaint = !kind.isStrokeOnly && fillColor != nil && strokeColor != nil && sw > 0
        let layered = opacity < 1 && bothPaint
        if opacity < 1 && !layered { ctx.setAlpha(CGFloat(opacity)) }
        if layered {
            let pad = sw + 2
            ctx.clip(to: path.boundingBoxOfPath.insetBy(dx: -pad, dy: -pad))
            ctx.setAlpha(CGFloat(opacity))
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            ctx.setAlpha(1)
        }
        if kind.isStrokeOnly {
            // 線・矢印: 塗らず、線の色(無ければ塗りの色)と太さで描く
            if let color = strokeColor ?? fillColor, sw > 0 {
                ctx.setStrokeColor(color)
                ctx.setLineWidth(CGFloat(sw))
                ctx.setLineCap(.round)
                ctx.setLineJoin(.round)
                ctx.addPath(path)
                ctx.strokePath()
            }
        } else {
            if let fill = fillColor {
                ctx.setFillColor(fill)
                ctx.addPath(path)
                ctx.fillPath()
            }
            if let stroke = strokeColor, sw > 0 {
                ctx.setStrokeColor(stroke)
                ctx.setLineWidth(CGFloat(sw))
                ctx.setLineJoin(.round)
                ctx.addPath(path)
                ctx.strokePath()
            }
        }
        if layered { ctx.endTransparencyLayer() }
    }
}
