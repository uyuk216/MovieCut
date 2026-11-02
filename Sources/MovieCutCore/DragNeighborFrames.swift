import Foundation
import CoreGraphics

// MARK: - ドラッグ中に、移動先の前後のコマを並べて見せる
//
// タイムラインでクリップを動かしている間、動かした先の「つなぎ目」が見えるように、次の 4 コマを 1 枚の帯にして出す。
//   頭のつなぎ目: [クリップの 1 コマ前 | クリップの最初のコマ]
//   終わりのつなぎ目: [クリップの最後のコマ | クリップの 1 コマ後]
// コマはどれも「動かした後のプロジェクト」を `Renderer`(プレビューと同じ経路)で描いたもの。1 コマ前・後にクリップが無ければ、そこには下のレイヤーや背景が映る。
// 頭が 0 秒のときは 1 コマ前が無いので、その枠は空(暗い印)にする。
public enum DragNeighborFrames {
    /// 帯の 1 コマの横幅(画素)。
    public static let cellWidth = 200
    /// 1 コマの間・つなぎ目の間の空き(画素)。
    static let gap = 3, pairGap = 12

    /// 4 コマの時刻。`headBefore` は頭が 0 秒(1 コマ前が無い)のとき nil。
    public struct Times: Equatable {
        public var headBefore: Double?
        public var headAfter: Double
        public var tailBefore: Double
        public var tailAfter: Double
        /// 帯に並べる順(頭の前・頭・終わり・終わりの後)。
        public var ordered: [Double?] { [headBefore, headAfter, tailBefore, tailAfter] }
    }

    /// クリップが `start`〜`end`(秒)にあるときの 4 コマの時刻(コマの格子に合わせる)。長さが 1 コマに満たなければ、最後のコマ = 最初のコマ。
    public static func times(start: Double, end: Double, rate: FrameRate) -> Times? {
        guard start.isFinite, end.isFinite, end > start else { return nil }
        let d = rate.frameDuration
        let s = rate.snapped(max(0, start))
        let after = rate.snapped(end)
        let lastIndex = max(rate.frameIndex(at: s), rate.frameIndex(at: end - 1e-6))
        let last = rate.time(ofFrame: lastIndex)
        return Times(headBefore: s >= d - 1e-6 ? rate.snapped(s - d) : nil, headAfter: s, tailBefore: last, tailAfter: max(after, last + d))
    }

    /// 帯の大きさ(画素)。コマの縦横比は プロジェクトの画面に合わせる。
    public static func stripSize(width: Int, height: Int) -> CGSize {
        let cw = cellWidth
        let ch = max(2, Int((Double(cw) * Double(max(height, 1)) / Double(max(width, 1))).rounded()))
        return CGSize(width: cw * 4 + gap * 2 + pairGap, height: ch)
    }

    /// `project` を `times` の 4 コマで描いて、1 枚の帯にする(コマは縦横比を保って縮める)。描けなければ nil。
    public static func strip(project: Project, assets: RenderAssets, times: Times) -> CGImage? {
        guard project.width > 0, project.height > 0 else { return nil }
        let size = stripSize(width: project.width, height: project.height)
        let cw = cellWidth, ch = Int(size.height)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: Int(size.width), height: ch, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.1, blue: 0.11, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: Int(size.width), height: ch))
        ctx.interpolationQuality = .medium
        let renderer = Renderer(project: project, assets: assets)
        var x = 0
        for (i, t) in times.ordered.enumerated() {
            let rect = CGRect(x: x, y: 0, width: cw, height: ch)
            if let t, let img = renderer.renderImage(t: t) {
                ctx.draw(img, in: rect)
            } else {
                // 無いコマ(頭の前など): 斜線の代わりに、少し明るい枠だけ
                ctx.setFillColor(CGColor(srgbRed: 0.18, green: 0.18, blue: 0.2, alpha: 1))
                ctx.fill(rect)
            }
            x += cw + (i == 1 ? pairGap : gap)
        }
        return ctx.makeImage()
    }
}
