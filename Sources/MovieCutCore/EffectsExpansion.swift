import Foundation
import CoreGraphics
import CoreImage

// MARK: - トライトーン / ソラリゼーション(CIColorCube 系)

/// トライトーン: 輝度を「影・中間・ハイライト」の 3 色へ写し、量(amount)で原画と混ぜる。
/// パレットは mode 引数(0〜3)で選ぶ(エフェクトの色は 1 色しか持てないため、色の組はプリセットにする)。
public enum Tritone {
    public static let dimension = 24
    public static let palettes: [(shadow: (Double, Double, Double), mid: (Double, Double, Double), high: (Double, Double, Double))] = [
        ((0.10, 0.12, 0.25), (0.72, 0.62, 0.47), (1.00, 0.95, 0.85)),   // 0 クラシック
        ((0.02, 0.08, 0.25), (0.25, 0.55, 0.85), (0.90, 0.97, 1.00)),   // 1 ブルー
        ((0.22, 0.05, 0.12), (0.85, 0.45, 0.55), (1.00, 0.92, 0.88)),   // 2 ローズ
        ((0.03, 0.15, 0.08), (0.45, 0.75, 0.50), (0.95, 1.00, 0.90)),   // 3 グリーン
    ]

    public static func paletteIndex(_ v: Double) -> Int {
        guard v.isFinite else { return 0 }
        return min(max(Int(v.rounded()), 0), palettes.count - 1)
    }

    static var cache: [String: Data] = [:]
    static let lock = NSLock()

    public static func cubeData(palette: Int, amount: Double) -> Data {
        let a = min(max(amount, 0), 1)
        let key = "t\(palette)-\(Int((a * 100).rounded()))"
        lock.lock(); if let d = cache[key] { lock.unlock(); return d }; lock.unlock()
        let p = palettes[min(max(palette, 0), palettes.count - 1)]
        let n = dimension
        var floats = [Float](repeating: 0, count: n * n * n * 4)
        var i = 0
        for b in 0..<n { for g in 0..<n { for r in 0..<n {
            let rf = Double(r) / Double(n - 1), gf = Double(g) / Double(n - 1), bf = Double(b) / Double(n - 1)
            let l = 0.2126 * rf + 0.7152 * gf + 0.0722 * bf
            let mapped: (Double, Double, Double)
            if l < 0.5 {
                let t = l * 2
                mapped = (p.shadow.0 + (p.mid.0 - p.shadow.0) * t, p.shadow.1 + (p.mid.1 - p.shadow.1) * t, p.shadow.2 + (p.mid.2 - p.shadow.2) * t)
            } else {
                let t = (l - 0.5) * 2
                mapped = (p.mid.0 + (p.high.0 - p.mid.0) * t, p.mid.1 + (p.high.1 - p.mid.1) * t, p.mid.2 + (p.high.2 - p.mid.2) * t)
            }
            floats[i] = Float(rf + (mapped.0 - rf) * a); floats[i + 1] = Float(gf + (mapped.1 - gf) * a)
            floats[i + 2] = Float(bf + (mapped.2 - bf) * a); floats[i + 3] = 1
            i += 4
        } } }
        let data = floats.withUnsafeBufferPointer { Data(buffer: $0) }
        lock.lock(); if cache.count > 64 { cache.removeAll() }; cache[key] = data; lock.unlock()
        return data
    }

    public static func apply(_ image: CIImage, palette: Int, amount: Double) -> CIImage {
        guard amount > 1e-6, !image.extent.isInfinite, !image.extent.isEmpty else { return image }
        return image.unpremultiplyingAlpha()
            .applyingFilter("CIColorCube", parameters: ["inputCubeDimension": dimension, "inputCubeData": cubeData(palette: palette, amount: amount)])
            .premultiplyingAlpha()
    }
}

/// ソラリゼーション: しきい値以上の明るさを反転させる(フィルムのサバティエ効果)。量で原画と混ぜる。
public enum Solarize {
    public static let dimension = 32
    static var cache: [String: Data] = [:]
    static let lock = NSLock()

    public static func cubeData(threshold: Double, amount: Double) -> Data {
        let t = min(max(threshold, 0), 1), a = min(max(amount, 0), 1)
        let key = "s\(Int((t * 100).rounded()))-\(Int((a * 100).rounded()))"
        lock.lock(); if let d = cache[key] { lock.unlock(); return d }; lock.unlock()
        let n = dimension
        var floats = [Float](repeating: 0, count: n * n * n * 4)
        var i = 0
        func f(_ v: Double) -> Double { v + ((v < t ? v : 1 - v) - v) * a }
        for b in 0..<n { for g in 0..<n { for r in 0..<n {
            floats[i] = Float(f(Double(r) / Double(n - 1))); floats[i + 1] = Float(f(Double(g) / Double(n - 1)))
            floats[i + 2] = Float(f(Double(b) / Double(n - 1))); floats[i + 3] = 1
            i += 4
        } } }
        let data = floats.withUnsafeBufferPointer { Data(buffer: $0) }
        lock.lock(); if cache.count > 64 { cache.removeAll() }; cache[key] = data; lock.unlock()
        return data
    }

    public static func apply(_ image: CIImage, threshold: Double, amount: Double) -> CIImage {
        guard amount > 1e-6, !image.extent.isInfinite, !image.extent.isEmpty else { return image }
        return image.unpremultiplyingAlpha()
            .applyingFilter("CIColorCube", parameters: ["inputCubeDimension": dimension, "inputCubeData": cubeData(threshold: threshold, amount: amount)])
            .premultiplyingAlpha()
    }
}

// MARK: - 回転ブラー(放射方向ではなく、中心のまわりに回すぼかし)

/// 回転ブラー: 中心のまわりに少しずつ回したコピーを均等に足し合わせる(絞りぼかしと同じ畳み込みの考え方)。
/// ズームぼかし(放射)とは別物で、円弧状に流れる。端は延ばして読むので縁が暗くならない。
public enum SpinBlur {
    public static let steps = 12

    public static func apply(_ image: CIImage, center: CGPoint, angleDegrees: Double) -> CIImage {
        let rect = image.extent
        guard angleDegrees.isFinite, abs(angleDegrees) > 0.05, !rect.isInfinite, !rect.isEmpty else { return image }
        let src = image.clampedToExtent()
        let w = 1.0 / Double(steps)
        var acc: CIImage? = nil
        for i in 0..<steps {
            let f = Double(i) / Double(steps - 1) - 0.5
            let a = angleDegrees * f * Double.pi / 180
            var t = CGAffineTransform(translationX: center.x, y: center.y)
            t = t.rotated(by: CGFloat(a))
            t = t.translatedBy(x: -center.x, y: -center.y)
            // 色はそのまま、アルファだけ 1/steps にする(乗算済みでは各コピーが w 倍になり、足すと元に戻る)。
            // RGB も一緒に縮めると、CIColorMatrix が非乗算済みの色に効くため二重に暗くなる(実測で確認)。
            let fixed = src.transformed(by: t).applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 1, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: w),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            ])
            acc = acc.map { fixed.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: $0]) } ?? fixed
        }
        return (acc ?? image).cropped(to: rect)
    }
}

// MARK: - 境界ぼかし(中心はシャープ、周辺ほどぼける)

/// 境界ぼかし: 放射グラデーションのマスクで、ぼかした絵を周辺だけに混ぜる。
/// 中心(inner の内側)は元のまま、枠の外周に向けてぼけが強くなる。
public enum EdgeBlur {
    public static func apply(_ image: CIImage, bounds: CGRect, radius: Double, inner: Double) -> CIImage {
        let rect = image.extent
        guard radius.isFinite, radius > 0.05, !rect.isInfinite, !rect.isEmpty else { return image }
        let blurred = image.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: rect)
        let half = max(1, hypot(bounds.width, bounds.height) / 2)
        let k = min(max(inner, 0), 1)
        let r0 = k * half, r1 = max(r0 + 1, half * 1.05)
        guard let grad = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(x: bounds.midX, y: bounds.midY),
            "inputRadius0": r0, "inputRadius1": r1,
            "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: 0),
            "inputColor1": CIColor(red: 1, green: 1, blue: 1, alpha: 1),
        ])?.outputImage else { return image }
        return blurred.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: grad.cropped(to: rect),
        ]).cropped(to: rect)
    }
}

// MARK: - 残像(ずらした半透明コピーを重ねる単一フレーム版)

/// 残像: ずらした半透明のコピーを数枚重ね、ゴースト状の尾を付ける。
/// 本来の残像は過去フレームを使うが、描画は 1 フレーム単位で完結する設計のため、
/// ここでは「同一フレームのずらし重ね」で尾を表現する(時間方向の残像ではない)。
public enum EchoGhost {
    public static let decay = 0.65

    public static func apply(_ image: CIImage, distance: Double, angleDegrees: Double, count: Int, opacity: Double) -> CIImage {
        let rect = image.extent
        guard distance.isFinite, distance > 0.05, count >= 1, opacity > 0.01, !rect.isInfinite, !rect.isEmpty else { return image }
        let rad = angleDegrees * Double.pi / 180
        let dx = cos(rad) * distance, dy = sin(rad) * distance
        var acc = image
        for i in stride(from: count, through: 1, by: -1) {
            let f = opacity * pow(decay, Double(i - 1))
            // 色はそのまま、アルファだけ f 倍にした半透明コピーを重ねる(RGB も縮めると二重に暗くなる)。
            let ghost = image.transformed(by: CGAffineTransform(translationX: dx * Double(i), y: dy * Double(i)))
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 1, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: f),
                    "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                ])
            acc = ghost.composited(over: acc)
        }
        return acc.cropped(to: rect)
    }
}
