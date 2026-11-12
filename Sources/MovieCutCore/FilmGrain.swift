import Foundation
import CoreImage

/// フィルムグレイン(フィルムの粒)。画像・引数・大きさだけで決まる純粋な処理。
///
/// 組み立て: ①`CIRandomGenerator` のノイズを粒の大きさに粗くする(`CIPixellate`)→ ②輝度を
/// 中央(0.5)から強さぶん広げたグレーの絵にし、`CISoftLightBlendMode` で元の絵に重ねる
/// (0.5 の所は元のまま、明るい粒は明るく・暗い粒は暗く) → ③最後に元のアルファで覆い直す
/// (`CIBlendWithAlphaMask`)ので、透明な所には乗らず、アルファは元のままになる。
/// ノイズは描くたびに変わるので、連続するコマでは粒がちらつく(フィルムの粒らしさ)。
/// 静止画・書き出しでは 1 回の描画ごとに 1 枚ぶんの粒が乗る。
/// なお足し算で直接足す方法は、Core Image が乗算済みアルファで処理するため透明な所の
/// 色が消えてしまう(アルファ 0 の増減分は足せない)。そのためブレンド+覆い直しの形にした。
public enum FilmGrain {
    /// `amount` は粒の強さ(0〜1)。`size` は粒の大きさ(画素、そのまま)。
    public static func apply(_ image: CIImage, amount: Double, size: Double) -> CIImage {
        let rect = image.extent
        guard amount > 1e-6, !rect.isInfinite, !rect.isEmpty else { return image }
        guard let raw = CIFilter(name: "CIRandomGenerator")?.outputImage else { return image }
        var noise = raw.cropped(to: rect)
        let px = max(1, size)
        if px > 1.5 {
            noise = noise.applyingFilter("CIPixellate", parameters: [
                "inputCenter": CIVector(x: rect.minX, y: rect.minY), "inputScale": px,
            ]).cropped(to: rect)
        }
        // 輝度を中央 0.5 から強さぶん広げる(アルファは 1 = ブレンドの覆いとして使う)。
        let a = amount, kr = 0.2126 * a, kg = 0.7152 * a, kb = 0.0722 * a, bias = 0.5 - 0.5 * a
        let row = CIVector(x: kr, y: kg, z: kb, w: 0)
        let grain = noise.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": row, "inputGVector": row, "inputBVector": row,
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 1),
        ])
        let blended = grain.applyingFilter("CISoftLightBlendMode", parameters: [kCIInputBackgroundImageKey: image])
        // ブレンドは透明な所のアルファも上げてしまうので、元のアルファで覆い直す。
        let clear = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: rect)
        return blended.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: clear, kCIInputMaskImageKey: image,
        ]).cropped(to: rect)
    }
}
