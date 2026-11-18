import Foundation
import CoreImage

/// 映像ノイズ除去(監査 #59 / W3-22)。Core Image の `CINoiseReduction` を使う空間方向のノイズ低減。
///
/// 方式と限界(正直な仕様):
/// - 学習型(AI)デノイズではない。`CINoiseReduction` は近傍の平滑化で粒状ノイズを抑える古典的な処理で、
///   強くかけるほど細部(髪・文字の縁など)も一緒に鈍る。
/// - 時間方向(前後のコマとの比較)は使わない。コマごとに独立に処理するので、プレビューと書き出しで
///   同じ入力には同じ結果になり、ちらつき(テンポラルフリッカー)の低減は限定的。
/// - 引数: strength(0〜1)が全体の強さ。内部では noiseLevel = 0.02 + 0.28 × strength、
///   sharpness = 0.4 × (1 − strength) に写す(実測: noiseLevel 0.3 付近で平滑が飽和し、
///   sharpness を上げると逆に粒が立つため、強さと逆向きにしている)。
/// - strength が 0 以下・範囲が空なら入力をそのまま返す(描画不変)。
public enum VideoDenoise {
    /// ノイズ量(0〜1 の強さ → CINoiseReduction の inputNoiseLevel)。
    public static func noiseLevel(forStrength strength: Double) -> Double {
        let s = min(max(strength, 0), 1)
        return 0.02 + 0.28 * s
    }

    /// 輪郭の保持(強さ → inputSharpness)。強いほど小さくする。
    public static func sharpness(forStrength strength: Double) -> Double {
        let s = min(max(strength, 0), 1)
        return 0.4 * (1 - s)
    }

    public static func apply(_ image: CIImage, strength: Double) -> CIImage {
        let rect = image.extent
        guard strength > 1e-6, !rect.isInfinite, !rect.isEmpty else { return image }
        let out = image.applyingFilter("CINoiseReduction", parameters: [
            "inputNoiseLevel": noiseLevel(forStrength: strength),
            "inputSharpness": sharpness(forStrength: strength),
        ])
        return out.cropped(to: rect)
    }
}
