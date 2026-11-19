import Foundation

// MARK: - エフェクトの種類と引数

/// エフェクトの引数 1 つ分の仕様(範囲・既定値・インスペクタの刻み)。
public struct EffectParamSpec: Equatable, Sendable {
    public enum Unit: Sendable { case plain, percent, px, degrees, mode, toggle, aperture }
    public let key: String
    public let label: String
    public let range: ClosedRange<Double>
    /// 「追加」したときの値 = 「初期値に戻す」で戻る値。
    public let defaultValue: Double
    public let step: Double
    public let unit: Unit

    public func clamp(_ v: Double) -> Double {
        guard v.isFinite else { return defaultValue }
        return min(max(v, range.lowerBound), range.upperBound)
    }
}

/// クリップにかけられるエフェクトの種類。ファイルには文字列(rawValue)で書く。
/// 知らない文字列は `Effect.kind` にそのまま残し、描くときは何もしない。
public enum EffectKind: String, CaseIterable, Sendable {
    case brightness, contrast, saturation, hue, exposure, sharpen, mono, sepia
    case vignette, pixelate, gaussianBlur, zoomBlur, motionBlur, glow, dropShadow, outline
    case chromaKey, lut, faceBlur
    /// 色調転写: 参照画像の色調(平均と標準偏差)へ寄せる。参照画像の場所は `Effect.path`。
    case colorTransfer
    /// 色温度・ティント(ホワイトバランス)と、持ち上げ・ガンマ・ゲインのカラーホイール。
    case whiteBalance, colorWheels
    /// カラーカーブ: RGB・マスターのトーンカーブと、色相別(色相→色相/彩度/輝度)のカーブ。33³ の CIColorCube で適用する。
    case colorCurves
    /// HSLセカンダリ: 色相・彩度・輝度の範囲で選んだ色だけを補正する(範囲選択は `HSLSelection`)。
    case hslSecondary
    /// 光学ミスト: 明るい所だけをぼかして重ね、ふんわり光らせる(ハイライトのにじみ)。
    case opticalMist
    /// ハイライト補正: 明るい部分だけを白の手前へなめらかに寄せる(フィルム風のトーンの肩)。
    case highlightRolloff
    /// 絞りぼかし: 円・多角形・星・ハートの形のボケ(明るい光が、その形の円盤になる)。
    case bokehBlur
    /// フィルムグレイン: 輝度のノイズを粒状に足す(フィルムの粒)。
    case filmGrain
    /// 汎用加工の拡充(第2波B2・監査#57): 色調・モザイク形状・歪み・網点など。
    case invert, posterize, unsharpMask, edges, crystallize, hexPixelate, pointillize, twirl
    case lensDistortion, halftone, kaleidoscope, tritone, solarize, spinBlur, edgeBlur, echo
    /// 映像ノイズ除去: CINoiseReduction による空間方向の平滑(学習型ではない。方式と限界は VideoDenoise / docs 参照)。
    case denoise

    public var label: String {
        switch self {
        case .brightness: return "明るさ"
        case .contrast: return "コントラスト"
        case .saturation: return "彩度"
        case .hue: return "色相"
        case .exposure: return "露出"
        case .sharpen: return "シャープ"
        case .mono: return "モノクロ"
        case .sepia: return "セピア"
        case .vignette: return "ビネット"
        case .pixelate: return "モザイク"
        case .gaussianBlur: return "ガウスぼかし"
        case .zoomBlur: return "ズームぼかし"
        case .motionBlur: return "モーションぼかし"
        case .glow: return "グロー"
        case .dropShadow: return "ドロップシャドウ"
        case .outline: return "縁取り"
        case .chromaKey: return "クロマキー"
        case .lut: return "LUT"
        case .faceBlur: return "顔ぼかし"
        case .colorTransfer: return "色調転写"
        case .whiteBalance: return "ホワイトバランス"
        case .colorWheels: return "カラーホイール"
        case .colorCurves: return "カラーカーブ"
        case .hslSecondary: return "HSLセカンダリ"
        case .opticalMist: return "光学ミスト"
        case .highlightRolloff: return "ハイライト補正"
        case .bokehBlur: return "絞りぼかし"
        case .filmGrain: return "フィルムグレイン"
        case .invert: return "反転"
        case .posterize: return "ポスタリゼーション"
        case .unsharpMask: return "アンシャープマスク"
        case .edges: return "輪郭抽出"
        case .crystallize: return "結晶モザイク"
        case .hexPixelate: return "六角モザイク"
        case .pointillize: return "点描モザイク"
        case .twirl: return "渦巻き"
        case .lensDistortion: return "レンズ歪み"
        case .halftone: return "網点"
        case .kaleidoscope: return "万華鏡"
        case .tritone: return "トライトーン"
        case .solarize: return "ソラリゼーション"
        case .spinBlur: return "回転ブラー"
        case .edgeBlur: return "境界ぼかし"
        case .echo: return "残像"
        case .denoise: return "ノイズ除去"
        }
    }

    private static func p(_ key: String, _ label: String, _ lo: Double, _ hi: Double, _ def: Double, _ step: Double, _ unit: EffectParamSpec.Unit = .plain) -> EffectParamSpec {
        EffectParamSpec(key: key, label: label, range: lo...hi, defaultValue: def, step: step, unit: unit)
    }

    /// カラーカーブの引数(全 35): トーン 4 本 × 5 点 + 色相→色相/彩度/輝度 × 5 点。キーは `ColorCurves.toneCurves(from:)` / `hueCurves(from:)` と一致させる。
    private static let colorCurvesParams: [EffectParamSpec] = {
        var out: [EffectParamSpec] = []
        let tone: [(String, String)] = [("master", "マスター点"), ("red", "赤点"), ("green", "緑点"), ("blue", "青点")]
        for (key, label) in tone {
            for (i, x) in ColorCurves.anchorX.enumerated() { out.append(p("\(key)\(i)", "\(label)\(i + 1)", 0, 1, x, 0.01)) }
        }
        for i in 0..<5 { out.append(p("hueHue\(i)", "色相→色相 点\(i + 1)", -180, 180, 0, 1, .degrees)) }
        for i in 0..<5 { out.append(p("hueSat\(i)", "色相→彩度 点\(i + 1)", 0, 2, 1, 0.01)) }
        for i in 0..<5 { out.append(p("hueLum\(i)", "色相→輝度 点\(i + 1)", -0.5, 0.5, 0, 0.01)) }
        return out
    }()

    /// 引数の仕様(インスペクタに並ぶ順)。px の値は 1920×1080 での大きさ(解像度に合わせて拡縮する)。
    public var params: [EffectParamSpec] {
        switch self {
        case .brightness: return [Self.p("amount", "明るさ", -1, 1, 0.2, 0.01)]
        case .contrast: return [Self.p("amount", "コントラスト", 0, 3, 1.3, 0.01)]
        case .saturation: return [Self.p("amount", "彩度", 0, 3, 1.5, 0.01)]
        case .hue: return [Self.p("degrees", "色相（°）", -180, 180, 30, 1, .degrees)]
        case .exposure: return [Self.p("ev", "露出（EV）", -3, 3, 0.5, 0.05)]
        case .sharpen: return [Self.p("amount", "強さ", 0, 3, 1, 0.05)]
        case .mono: return [Self.p("amount", "強さ", 0, 1, 1, 0.01, .percent)]
        case .sepia: return [Self.p("amount", "強さ", 0, 1, 1, 0.01, .percent)]
        case .vignette: return [Self.p("intensity", "強さ", 0, 2, 1, 0.01), Self.p("radius", "範囲", 0, 2, 1, 0.01)]
        case .pixelate: return [Self.p("size", "ブロックの大きさ（px）", 2, 100, 12, 1, .px)]
        case .gaussianBlur: return [Self.p("radius", "半径（px）", 0, 100, 8, 1, .px)]
        case .zoomBlur: return [Self.p("amount", "強さ", 0, 60, 20, 1)]
        case .motionBlur: return [Self.p("radius", "半径（px）", 0, 100, 20, 1, .px), Self.p("angle", "向き（°）", -180, 180, 0, 1, .degrees)]
        case .glow: return [Self.p("radius", "広がり（px）", 0, 100, 20, 1, .px), Self.p("intensity", "強さ", 0, 2, 1, 0.01)]
        case .dropShadow: return [Self.p("dx", "横のずれ（px）", -200, 200, 12, 1, .px), Self.p("dy", "縦のずれ（px）", -200, 200, 12, 1, .px),
                                  Self.p("blur", "ぼかし（px）", 0, 100, 10, 1, .px), Self.p("opacity", "濃さ", 0, 1, 0.6, 0.01, .percent)]
        case .outline: return [Self.p("width", "太さ（px）", 1, 30, 6, 1, .px)]
        case .chromaKey: return [Self.p("similarity", "色の許容", 0, 1, 0.4, 0.01, .percent), Self.p("smoothness", "なめらかさ", 0, 1, 0.1, 0.01, .percent),
                                 Self.p("spill", "色かぶりの除去", 0, 1, 0.5, 0.01, .percent)]
        case .lut: return [Self.p("intensity", "強さ", 0, 1, 1, 0.01, .percent)]
        case .colorTransfer: return [Self.p("intensity", "強さ", 0, 1, 1, 0.01, .percent)]
        case .faceBlur: return [Self.p("strength", "強さ", 0, 1, 0.6, 0.01, .percent), Self.p("mode", "方式", 0, 1, 0, 1, .mode),
                                Self.p("size", "モザイクの大きさ（px）", 2, 100, 38, 1, .px), Self.p("track", "顔に追従", 0, 1, 0, 1, .toggle)]
        case .whiteBalance: return [Self.p("temperature", "色温度（青↔橙）", -1, 1, 0, 0.01), Self.p("tint", "ティント（緑↔紫）", -1, 1, 0, 0.01)]
        case .colorWheels: return [
            Self.p("liftAngle", "持ち上げ・色相（°）", -180, 180, 0, 1, .degrees), Self.p("liftAmount", "持ち上げ・強さ", 0, 1, 0, 0.01, .percent),
            Self.p("gammaAngle", "ガンマ・色相（°）", -180, 180, 0, 1, .degrees), Self.p("gammaAmount", "ガンマ・強さ", 0, 1, 0, 0.01, .percent),
            Self.p("gainAngle", "ゲイン・色相（°）", -180, 180, 0, 1, .degrees), Self.p("gainAmount", "ゲイン・強さ", 0, 1, 0, 0.01, .percent),
        ]
        case .colorCurves: return Self.colorCurvesParams
        case .hslSecondary: return [
            Self.p("hueCenter", "色相の中心（°）", 0, 360, 0, 1, .degrees), Self.p("hueWidth", "色相の幅（°）", 0, 360, 90, 1, .degrees),
            Self.p("hueFeather", "色相のぼかし（°）", 0, 180, 45, 1, .degrees),
            Self.p("satMin", "彩度の下限", 0, 1, 0, 0.01), Self.p("satMax", "彩度の上限", 0, 1, 1, 0.01), Self.p("satFeather", "彩度のぼかし", 0, 0.5, 0.1, 0.01),
            Self.p("lumMin", "輝度の下限", 0, 1, 0, 0.01), Self.p("lumMax", "輝度の上限", 0, 1, 1, 0.01), Self.p("lumFeather", "輝度のぼかし", 0, 0.5, 0.1, 0.01),
            Self.p("hueShift", "色相シフト（°）", -180, 180, 0, 1, .degrees), Self.p("satScale", "彩度", 0, 3, 1, 0.01),
            Self.p("exposure", "露出（EV）", -3, 3, 0, 0.05), Self.p("strength", "強さ", 0, 1, 1, 0.01, .percent),
        ]
        case .opticalMist: return [Self.p("amount", "量", 0, 1, 0.5, 0.01, .percent), Self.p("threshold", "しきい値", 0, 1, 0.7, 0.01, .percent),
                                   Self.p("radius", "ぼかし半径（px）", 0, 100, 24, 1, .px)]
        case .highlightRolloff: return [Self.p("knee", "圧縮の始まり", 0, 0.99, HighlightRolloff.defaultKnee, 0.01, .percent)]
        case .bokehBlur: return [Self.p("radius", "ボケの半径（px）", 0, 100, 20, 1, .px), Self.p("shape", "絞りの形", 0, Double(ApertureShape.allCases.count - 1), 0, 1, .aperture),
                                 Self.p("highlight", "ハイライトの強調", 0, 1, 0.3, 0.01, .percent), Self.p("rotation", "形の向き（°）", -180, 180, 0, 1, .degrees)]
        case .filmGrain: return [Self.p("amount", "強さ", 0, 1, 0.35, 0.01, .percent), Self.p("size", "粒の大きさ（px）", 1, 16, 2, 1, .px)]
        case .invert: return [Self.p("amount", "強さ", 0, 1, 1, 0.01, .percent)]
        case .posterize: return [Self.p("levels", "階調数", 2, 16, 6, 1)]
        case .unsharpMask: return [Self.p("radius", "半径（px）", 0, 100, 8, 1, .px), Self.p("intensity", "強さ", 0, 3, 1, 0.05)]
        case .edges: return [Self.p("intensity", "強さ", 0, 10, 3, 0.1)]
        case .crystallize: return [Self.p("size", "結晶の大きさ（px）", 2, 100, 20, 1, .px)]
        case .hexPixelate: return [Self.p("size", "六角の大きさ（px）", 2, 100, 16, 1, .px)]
        case .pointillize: return [Self.p("size", "点の半径（px）", 1, 100, 12, 1, .px)]
        case .twirl: return [Self.p("radius", "半径（px）", 10, 2000, 300, 1, .px), Self.p("angle", "角度（°）", -720, 720, 90, 1, .degrees)]
        case .lensDistortion: return [Self.p("scale", "歪み（−膨らみ↔＋へこみ）", -1, 1, 0.4, 0.01), Self.p("radius", "半径（px）", 10, 3000, 800, 1, .px)]
        case .halftone: return [Self.p("width", "網点の間隔（px）", 2, 50, 8, 1, .px), Self.p("angle", "角度（°）", -180, 180, 0, 1, .degrees), Self.p("sharpness", "くっきりさ", 0, 1, 0.7, 0.01, .percent)]
        case .kaleidoscope: return [Self.p("count", "分割数", 3, 24, 6, 1), Self.p("angle", "角度（°）", -180, 180, 0, 1, .degrees)]
        case .tritone: return [Self.p("amount", "強さ", 0, 1, 1, 0.01, .percent), Self.p("palette", "色の組", 0, 3, 0, 1, .mode)]
        case .solarize: return [Self.p("amount", "強さ", 0, 1, 1, 0.01, .percent), Self.p("threshold", "しきい値", 0, 1, 0.5, 0.01, .percent)]
        case .spinBlur: return [Self.p("amount", "回転量（°）", 0, 90, 20, 1, .degrees)]
        case .edgeBlur: return [Self.p("radius", "ぼかし半径（px）", 0, 100, 20, 1, .px), Self.p("inner", "ぼかさない範囲", 0, 1, 0.6, 0.01, .percent)]
        case .echo: return [Self.p("distance", "ずらし量（px）", 0, 200, 30, 1, .px), Self.p("angle", "向き（°）", -180, 180, 0, 1, .degrees),
                            Self.p("count", "重ねる数", 1, 8, 3, 1), Self.p("opacity", "残像の濃さ", 0, 1, 0.5, 0.01, .percent)]
        case .denoise: return [Self.p("strength", "強さ", 0, 1, 0.5, 0.01, .percent)]
        }
    }

    /// 色を持つ種類の既定の色(無ければ nil)。
    public var defaultColor: String? {
        switch self {
        case .dropShadow: return "#000000"
        case .outline: return "#ffffff"
        case .chromaKey: return "#00ff00"
        default: return nil
        }
    }

    public func spec(_ key: String) -> EffectParamSpec? { params.first { $0.key == key } }
}

// MARK: - エフェクト

/// クリップにかける 1 つのエフェクト。`kind` は知らない文字列も保つ(描くときは何もしない)。
/// `params` は設定値(無いものは仕様の既定値)。`enabled` は true なら書かない。`color` は影・縁取りの色("#rrggbb")。
public struct Effect: Equatable, Codable, Sendable {
    public var kind: String
    public var enabled: Bool = true
    public var params: [String: Double] = [:]
    public var color: String?
    /// ファイルを使うエフェクトの場所(LUT は .cube、色調転写は参照画像)。それ以外では使わない。
    public var path: String?
    /// 知らないキー(保持して書き戻す)
    public var extra: [String: JSONValue] = [:]

    static let knownKeys: Set<String> = ["kind", "enabled", "params", "color", "path"]

    public init(kind: String, enabled: Bool = true, params: [String: Double] = [:], color: String? = nil) {
        self.kind = kind; self.enabled = enabled; self.params = params; self.color = color
    }

    /// 既定値で作る(インスペクタ・メニューの「追加」)。
    public init(_ kind: EffectKind) {
        self.kind = kind.rawValue
        for s in kind.params { params[s.key] = s.defaultValue }
        color = kind.defaultColor
    }

    public var known: EffectKind? { EffectKind(rawValue: kind) }

    /// 設定値(範囲に収める)。未設定は既定値、知らない種類・引数は 0。
    public func value(_ key: String) -> Double {
        guard let spec = known?.spec(key) else { return params[key] ?? 0 }
        return spec.clamp(params[key] ?? spec.defaultValue)
    }

    public var colorOrDefault: String { color ?? known?.defaultColor ?? "#000000" }

    public init(from decoder: Decoder) throws {
        let l = Lenient(c: try decoder.container(keyedBy: AnyKey.self), known: Self.knownKeys)
        kind = l.string("kind") ?? ""
        enabled = l.bool("enabled") ?? true
        if let raw: [String: JSONValue] = l.value("params") {
            for (k, v) in raw { if case .number(let d) = v, d.isFinite { params[k] = d } }
        }
        color = l.string("color")
        path = l.string("path")
        extra = l.extra()
    }

    /// enabled は true のとき、params は空のとき、color は無いときは書かない。
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        for (k, v) in extra { try c.encode(v, forKey: AnyKey(k)) }
        try c.encode(kind, forKey: AnyKey("kind"))
        if !enabled { try c.encode(false, forKey: AnyKey("enabled")) }
        if !params.isEmpty { try c.encode(params, forKey: AnyKey("params")) }
        try c.encodeIfPresent(color, forKey: AnyKey("color"))
        try c.encodeIfPresent(path, forKey: AnyKey("path"))
    }
}

// MARK: - キーフレームの項目名

/// エフェクトの引数のキーフレームは、項目名 "fx.<番号>.<引数名>" で書く。
public enum EffectKey {
    public static func make(_ index: Int, _ param: String) -> String { "fx.\(index).\(param)" }

    public static func parse(_ key: String) -> (index: Int, param: String)? {
        guard key.hasPrefix("fx.") else { return nil }
        let rest = key.dropFirst(3)
        guard let dot = rest.firstIndex(of: "."), let i = Int(rest[rest.startIndex..<dot]), i >= 0 else { return nil }
        let p = String(rest[rest.index(after: dot)...])
        return p.isEmpty ? nil : (i, p)
    }

    /// そのクリップで、その項目の仕様(エフェクトがあり、知っている種類・引数のとき)。
    public static func spec(_ key: String, in clip: Clip) -> EffectParamSpec? {
        guard let (i, p) = parse(key), clip.effects.indices.contains(i) else { return nil }
        return clip.effects[i].known?.spec(p)
    }
}

// MARK: - クリップ側

extension Clip {
    /// エフェクトを付けられる種類。
    public static func supportsEffects(_ type: ClipType) -> Bool { [.image, .video, .text, .compound, .tachie].contains(type) }

    /// 描くエフェクトが 1 つでもあるか(有効で、知っている種類)。描画の速い道の判定。
    public var hasActiveEffects: Bool { effects.contains { $0.enabled && $0.known != nil } }

    /// エフェクトの引数のキー("fx.i.param")を持つ項目名の一覧。
    var effectKeys: [String] {
        var out: [String] = []
        for (i, e) in effects.enumerated() {
            guard let k = e.known else { continue }
            for s in k.params { out.append(EffectKey.make(i, s.key)) }
        }
        return out
    }
}
