import Foundation

// MARK: - 減算ブレンドの画素合成
//
// 定義(Photoshop / Premiere の「減算」と同じ): 成分ごとに
//   B(下, 上) = clamp(下 − 上 + 1.0, 0, 1)        (0〜1 の非事前乗算色)
// 合成は他のブレンドモードと同じ作法(ブレンドした色を source-over で重ねる):
//   αo = αs + αb − αs·αb
//   co(事前乗算) = (1−αb)·cs + αs·αb·B(下, 上) + (1−αs)·cb   (cs・cb は事前乗算色)
// 下が完全に透明な画素では上そのもの、上が透明な画素では下そのものになる。
//
// Core Image の CISubtractBlendMode は +1.0 の無い clamp(下 − 上) で意味が違うため使わない
// (実測: 下 = 赤 (255,0,0)・上 = 灰 128 のとき CI は (127,0,0)、この定義では (255,127,127))。
// CGContext にも減算が無いので、Renderer がクリップを透明な台紙へ通常合成で描き分け、
// ここで下地と画素ごとに合成する。計算は sRGB のバイト値のまま行うので、CGContext の
// 他のブレンドモード(同じくガンマ空間の値で計算)と揃う。
enum SubtractBlend {
    /// 1 画素の合成。引数・戻り値とも事前乗算 RGBA(各 0〜255)。
    static func blendPixel(br: UInt8, bg: UInt8, bb: UInt8, ba: UInt8,
                           sr: UInt8, sg: UInt8, sb: UInt8, sa: UInt8) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        if sa == 0 { return (br, bg, bb, ba) }   // 上が透明なら下そのまま
        if ba == 0 { return (sr, sg, sb, sa) }   // 下が透明なら上そのまま
        let bA = Double(ba) / 255, sA = Double(sa) / 255
        func channel(_ bP: UInt8, _ sP: UInt8) -> UInt8 {
            let cb = Double(bP) / 255 / bA       // 下の非事前乗算色
            let cs = Double(sP) / 255 / sA       // 上の非事前乗算色
            let blended = min(max(cb - cs + 1, 0), 1)
            let co = (1 - bA) * (Double(sP) / 255) + sA * bA * blended + (1 - sA) * (Double(bP) / 255)
            return UInt8(min(max((co * 255).rounded(), 0), 255))
        }
        let oA = sA + bA - sA * bA
        return (channel(br, sr), channel(bg, sg), channel(bb, sb),
                UInt8(min(max((oA * 255).rounded(), 0), 255)))
    }

    /// BGRA 事前乗算のバッファ同士を合成し、target(下地)へ書き戻す。
    /// 画素ごとに読み切ってから書くので、target と下地が同じバッファでもよい。
    /// 範囲の外は触らない(呼び出し側の切り抜きを守るため)。
    static func composite(target: UnsafeMutablePointer<UInt8>, targetStride: Int,
                          source: UnsafePointer<UInt8>, sourceStride: Int,
                          xRange: Range<Int>, yRange: Range<Int>) {
        let rows = yRange.count
        guard rows > 0, xRange.count > 0 else { return }
        let bands = min(rows, max(1, ProcessInfo.processInfo.activeProcessorCount))
        DispatchQueue.concurrentPerform(iterations: bands) { band in
            let r0 = yRange.lowerBound + rows * band / bands
            let r1 = yRange.lowerBound + rows * (band + 1) / bands
            for y in r0..<r1 {
                var tp = target + y * targetStride + xRange.lowerBound * 4
                var sp = source + y * sourceStride + xRange.lowerBound * 4
                for _ in xRange {
                    // BGRA 事前乗算: 0=B, 1=G, 2=R, 3=A
                    let out = blendPixel(br: tp[2], bg: tp[1], bb: tp[0], ba: tp[3],
                                         sr: sp[2], sg: sp[1], sb: sp[0], sa: sp[3])
                    tp[0] = out.b; tp[1] = out.g; tp[2] = out.r; tp[3] = out.a
                    tp += 4; sp += 4
                }
            }
        }
    }
}
