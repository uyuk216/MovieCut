import Foundation
import CoreGraphics

/// フレームブレンド: 隣り合う 2 コマを時間の比で混ぜる(線形のクロスフェード)。速度が 1 未満のスローモーションを滑らかにする。
/// 画素は `(1 − w) × A + w × B`(不透明な画像どうし)。CoreGraphics の描画で作るので、プレビューと書き出しで同じ結果になる。
enum FrameBlend {
    /// `a` と `b` を重さ `w`(0〜1)で混ぜた画像。大きさが違うとき・作れないときは `a`(nil は作れなかったとき)。
    /// w ≤ 0 は a、w ≥ 1 は b をそのまま返す(作り直さない)。
    static func mix(_ a: CGImage, _ b: CGImage, weight w: Double) -> CGImage? {
        if w <= 0 { return a }
        if w >= 1 { return b }
        guard a.width == b.width, a.height == b.height, a.width > 0, a.height > 0 else { return a }
        let cs = a.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let ctx = CGContext(data: nil, width: a.width, height: a.height, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: info) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: a.width, height: a.height)
        ctx.draw(a, in: rect)
        ctx.setAlpha(CGFloat(w))
        ctx.draw(b, in: rect)
        return ctx.makeImage()
    }
}
