import Foundation
import CoreGraphics
import CoreImage

// MARK: - ベベル共通基盤(Bevel Alpha / Bevel & Emboss)
//
// ベベル系 2 種の共有基盤。Premiere の Bevel Alpha / Bevel & Emboss の厳密な再現ではなく、
// 見た目の等価機能として Core Image の組み込みフィルタだけで組み立てる(カスタムカーネルは使わない)。
//
// 方式:
//   ① 場(field)を作る。Bevel Alpha はアルファそのもの、Bevel & Emboss は輝度。
//      どちらも「値が高い所ほど手前にある」とみなせる単一チャンネルの絵(グレー・アルファ 1)に直す。
//   ② 場を柔らかさ(softness)でガウスぼかしする(斜面のなだらかさ)。
//   ③ ぼかした場を、光の方向へ進んだ位置で読んだもの(S+)と、逆へ進んだ位置で読んだもの(S−)を作り、
//      傾きの符号で分ける: ハイライト = clamp(S− − S+)、シャドウ = clamp(S+ − S−)。
//      これは方向微分 −(∇場 · 光方向) の符号分割で、平らな所(場が一定)では両方とも 0 になる。
//      減算は CISubtractBlendMode(= clamp(背景 − 前景)、実測で確認)を使う。
//   ④ ハイライトは白・シャドウは黒のシルエット(アルファ = マスク × 強さ)に直し、
//      元のアルファの内側だけに絞って(CIBlendWithAlphaMask)から元の絵へ重ねる。
//      そのためベベルは輪郭の内側だけに付き、シルエットは広がらない(Premiere の Bevel Alpha と同じ考え方)。
//
// 座標と角度: 角度は「光源がある向き」を画面の右を 0°、反時計回りを正とする(CI 座標は y 上向き)。
// 既定の 135° は左上からの光。引数の px は呼び出し側(EffectPipeline)が解像度に合わせて拡縮してから渡す。
public enum Bevel {
    /// 場の取り方。Bevel Alpha = アルファ、Bevel & Emboss = 輝度。
    public enum Field: Sendable { case alpha, luminance }

    /// 輝度場の差は小さい(階調の差がそのまま出る)ので、エンボス側ではマスクをこの倍率で持ち上げる。
    public static let luminanceGain = 2.5

    /// 光の向き(単位ベクトル、CI 座標・y 上向き)。角度は右が 0°、反時計回りが正。
    public static func lightVector(angleDegrees: Double) -> CGPoint {
        let a = (angleDegrees.isFinite ? angleDegrees : 135) * Double.pi / 180
        return CGPoint(x: cos(a), y: sin(a))
    }

    /// アルファを場にした絵(R=G=B=アルファ、アルファは 1)。
    static func alphaField(_ image: CIImage, rect: CGRect) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 1), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 1), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ]).cropped(to: rect)
    }

    /// 輝度(Rec.709)を場にした絵(R=G=B=輝度、アルファは 1)。色の計算は非乗算済みの色に対して行われる
    /// (CIColorMatrix の作法)ため、半透明の所では「見た目」ではなく元の色の明るさで傾きが決まる。
    static func luminanceField(_ image: CIImage, rect: CGRect) -> CIImage {
        let row = CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": row, "inputGVector": row, "inputBVector": row,
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ]).cropped(to: rect)
    }

    /// マスク(R に値が入ったグレー絵)を、白または黒のシルエット(アルファ = R × 強さ)に直す。
    static func silhouette(mask: CIImage, white: Bool, strength: Double) -> CIImage {
        let b = white ? 1.0 : 0.0
        return mask.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: strength, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: b, y: b, z: b, w: 0),
        ])
    }

    /// レイヤーを元の絵のアルファの内側だけに絞る(透明な所へはみ出さない)。
    static func clippedInside(_ layer: CIImage, of image: CIImage, rect: CGRect) -> CIImage {
        let clear = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: rect)
        return layer.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: clear, kCIInputMaskImageKey: image,
        ]).cropped(to: rect)
    }

    /// ベベルをかける。`size` は斜面の厚み(画素、光方向への読みずらし量)、`softness` はぼかしの σ(画素)。
    /// `highlight` / `shadow` は 0〜1 の強さ。大きさが 0.05 以下・強さが両方 0・範囲が空/無限なら何もしない。
    public static func apply(_ image: CIImage, field: Field, size: Double, angleDegrees: Double,
                             softness: Double, highlight: Double, shadow: Double) -> CIImage {
        let rect = image.extent
        guard size.isFinite, size > 0.05, !rect.isInfinite, !rect.isEmpty else { return image }
        let gain = field == .luminance ? luminanceGain : 1.0
        let hiK = min(max(highlight, 0), 1) * gain, shK = min(max(shadow, 0), 1) * gain
        guard hiK > 1e-6 || shK > 1e-6 else { return image }

        let base = field == .alpha ? alphaField(image, rect: rect) : luminanceField(image, rect: rect)
        var blurred = base.clampedToExtent()
        let sigma = softness.isFinite ? max(softness, 0) : 0
        if sigma > 0.05 { blurred = blurred.applyingGaussianBlur(sigma: sigma) }
        blurred = blurred.cropped(to: rect)

        // S+: 光の方向へ進んだ位置で読む = 絵を光と逆向きへずらす。S− はその逆。
        // ずらして読む元は端を延ばした絵にする(範囲の外を 0 で読むと、絵の境界そのものが輪郭になってしまう)。
        let v = lightVector(angleDegrees: angleDegrees)
        let extended = blurred.clampedToExtent()
        let toward = extended.transformed(by: CGAffineTransform(translationX: -v.x * size, y: -v.y * size)).cropped(to: rect)
        let away = extended.transformed(by: CGAffineTransform(translationX: v.x * size, y: v.y * size)).cropped(to: rect)

        // CISubtractBlendMode は clamp(背景 − 前景)。ハイライト = clamp(S− − S+)、シャドウ = clamp(S+ − S−)。
        var out = image
        if shK > 1e-6 {
            let mask = away.applyingFilter("CISubtractBlendMode", parameters: [kCIInputBackgroundImageKey: toward])
            out = clippedInside(silhouette(mask: mask, white: false, strength: shK), of: image, rect: rect).composited(over: out)
        }
        if hiK > 1e-6 {
            let mask = toward.applyingFilter("CISubtractBlendMode", parameters: [kCIInputBackgroundImageKey: away])
            out = clippedInside(silhouette(mask: mask, white: true, strength: hiK), of: image, rect: rect).composited(over: out)
        }
        return out.cropped(to: rect)
    }
}

// MARK: - 放射ブラー(ズーム方向が基本、回転も選べる)

/// 放射ブラー: 中心点から放射方向へ流れるぼかし。方式(mode)で選ぶ:
/// - ズーム(0・既定): 中心のまわりに少しずつ拡縮したコピーを均等に足し合わせる(放射状の streak)。
///   絵の端は延ばして読むので縁が暗くならない。`SpinBlur` と同じ畳み込みの考え方で、変換が回転ではなく拡縮。
/// - 回転(1): 既存の `SpinBlur` に委譲する(量 100 で 90° に写す)。
/// 中心は呼び出し側が画素座標(CI 座標)で渡す。量が 0.05 以下・範囲が空/無限なら何もしない。
public enum RadialBlur {
    /// 方式。引数の値(0/1)から作る。数でない・範囲外はズーム。
    public enum Mode: Int, Sendable { case zoom = 0, spin = 1 }

    public static func mode(value: Double) -> Mode {
        guard value.isFinite else { return .zoom }
        return Mode(rawValue: min(max(Int(value.rounded()), 0), 1)) ?? .zoom
    }

    /// ズーム方式のサンプル数。
    public static let steps = 12
    /// 量 100 のときの拡縮の広がり(中心から ±この割合)。量に比例する。
    public static let maxZoom = 0.3
    /// 回転方式で、量を回転角(°)へ写す倍率(量 100 → 90°)。
    public static let spinDegreesPerAmount = 0.9

    public static func spinDegrees(forAmount amount: Double) -> Double { amount * spinDegreesPerAmount }

    public static func apply(_ image: CIImage, center: CGPoint, amount: Double, mode: Mode) -> CIImage {
        let rect = image.extent
        guard amount.isFinite, amount > 0.05, !rect.isInfinite, !rect.isEmpty else { return image }
        switch mode {
        case .spin:
            return SpinBlur.apply(image, center: center, angleDegrees: spinDegrees(forAmount: amount))
        case .zoom:
            let src = image.clampedToExtent()
            let spread = min(max(amount, 0), 100) / 100 * maxZoom
            let w = 1.0 / Double(steps)
            var acc: CIImage? = nil
            for i in 0..<steps {
                let f = Double(i) / Double(steps - 1) - 0.5
                let s = 1 + f * 2 * spread
                var t = CGAffineTransform(translationX: center.x, y: center.y)
                t = t.scaledBy(x: CGFloat(s), y: CGFloat(s))
                t = t.translatedBy(x: -center.x, y: -center.y)
                // SpinBlur と同じ作法: 色はそのまま、アルファだけ 1/steps にして足し合わせる。
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
}
