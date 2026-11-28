import Foundation
import CoreGraphics
import CoreImage

// MARK: - 物体除去(古典的インペインティング)
//
// マスクで指定した領域(穴)を、周囲の既知の画素から埋める。学習型ではなく、決定的な 2 段の処理:
// 1. onion-peel: 穴の縁から内側へ 1 層ずつ、その時点で既知の 8 近傍の平均で埋める(初期値)
// 2. 緩和: 穴の画素だけを 4 近傍の平均へ寄せる反復(ラプラス方程式の解 = なだらかな補間)。
//    線形のグラデーションは調和関数なので、周囲が線形なら連続に埋まる。
// 同じ入力は必ず同じ出力(乱数・並列・浮動小数の順序揺れなし)。穴の外の画素は 1 つも変えない。
// 限界: テクスチャ(模様・文字・顔など)は再現できず、大きな穴や複雑な背景ではぼやけた塗りになる。

public enum Inpainting {
    /// 緩和の反復回数の既定。小さな穴ならすぐ収束し、大きな穴はぼやけた塗りになる前提で打ち切る。
    public static let defaultRelaxIterations = 80

    /// RGBA8 のバッファの穴(`hole[i] == true`)を周囲で埋める。穴の外は変えない。
    /// 既知の画素がまったく無い(全面が穴)ときは何もしない。
    public static func fill(rgba: inout [UInt8], width w: Int, height h: Int, hole: [Bool],
                            relaxIterations: Int = defaultRelaxIterations) {
        guard w > 0, h > 0, rgba.count == w * h * 4, hole.count == w * h else { return }
        guard hole.contains(true), hole.contains(false) else { return }
        var px = rgba.map { Float($0) }
        var known = hole.map { !$0 }

        // 1. onion-peel
        var layer: [Int] = []
        var remaining = hole.reduce(0) { $0 + ($1 ? 1 : 0) }
        var holeIdx: [Int] = []
        holeIdx.reserveCapacity(remaining)
        for i in 0..<(w * h) where hole[i] { holeIdx.append(i) }
        var pending = holeIdx
        while remaining > 0 {
            layer.removeAll(keepingCapacity: true)
            var stillPending: [Int] = []
            var values: [Float] = []
            for i in pending {
                let x = i % w, y = i / w
                var sum: (Float, Float, Float, Float) = (0, 0, 0, 0), n: Float = 0
                for dy in -1...1 { for dx in -1...1 where dx != 0 || dy != 0 {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, nx < w, ny >= 0, ny < h, known[ny * w + nx] else { continue }
                    // 斜めは距離が √2 なので重みを下げる
                    let wt: Float = (dx == 0 || dy == 0) ? 1 : 0.70710678
                    let j = (ny * w + nx) * 4
                    sum.0 += px[j] * wt; sum.1 += px[j + 1] * wt; sum.2 += px[j + 2] * wt; sum.3 += px[j + 3] * wt
                    n += wt
                } }
                if n > 0 {
                    layer.append(i)
                    values.append(contentsOf: [sum.0 / n, sum.1 / n, sum.2 / n, sum.3 / n])
                } else {
                    stillPending.append(i)
                }
            }
            guard !layer.isEmpty else { return }   // 既知の画素に届かない(通常は来ない)
            for (k, i) in layer.enumerated() {
                px[i * 4] = values[k * 4]; px[i * 4 + 1] = values[k * 4 + 1]
                px[i * 4 + 2] = values[k * 4 + 2]; px[i * 4 + 3] = values[k * 4 + 3]
                known[i] = true
            }
            remaining -= layer.count
            pending = stillPending
        }

        // 2. 緩和(ガウス・ザイデル。走査順は固定)
        if relaxIterations > 0 {
            for _ in 0..<relaxIterations {
                for i in holeIdx {
                    let x = i % w, y = i / w
                    var s0: Float = 0, s1: Float = 0, s2: Float = 0, s3: Float = 0, n: Float = 0
                    func add(_ nx: Int, _ ny: Int) {
                        guard nx >= 0, nx < w, ny >= 0, ny < h else { return }
                        let j = (ny * w + nx) * 4
                        s0 += px[j]; s1 += px[j + 1]; s2 += px[j + 2]; s3 += px[j + 3]; n += 1
                    }
                    add(x - 1, y); add(x + 1, y); add(x, y - 1); add(x, y + 1)
                    if n > 0 { px[i * 4] = s0 / n; px[i * 4 + 1] = s1 / n; px[i * 4 + 2] = s2 / n; px[i * 4 + 3] = s3 / n }
                }
            }
        }

        for i in holeIdx {
            for c in 0..<4 { rgba[i * 4 + c] = UInt8(max(0, min(255, px[i * 4 + c].rounded()))) }
        }
    }

    /// 穴を `radius` 画素ぶん広げる(縁の色にじみを穴に含めるため)。4 近傍を radius 回。
    public static func dilated(_ hole: [Bool], width w: Int, height h: Int, radius: Int) -> [Bool] {
        guard radius > 0, w > 0, h > 0, hole.count == w * h else { return hole }
        var cur = hole
        for _ in 0..<radius {
            var next = cur
            for y in 0..<h { for x in 0..<w where !cur[y * w + x] {
                if (x > 0 && cur[y * w + x - 1]) || (x < w - 1 && cur[y * w + x + 1])
                    || (y > 0 && cur[(y - 1) * w + x]) || (y < h - 1 && cur[(y + 1) * w + x]) { next[y * w + x] = true }
            } }
            cur = next
        }
        return cur
    }

    // MARK: CIImage 経路(Renderer から呼ぶ)

    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false, .cacheIntermediates: false])
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    /// `img` のうち `holeMask`(白 = 除去する領域。`img` と同じ座標)を周囲で埋めた画像。
    /// `maxSide` が指定されれば、その長辺へ縮小して埋めた絵を拡大して使う(プレビュー用)。nil ならフル解像度。
    /// マスクの縁の少し外までを穴にして(`edgeGrow` 画素)、輪郭のにじみを残さない。
    /// 穴が空(マスクが真っ黒)なら元の画像をそのまま返す。
    public static func apply(_ img: CIImage, holeMask: CIImage, maxSide: Int?, edgeGrow: Int = 2) -> CIImage {
        let ext = img.extent
        guard ext.width >= 1, ext.height >= 1, ext.width.isFinite else { return img }
        let long = max(ext.width, ext.height)
        let scale = (maxSide.map { Double($0) / long } ?? 1).clamped(to: 0.01...1)
        let w = max(1, Int((ext.width * scale).rounded())), h = max(1, Int((ext.height * scale).rounded()))
        let toSmall = CGAffineTransform(translationX: -ext.minX, y: -ext.minY).scaledBy(x: Double(w) / ext.width, y: Double(h) / ext.height)
        let smallRect = CGRect(x: 0, y: 0, width: w, height: h)

        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        ciContext.render(img.transformed(by: toSmall), toBitmap: &rgba, rowBytes: w * 4, bounds: smallRect, format: .RGBA8, colorSpace: colorSpace)
        var m = [UInt8](repeating: 0, count: w * h * 4)
        ciContext.render(holeMask.cropped(to: ext).transformed(by: toSmall), toBitmap: &m, rowBytes: w * 4, bounds: smallRect, format: .RGBA8, colorSpace: colorSpace)
        // CI のビットマップは上端が先頭の行。穴・画素とも同じ並びなので上下の変換は要らない。
        var hole = [Bool](repeating: false, count: w * h)
        for i in 0..<(w * h) { hole[i] = m[i * 4] > 127 }
        guard hole.contains(true) else { return img }
        hole = dilated(hole, width: w, height: h, radius: edgeGrow)
        fill(rgba: &rgba, width: w, height: h, hole: hole)

        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: colorSpace,
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
                               decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return img }
        let filled = CIImage(cgImage: cg)
            .transformed(by: CGAffineTransform(scaleX: ext.width / Double(w), y: ext.height / Double(h)))
            .transformed(by: CGAffineTransform(translationX: ext.minX, y: ext.minY))
            .cropped(to: ext)
        // 穴の外は元の画素。穴の縁(マスクの外へ広げた分)も置き換える
        let grow = Double(edgeGrow) / scale
        let blendMask = grow > 0.5
            ? holeMask.cropped(to: ext).applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: grow]).cropped(to: ext)
            : holeMask.cropped(to: ext)
        return filled.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: img,
            kCIInputMaskImageKey: blendMask,
        ]).cropped(to: ext)
    }
}

private extension Double {
    func clamped(to r: ClosedRange<Double>) -> Double { min(max(self, r.lowerBound), r.upperBound) }
}
