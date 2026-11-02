import Foundation
import CoreImage

/// 光学ミスト(ハイライトのにじみ)。画像・引数・大きさだけで決まる純粋な処理。
///
/// 組み立て: ①輝度がしきい値を超えた分だけを取り出す(CIColorMatrix で輝度 − しきい値を 1 − しきい値で割り、CIColorClamp で 0〜1 に収め、
/// 元の色に掛ける)→ ②ガウスぼかし(σ = `sigma`、端は延ばして暗くならないように)→ ③量を掛けて
/// CIScreenBlendMode で元の絵に重ねる(白飛びしにくい)。CIBloom は強さと半径しか持たず、しきい値の位置を決められないため使わない。
public enum OpticalMist {
    public static func apply(_ image: CIImage, amount: Double, threshold: Double, sigma: Double) -> CIImage {
        let rect = image.extent
        guard amount > 1e-6, sigma > 1e-3, !rect.isInfinite, !rect.isEmpty else { return image }
        let t = min(max(threshold, 0), 1)
        let k = 1 / max(1 - t, 1e-3)
        let kr = 0.2126 * k, kg = 0.7152 * k, kb = 0.0722 * k
        let bias = -t * k
        // 輝度を全チャンネルへ((L − t) / (1 − t)。アルファは 1 のままにして負の値を後で 0 に収める)
        let luma = image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: kr, y: kg, z: kb, w: 0), "inputGVector": CIVector(x: kr, y: kg, z: kb, w: 0),
            "inputBVector": CIVector(x: kr, y: kg, z: kb, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 1),
        ]).applyingFilter("CIColorClamp", parameters: [
            "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0), "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1),
        ])
        let highlights = image.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: luma])
        let blurred = highlights.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: rect)
        let a = amount
        let weighted = blurred.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: a, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: a, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: a, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: a),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0),
        ])
        return weighted.applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: image]).cropped(to: rect)
    }
}
