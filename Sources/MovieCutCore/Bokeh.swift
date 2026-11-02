import Foundation
import CoreGraphics
import CoreImage

// MARK: - 絞り形のボケ(背景ぼかしの形を選ぶ)
//
// ふつうのぼかし(ガウス)は、点の光がなめらかな山になる。実際のレンズでは、点の光が絞り(羽根)の形 ―― 円・五角形・六角形・星 ―― の
// 平たい円盤になる。ここでは、その形の内側に細かく並べたずらし位置で、画像のコピーを均等に足し合わせて(形の畳み込み)作る。
//   ① 形の内側に、六方格子の点を ~`targetSamples` 個置く(重心が中心に来るよう平行移動)。
//   ② 点の間の隙間が縞にならないよう、元の絵に小さなガウスぼかし(σ ≈ 点の間隔の半分)をかけてから、ずらして足す。
//   ③ ハイライトの強調: しきい値を超えた明るい部分だけを同じ形でぼかし、スクリーン合成で足す(明るい光源が、はっきりした円盤になる)。
// 絵の外側は端を延ばして読む(縁が暗くならない)。CoreImage の純粋な処理で、プレビューと書き出しで同じ結果になる。

/// 絞りの形。`rawValue` はエフェクトの引数(0〜7)。クリップの保存では `name`(英字)で書く。
public enum ApertureShape: Int, CaseIterable, Sendable {
    case circle = 0, triangle, square, pentagon, hexagon, octagon, star, heart

    public var label: String {
        switch self {
        case .circle: return "円"
        case .triangle: return "三角形"
        case .square: return "四角形"
        case .pentagon: return "五角形"
        case .hexagon: return "六角形"
        case .octagon: return "八角形"
        case .star: return "星"
        case .heart: return "ハート"
        }
    }

    /// ファイルに書く名前。
    public var name: String {
        switch self {
        case .circle: return "circle"
        case .triangle: return "triangle"
        case .square: return "square"
        case .pentagon: return "pentagon"
        case .hexagon: return "hexagon"
        case .octagon: return "octagon"
        case .star: return "star"
        case .heart: return "heart"
        }
    }

    /// 名前から。知らない名前・nil は円。
    public init(name: String?) {
        self = ApertureShape.allCases.first { $0.name == name } ?? .circle
    }

    /// エフェクトの引数の値(0〜7。小数・範囲外は丸めて収める。数でないものは円)。
    public init(value v: Double) {
        guard v.isFinite else { self = .circle; return }
        self = ApertureShape(rawValue: min(max(Int(v.rounded()), 0), ApertureShape.allCases.count - 1)) ?? .circle
    }

    /// 外接円の半径 1 の多角形(円は nil)。最初の頂点は真上。回転は度(時計回りが正)。座標は y 上向き。
    public func polygon(rotation degrees: Double = 0) -> [CGPoint]? {
        var pts: [CGPoint]
        func regular(_ n: Int) -> [CGPoint] {
            (0..<n).map { i in
                let a = Double.pi / 2 - 2 * Double.pi * Double(i) / Double(n)       // 真上から時計回り
                return CGPoint(x: cos(a), y: sin(a))
            }
        }
        switch self {
        case .circle: return nil
        case .triangle: pts = regular(3)
        case .square: pts = regular(4).map { CGPoint(x: $0.x, y: $0.y) }
        case .pentagon: pts = regular(5)
        case .hexagon: pts = regular(6)
        case .octagon: pts = regular(8)
        case .star:
            pts = (0..<10).map { i in
                let a = Double.pi / 2 - 2 * Double.pi * Double(i) / 10, r = i % 2 == 0 ? 1.0 : 0.42
                return CGPoint(x: r * cos(a), y: r * sin(a))
            }
        case .heart:
            // 古典的なハートの曲線を、外接円の半径 1 に収める
            let raw = (0..<48).map { i -> CGPoint in
                let t = 2 * Double.pi * Double(i) / 48
                return CGPoint(x: 16 * pow(sin(t), 3), y: 13 * cos(t) - 5 * cos(2 * t) - 2 * cos(3 * t) - cos(4 * t))
            }
            let cy = (raw.map(\.y).max()! + raw.map(\.y).min()!) / 2
            let shifted = raw.map { CGPoint(x: $0.x, y: $0.y - cy) }
            let m = shifted.map { hypot($0.x, $0.y) }.max()!
            pts = shifted.map { CGPoint(x: $0.x / m, y: $0.y / m) }
        }
        guard degrees != 0 else { return pts }
        let a = -degrees * Double.pi / 180                        // y 上向きでの時計回り
        let c = cos(a), s = sin(a)
        pts = pts.map { CGPoint(x: $0.x * c - $0.y * s, y: $0.x * s + $0.y * c) }
        return pts
    }
}

public enum Bokeh {
    /// 形の内側に置くずらし位置の目標の数(実際は形の面積に応じて前後する)。
    public static let targetSamples = 80
    /// ぼかし範囲(背景ぼかし)の絞りぼかしで使う、ハイライトの強調の強さ。
    public static let regionHighlight = 0.3
    /// ハイライトの強調で、明るい部分とみなす輝度のしきい値。
    public static let highlightThreshold = 0.72

    /// 多角形の内側か(偶奇規則)。
    static func inside(_ p: CGPoint, polygon pts: [CGPoint]) -> Bool {
        var inside = false
        var j = pts.count - 1
        for i in 0..<pts.count {
            let a = pts[i], b = pts[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }

    static func area(of pts: [CGPoint]) -> Double {
        var s = 0.0
        for i in 0..<pts.count { let a = pts[i], b = pts[(i + 1) % pts.count]; s += a.x * b.y - b.x * a.y }
        return abs(s) / 2
    }

    /// 形の内側のずらし位置(画素。y 上向き)と、点の間隔。重心が原点に来る。`radius` が小さすぎる・形が作れないときは原点 1 点。
    public static func offsets(shape: ApertureShape, radius: Double, rotation: Double = 0, target: Int = targetSamples) -> (points: [CGPoint], spacing: Double) {
        guard radius.isFinite, radius > 0.5 else { return ([.zero], 0) }
        let poly = shape.polygon(rotation: rotation)
        let unitArea = poly.map(area(of:)) ?? Double.pi
        let areaPx = unitArea * radius * radius
        // 六方格子(行の間隔 = d·√3/2)の密度は 1 / (d² · √3/2)
        let n = Double(max(1, target))
        let d = max(1, (areaPx / (n * 0.8660254)).squareRoot())
        var pts: [CGPoint] = []
        let rowH = d * 0.8660254
        let reach = radius * 1.001
        var row = 0
        var y = -reach
        while y <= reach {
            var x = -reach + (row % 2 == 0 ? 0 : d / 2)
            while x <= reach {
                let p = CGPoint(x: x, y: y)
                let ok: Bool
                if let poly { ok = inside(CGPoint(x: p.x / radius, y: p.y / radius), polygon: poly) } else { ok = hypot(p.x, p.y) <= radius }
                if ok { pts.append(p) }
                x += d
            }
            y += rowH; row += 1
        }
        guard !pts.isEmpty else { return ([.zero], d) }
        // 重心を原点へ(格子の端の取りこぼしで偏らない)
        let cx = pts.map(\.x).reduce(0, +) / Double(pts.count), cy = pts.map(\.y).reduce(0, +) / Double(pts.count)
        return (pts.map { CGPoint(x: $0.x - cx, y: $0.y - cy) }, d)
    }

    /// `image` に絞り形のぼかしをかける。`radius` は形の外接円の半径(画素)。`highlight` は 0〜1(0 = 強調なし)。
    /// 半径が 0.5 画素未満・範囲が無限・空のときは何もしない。出力の範囲は入力と同じ。
    public static func apply(_ image: CIImage, radius: Double, shape: ApertureShape, rotation: Double = 0, highlight: Double = 0) -> CIImage {
        let rect = image.extent
        guard radius.isFinite, radius >= 0.5, !rect.isInfinite, !rect.isEmpty else { return image }
        let (offs, spacing) = offsets(shape: shape, radius: radius, rotation: rotation)
        let sigma = max(0.5, 0.5 * spacing)
        func convolve(_ src: CIImage) -> CIImage {
            let w = 1 / Double(offs.count)
            // CIColorMatrix は色を「アルファで割った値」に対して行列をかけ、結果にアルファを掛け直す。
            // 色もアルファも w 倍にすると色が w² 倍になってしまうので、アルファだけを w 倍する(掛け直しで色もちょうど w 倍になる)
            let scaled = src.clampedToExtent().applyingGaussianBlur(sigma: sigma).applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 1, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: w),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            ])
            var acc: CIImage?
            for o in offs {
                let t = scaled.transformed(by: CGAffineTransform(translationX: o.x, y: o.y))
                acc = acc.map { t.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: $0]) } ?? t
            }
            return (acc ?? scaled).cropped(to: rect)
        }
        let base = convolve(image)
        let h = min(max(highlight, 0), 1)
        guard h > 1e-6 else { return base }
        // 明るい部分を同じ形でぼかして、強さ 2h で足す(スクリーン合成なので白飛びしにくい)
        let k = 2 * h
        let boosted = convolve(OpticalMist.highlights(of: image, threshold: highlightThreshold)).applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0),
        ])
        return boosted.applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: base]).cropped(to: rect)
    }
}
