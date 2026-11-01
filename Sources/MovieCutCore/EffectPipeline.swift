import Foundation
import CoreGraphics
import CoreImage

/// 時刻を決めて、引数の値を確定させたエフェクト(キーフレーム込み・範囲に収めた後)。
public struct ResolvedEffect: Equatable, Sendable {
    public var kind: EffectKind
    public var values: [String: Double]
    public var color: String
    public var path: String? = nil

    public func v(_ key: String) -> Double { values[key] ?? kind.spec(key)?.defaultValue ?? 0 }
}

/// エフェクトを CIFilter の連なりにして画像にかける(UI にも Undo にも依存しない純粋な処理)。
///
/// - 入力はクリップ 1 枚ぶんの画素(透明な背景に、回転・拡大・切り抜きまで済んだクリップを描いたもの)。出力も同じ範囲(はみ出しは切る)。
///   不透明度・トランジションのマスクはこの後にかかるので、エフェクトはクリップ自身の画素だけに効く。
/// - ぼかし・シャープ・ズーム/モーションは `clampedToExtent` してから処理し、範囲の縁が暗くならないようにする。
/// - px の引数は 1920×1080 での大きさ。`scale`(= √(幅×高さ / (1920×1080)))で解像度に合わせる。
/// - プレビューと書き出しは同じ経路(Renderer)でこれを呼ぶので、見た目は同じ。
public enum EffectPipeline {
    /// 引数が「何もしない」値のとき true(速い道に戻す判定)。
    static func isIdentity(_ k: EffectKind, _ v: (String) -> Double) -> Bool {
        let eps = 1e-6
        switch k {
        case .brightness: return abs(v("amount")) < eps
        case .contrast: return abs(v("amount") - 1) < eps
        case .saturation: return abs(v("amount") - 1) < eps
        case .hue: return abs(v("degrees")) < eps
        case .exposure: return abs(v("ev")) < eps
        case .sharpen: return v("amount") < eps
        case .mono, .sepia: return v("amount") < eps
        case .vignette: return v("intensity") < eps
        case .pixelate: return false
        case .gaussianBlur: return v("radius") < eps
        case .zoomBlur: return v("amount") < eps
        case .motionBlur: return v("radius") < eps
        case .glow: return v("intensity") < eps || v("radius") < eps
        case .dropShadow: return v("opacity") < eps
        case .outline: return false
        case .chromaKey: return false
        case .lut: return v("intensity") < eps
        case .faceBlur: return v("strength") < eps
        case .whiteBalance: return abs(v("temperature")) < eps && abs(v("tint")) < eps
        case .colorWheels: return v("liftAmount") < eps && v("gammaAmount") < eps && v("gainAmount") < eps
        }
    }

    /// クリップの時刻 `r`(頭からの秒)で効くエフェクトの列(無効・未知・何もしないものを除く)。キーが無ければ設定値そのまま(速い)。
    public static func resolve(_ c: Clip, atClipTime r: Double) -> [ResolvedEffect] {
        var out: [ResolvedEffect] = []
        for (i, e) in c.effects.enumerated() {
            guard e.enabled, let kind = e.known else { continue }
            var vals: [String: Double] = [:]
            for s in kind.params {
                var v = e.value(s.key)
                if !c.keyframes.isEmpty, let ks = c.keyframes[EffectKey.make(i, s.key)], let kv = Animation.interpolate(ks, at: r) { v = s.clamp(kv) }
                vals[s.key] = v
            }
            if isIdentity(kind, { vals[$0] ?? 0 }) { continue }
            if kind == .lut, (e.path ?? "").isEmpty { continue }
            out.append(ResolvedEffect(kind: kind, values: vals, color: e.colorOrDefault, path: e.path))
        }
        return out
    }

    /// エフェクトが絵の外へはみ出す、最大の幅(画素)。作業用の範囲をこれだけ広げる。
    public static func margin(of fx: [ResolvedEffect], scale: Double) -> Double {
        var m = 0.0
        for e in fx {
            switch e.kind {
            case .gaussianBlur: m += 3 * e.v("radius") * scale
            case .motionBlur: m += e.v("radius") * scale
            case .glow: m += 3 * e.v("radius") * scale * 0.5
            case .dropShadow: m += max(abs(e.v("dx")), abs(e.v("dy"))) * scale + 3 * e.v("blur") * scale * 0.5
            case .outline: m += e.v("width") * scale
            default: break
            }
        }
        return m
    }

    private static func vec(_ x: Double, _ y: Double, _ z: Double, _ w: Double) -> CIVector { CIVector(x: x, y: y, z: z, w: w) }

    private static func ciColor(_ hex: String) -> CIColor {
        let cg = parseHexColor(hex) ?? CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        let c = cg.components ?? [0, 0, 0, 1]
        return CIColor(red: c[0], green: c.count > 2 ? c[1] : c[0], blue: c.count > 2 ? c[2] : c[0], alpha: 1)
    }

    /// 範囲の縁を延ばしてから処理し、元の範囲に切り戻す。
    private static func clamped(_ img: CIImage, _ rect: CGRect, _ f: (CIImage) -> CIImage) -> CIImage {
        f(img.clampedToExtent()).cropped(to: rect)
    }

    /// 形(アルファ)だけを残して、色 `hex`・不透明度 `opacity` に塗りつぶした影絵。
    private static func silhouette(_ img: CIImage, color hex: String, opacity: Double) -> CIImage {
        let c = ciColor(hex)
        return img.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": vec(0, 0, 0, 0), "inputGVector": vec(0, 0, 0, 0), "inputBVector": vec(0, 0, 0, 0),
            "inputAVector": vec(0, 0, 0, opacity), "inputBiasVector": vec(Double(c.red), Double(c.green), Double(c.blue), 0),
        ])
    }

    /// `bounds` はクリップの枠(画像の座標・左下原点)。ビネットの中心や、ズームぼかしの中心、モザイクの格子の基準に使う。
    /// `faces` は顔の検出枠(0〜1・左上原点)。顔ぼかしのエフェクトが使う。無ければ顔ぼかしは何もしない。
    public static func apply(_ image: CIImage, effects: [ResolvedEffect], bounds: CGRect, scale: Double, faces: [CGRect] = []) -> CIImage {
        let rect = image.extent
        var img = image
        for e in effects {
            img = applyOne(e, img, rect: rect, bounds: bounds, scale: scale, faces: faces)
        }
        return img
    }

    static func applyOne(_ e: ResolvedEffect, _ img: CIImage, rect: CGRect, bounds: CGRect, scale: Double, faces: [CGRect] = []) -> CIImage {
        let center = CIVector(x: bounds.midX, y: bounds.midY)
        switch e.kind {
        case .brightness:
            return img.applyingFilter("CIColorControls", parameters: ["inputBrightness": e.v("amount"), "inputContrast": 1, "inputSaturation": 1])
        case .contrast:
            return img.applyingFilter("CIColorControls", parameters: ["inputBrightness": 0, "inputContrast": e.v("amount"), "inputSaturation": 1])
        case .saturation:
            return img.applyingFilter("CIColorControls", parameters: ["inputBrightness": 0, "inputContrast": 1, "inputSaturation": e.v("amount")])
        case .hue:
            return img.applyingFilter("CIHueAdjust", parameters: ["inputAngle": e.v("degrees") * Double.pi / 180])
        case .exposure:
            return img.applyingFilter("CIExposureAdjust", parameters: ["inputEV": e.v("ev")])
        case .sharpen:
            return clamped(img, rect) { $0.applyingFilter("CISharpenLuminance", parameters: ["inputSharpness": e.v("amount"), "inputRadius": 1.69 * scale]) }
        case .mono:
            // 輝度(Rec.709)と元の色を amount で混ぜる。amount = 1 で R = G = B
            let a = e.v("amount"), kr = 0.2126, kg = 0.7152, kb = 0.0722
            return img.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": vec(1 - a + a * kr, a * kg, a * kb, 0),
                "inputGVector": vec(a * kr, 1 - a + a * kg, a * kb, 0),
                "inputBVector": vec(a * kr, a * kg, 1 - a + a * kb, 0),
                "inputAVector": vec(0, 0, 0, 1), "inputBiasVector": vec(0, 0, 0, 0),
            ])
        case .sepia:
            return img.applyingFilter("CISepiaTone", parameters: ["inputIntensity": e.v("amount")])
        case .vignette:
            // 枠の中心から外へ向けて黒く(アルファはそのまま = 透明な所は透明のまま)
            let half = max(1, hypot(bounds.width, bounds.height) / 2)
            let r = e.v("radius")
            let inner = max(0, r * half * 0.55), outer = max(inner + 1, r * half * 1.15)
            let a = min(1, e.v("intensity") * 0.8)
            let grad = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": center, "inputRadius0": inner, "inputRadius1": outer,
                "inputColor0": CIColor(red: 0, green: 0, blue: 0, alpha: 0), "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: a),
            ])?.outputImage
            guard let g = grad else { return img }
            return g.applyingFilter("CISourceAtopCompositing", parameters: [kCIInputBackgroundImageKey: img]).cropped(to: rect)
        case .pixelate:
            let s = max(2, e.v("size") * scale)
            return clamped(img, rect) { $0.applyingFilter("CIPixellate", parameters: ["inputCenter": CIVector(x: bounds.minX, y: bounds.minY), "inputScale": s]) }
        case .gaussianBlur:
            let sigma = e.v("radius") * scale
            return clamped(img, rect) { $0.applyingGaussianBlur(sigma: sigma) }
        case .zoomBlur:
            return clamped(img, rect) { $0.applyingFilter("CIZoomBlur", parameters: ["inputCenter": center, "inputAmount": e.v("amount") * scale]) }
        case .motionBlur:
            return clamped(img, rect) { $0.applyingFilter("CIMotionBlur", parameters: ["inputRadius": e.v("radius") * scale, "inputAngle": e.v("angle") * Double.pi / 180]) }
        case .glow:
            // ぼかしたものを強さ倍して足す(光がにじむ)
            let sigma = max(0.1, e.v("radius") * scale * 0.5), k = e.v("intensity")
            let blurred = clamped(img, rect) { $0.applyingGaussianBlur(sigma: sigma) }
            let boosted = blurred.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": vec(k, 0, 0, 0), "inputGVector": vec(0, k, 0, 0), "inputBVector": vec(0, 0, k, 0),
                "inputAVector": vec(0, 0, 0, k), "inputBiasVector": vec(0, 0, 0, 0),
            ])
            return boosted.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: img]).cropped(to: rect)
        case .dropShadow:
            // CI は左下原点なので、画面で「下へ dy」は −dy
            var sh = silhouette(img, color: e.color, opacity: e.v("opacity"))
                .transformed(by: CGAffineTransform(translationX: e.v("dx") * scale, y: -e.v("dy") * scale))
            let sigma = e.v("blur") * scale * 0.5
            if sigma > 0.05 { sh = sh.applyingGaussianBlur(sigma: sigma) }
            return img.composited(over: sh).cropped(to: rect)
        case .outline:
            let w = max(1, e.v("width") * scale)
            let ring = silhouette(img, color: e.color, opacity: 1).applyingFilter("CIMorphologyMaximum", parameters: ["inputRadius": w])
            return img.composited(over: ring).cropped(to: rect)
        case .chromaKey:
            return ChromaKey.apply(img, key: e.color, similarity: e.v("similarity"), smoothness: e.v("smoothness"), spill: e.v("spill"))
        case .faceBlur:
            return FaceBlur.apply(img, faces: faces, mode: FaceBlur.Mode(e.v("mode")), strength: e.v("strength"), scale: scale)
        case .whiteBalance:
            // 色温度を上げると「入力の白は青すぎた」と見なして、橙寄りに直す。ティントは緑↔紫(正で紫)
            let neutral = CIVector(x: 6500 + 2500 * e.v("temperature"), y: 100 * e.v("tint"))
            return img.applyingFilter("CITemperatureAndTint", parameters: ["inputNeutral": neutral, "inputTargetNeutral": CIVector(x: 6500, y: 0)])
        case .colorWheels:
            let lift = ColorWheels.Wheel(angle: e.v("liftAngle"), amount: e.v("liftAmount"))
            let gamma = ColorWheels.Wheel(angle: e.v("gammaAngle"), amount: e.v("gammaAmount"))
            let gain = ColorWheels.Wheel(angle: e.v("gainAngle"), amount: e.v("gainAmount"))
            let data = ColorWheels.cubeData(lift: lift, gamma: gamma, gain: gain)
            return img.unpremultiplyingAlpha()
                .applyingFilter("CIColorCube", parameters: ["inputCubeDimension": ColorWheels.dimension, "inputCubeData": data])
                .premultiplyingAlpha()
        case .lut:
            guard let p = e.path, let c = LUTCache.shared.cube(atPath: p) else { return img }
            return LUTApply.apply(img, lut: c.lut, dimension: c.dimension, data: c.data, intensity: e.v("intensity"))
        }
    }

    /// 共有の CIContext で CGImage にする(BGRA8・premultiplied・sRGB)。
    public static func makeImage(_ image: CIImage, from rect: CGRect) -> CGImage? {
        ciContext.createCGImage(image, from: rect, format: .BGRA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }
}
