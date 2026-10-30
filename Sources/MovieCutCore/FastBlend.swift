import Foundation
import CoreGraphics

/// 不透明度つきの画像を、CoreGraphics の汎用経路(1080p で約 9 ms)を通さずに直接重ねる。
/// 条件が合うときだけ使い(等倍・整数位置・BGRA 事前乗算・クリップ無し)、合わなければ false を返して呼び出し側が従来どおり描く。
/// 結果は CoreGraphics の source-over と ±1/255 以内で一致する。
enum FastBlend {
    static var disabled = ProcessInfo.processInfo.environment["MC_NO_FASTBLEND"] != nil

    /// ctx は左上原点(上下反転済み)の BGRA 事前乗算ビットマップ。rect はキャンバス座標。
    static func drawFaded(_ ctx: CGContext, _ img: CGImage, rect: CGRect, alpha: Double) -> Bool {
        guard !disabled, alpha > 0, alpha <= 1,
              img.bitsPerComponent == 8, img.bitsPerPixel == 32, img.alphaInfo == .premultipliedFirst, img.bitmapInfo.contains(.byteOrder32Little),
              ctx.bitsPerComponent == 8, ctx.bitsPerPixel == 32, ctx.alphaInfo == .premultipliedFirst, ctx.bitmapInfo.contains(.byteOrder32Little),
              let dst = ctx.data
        else { return false }
        // 等倍・整数位置だけ(CoreGraphics と同じ画素になる)
        let ox = rect.minX.rounded(), oy = rect.minY.rounded()
        guard abs(rect.minX - ox) < 1e-6, abs(rect.minY - oy) < 1e-6,
              abs(rect.width - Double(img.width)) < 1e-6, abs(rect.height - Double(img.height)) < 1e-6 else { return false }
        // 描画の変形が「左上原点・拡大なし」のときだけ(呼び出し側の約束だが、念のため)
        let ctm = ctx.ctm
        guard abs(ctm.a - 1) < 1e-9, abs(ctm.d + 1) < 1e-9, abs(ctm.b) < 1e-9, abs(ctm.c) < 1e-9,
              abs(ctm.ty - Double(ctx.height)) < 1e-6, abs(ctm.tx) < 1e-6 else { return false }
        let clip = ctx.boundingBoxOfClipPath
        let cw = ctx.width, ch = ctx.height
        guard clip.width >= Double(cw) - 1e-6, clip.height >= Double(ch) - 1e-6 else { return false }
        guard let data = img.dataProvider?.data, let sp = CFDataGetBytePtr(data) else { return false }
        let x0 = max(0, Int(ox)), y0 = max(0, Int(oy))
        let x1 = min(cw, Int(ox) + img.width), y1 = min(ch, Int(oy) + img.height)
        guard x1 > x0, y1 > y0 else { return true }
        let sRow = img.bytesPerRow, dRow = ctx.bytesPerRow
        let a = UInt32((alpha * 65535).rounded())
        let dBase = dst.assumingMemoryBound(to: UInt8.self)
        let sBase = sp
        let sx = x0 - Int(ox), sy = y0 - Int(oy), n = x1 - x0
        let rows = y1 - y0
        let bands = min(rows, max(1, ProcessInfo.processInfo.activeProcessorCount))
        DispatchQueue.concurrentPerform(iterations: bands) { b in
            let r0 = rows * b / bands, r1 = rows * (b + 1) / bands
            for r in r0..<r1 {
                let s = (sBase + (sy + r) * sRow + sx * 4)
                let d = (dBase + (y0 + r) * dRow + x0 * 4)
                blendRow(s, d, n, a)
            }
        }
        return true
    }

    @inline(__always)
    private static func blendRow(_ s: UnsafePointer<UInt8>, _ d: UnsafeMutablePointer<UInt8>, _ n: Int, _ a: UInt32) {
        var i = 0
        while i < n {
            let p = i * 4
            let sa = UInt32(s[p + 3])
            let inv = 65535 - (sa * a + 127) / 255   // 1 - 元のα × 不透明度(16 ビット)
            var k = 0
            while k < 4 {
                let v = (UInt32(s[p + k]) * a + UInt32(d[p + k]) * inv + 32767) / 65535
                d[p + k] = UInt8(truncatingIfNeeded: min(v, 255))
                k += 1
            }
            i += 1
        }
    }
}
