import Foundation
import CoreGraphics
import CoreImage

// MARK: - HSL マスク(Premiere Pro 27.0「HSL マスキング」のローカル等価)
//
// 色相・彩度・輝度で領域を切り分けるマスク。範囲選択は HSL セカンダリと共有する
// 独立部品 `HSLSelection` をそのまま使い、マスク画像の生成は `HSLSelection.maskCubeData`
// (重みをグレースケールで出す CIColorCube データ)を土台にする。
// 適用は形マスク(`ClipMask` / `ShapeMask`)・オブジェクトマスク(`ObjectMask`)と
// 同じ経路: `Renderer.drawEffectedClip` でエフェクトの後に `CIBlendWithMask` で
// 画素へかける。形・オブジェクトと併用でき、両方あるときは両方かかる(積 = AND)。
//
// HSL セカンダリとの違い: セカンダリは「選んだ範囲だけ色を変える補正」で、
// 透明度は変えない。HSL マスクは「選んだ範囲だけ残す(外は透明)」マスクで、
// クリップ全体へかけたエフェクト・補正の見え方も範囲の中だけに残る。
// 対象だけに補正をかけたいときは、オブジェクトマスクと同じ作法
// (クリップを複製して片方にマスクを付け、反転と組み合わせる)を使う。
//
// マスクの重みは「マスクをかける直前の画素(エフェクト適用後)」ではなく、
// エフェクトをかける前のクリップ自身の色から作る。色相シフト等の補正で
// 選択範囲そのものが動いてしまわないため(Premiere のクオリファイアと同じ考え方)。
//
// 保存の形(`ClipMask` と同じ約束): `Clip.hslMask` として保存し、既定値の項目は
// 書かず、知らないキーは `extra` に残してそのまま書き戻す。無いとき(nil)は
// ファイルに書かず、描画も従来と画素一致する。

/// マスクプレビューの表示方法。選択範囲の確認用で、書き出しにも効く表示切替なので
/// 使うときは確認後に「オフ」に戻すこと(ファイルにはオフ以外だけ書く)。
public enum HSLMaskPreview: String, Codable, Equatable, Sendable {
    /// プレビューなし(通常のマスク適用)。
    case off
    /// 選択範囲の外をグレー(無彩色)にして表示する。選択範囲の中は元の色のまま。
    case grayOutside
    /// 選択範囲の中を色(マゼンタ)で塗って表示する。重みは濃さになる。
    case tintInside
}

/// HSL マスク(クリップに保存される)。範囲選択 + 反転 + プレビュー表示。
public struct HSLMask: Codable, Equatable, Sendable {
    /// 色域の選択(HSL セカンダリと共有する部品)。
    public var selection: HSLSelection
    /// true で選択範囲の外を残し、中を透明にする。
    public var invert: Bool
    /// マスクプレビューの表示方法(確認用)。
    public var preview: HSLMaskPreview

    public init(selection: HSLSelection = HSLSelection(), invert: Bool = false, preview: HSLMaskPreview = .off) {
        self.selection = selection
        self.invert = invert
        self.preview = preview
    }

    /// 画素の色に対する実効の重み(反転を込めた「残す」重み 0〜1)。
    public func keepWeight(r: Double, g: Double, b: Double) -> Double {
        let w = selection.weight(r: r, g: g, b: b)
        return invert ? 1 - w : w
    }

    // MARK: ファイル形式(ClipMask と同じ作法)

    enum CodingKeys: String, CodingKey {
        case hueCenter, hueWidth, hueFeather, satMin, satMax, satFeather, lumMin, lumMax, lumFeather, invert, preview
    }
    /// 知らないキー(新しい版が書いた項目)。そのまま書き戻す。
    public var extra: [String: JSONValue] = [:]
    static let knownKeys: Set<String> = ["hueCenter", "hueWidth", "hueFeather", "satMin", "satMax", "satFeather",
                                         "lumMin", "lumMax", "lumFeather", "invert", "preview"]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = HSLSelection()
        let sel = HSLSelection(
            hueCenter: (try? c.decodeIfPresent(Double.self, forKey: .hueCenter)) ?? d.hueCenter,
            hueWidth: (try? c.decodeIfPresent(Double.self, forKey: .hueWidth)) ?? d.hueWidth,
            hueFeather: (try? c.decodeIfPresent(Double.self, forKey: .hueFeather)) ?? d.hueFeather,
            satMin: (try? c.decodeIfPresent(Double.self, forKey: .satMin)) ?? d.satMin,
            satMax: (try? c.decodeIfPresent(Double.self, forKey: .satMax)) ?? d.satMax,
            satFeather: (try? c.decodeIfPresent(Double.self, forKey: .satFeather)) ?? d.satFeather,
            lumMin: (try? c.decodeIfPresent(Double.self, forKey: .lumMin)) ?? d.lumMin,
            lumMax: (try? c.decodeIfPresent(Double.self, forKey: .lumMax)) ?? d.lumMax,
            lumFeather: (try? c.decodeIfPresent(Double.self, forKey: .lumFeather)) ?? d.lumFeather)
        let inv = (try? c.decodeIfPresent(Bool.self, forKey: .invert)) ?? false
        let prev = (try? c.decodeIfPresent(HSLMaskPreview.self, forKey: .preview)) ?? .off
        self.init(selection: sel, invert: inv, preview: prev)
        extra = Lenient(c: try decoder.container(keyedBy: AnyKey.self), known: Self.knownKeys).extra()
    }

    /// 既定値の項目は書かない(選択は `HSLSelection` の既定と違う項目だけ、反転・プレビューは有効なときだけ)。
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        for (k, v) in extra { try c.encode(v, forKey: AnyKey(k)) }
        let s = selection, d = HSLSelection()
        if s.hueCenter != d.hueCenter { try c.encode(s.hueCenter, forKey: AnyKey("hueCenter")) }
        if s.hueWidth != d.hueWidth { try c.encode(s.hueWidth, forKey: AnyKey("hueWidth")) }
        if s.hueFeather != d.hueFeather { try c.encode(s.hueFeather, forKey: AnyKey("hueFeather")) }
        if s.satMin != d.satMin { try c.encode(s.satMin, forKey: AnyKey("satMin")) }
        if s.satMax != d.satMax { try c.encode(s.satMax, forKey: AnyKey("satMax")) }
        if s.satFeather != d.satFeather { try c.encode(s.satFeather, forKey: AnyKey("satFeather")) }
        if s.lumMin != d.lumMin { try c.encode(s.lumMin, forKey: AnyKey("lumMin")) }
        if s.lumMax != d.lumMax { try c.encode(s.lumMax, forKey: AnyKey("lumMax")) }
        if s.lumFeather != d.lumFeather { try c.encode(s.lumFeather, forKey: AnyKey("lumFeather")) }
        if invert { try c.encode(true, forKey: AnyKey("invert")) }
        if preview != .off { try c.encode(preview.rawValue, forKey: AnyKey("preview")) }
    }
}

// MARK: - マスク画像の生成と適用(ShapeMask と同じ経路)

public enum HSLMaskRenderer {
    /// マスク LUT の 1 辺(`HSLSecondary.cubeDimension` と同じ 33)。
    public static let cubeDimension = 33

    // LUT データの小さなキャッシュ(プレビュー・書き出しの毎コマ生成を避ける)。
    // キーは選択と反転をそのまま使った文字列。
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Data] = [:]

    static func cacheKey(_ m: HSLMask) -> String {
        let s = m.selection
        return [s.hueCenter, s.hueWidth, s.hueFeather, s.satMin, s.satMax, s.satFeather,
                s.lumMin, s.lumMax, s.lumFeather].map { String($0) }.joined(separator: ",")
            + (m.invert ? "|inv" : "")
    }

    /// 「残す」重みをグレースケール (w, w, w, 1) で出す CIColorCube 用データ。
    /// 土台は `HSLSelection.maskCubeData`。反転は重みを 1 − w にして作る。
    public static func cubeData(for m: HSLMask) -> Data {
        if !m.invert { return HSLSelection.maskCubeData(selection: m.selection, dimension: cubeDimension) }
        let key = cacheKey(m)
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[key] { return hit }
        let base = HSLSelection.maskCubeData(selection: m.selection, dimension: cubeDimension)
        var floats = base.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        for i in stride(from: 0, to: floats.count, by: 4) {
            let w = 1 - floats[i]
            floats[i] = w; floats[i + 1] = w; floats[i + 2] = w
        }
        let data = floats.withUnsafeBufferPointer { Data(buffer: $0) }
        if cache.count > 8 { cache.removeAll() }
        cache[key] = data
        return data
    }

    /// 画像自身の色から作るマスク画像(白 = 残す、黒 = 消す、不透明)。
    /// 入力は事前乗算なしの色で判定する(透明に近い画素でも色で選ぶため)。
    public static func maskImage(from img: CIImage, mask m: HSLMask) -> CIImage {
        img.unpremultiplyingAlpha()
            .applyingFilter("CIColorCube", parameters: [
                "inputCubeDimension": cubeDimension,
                "inputCubeData": cubeData(for: m),
            ])
            .premultiplyingAlpha()
            .cropped(to: img.extent)
    }

    /// `ShapeMask.apply` と同じ作法で、HSL マスクを画素へかける。マスクの外は透明になる。
    /// マスク画像は `source`(エフェクト前のクリップ自身の画素)から作る。
    public static func apply(_ img: CIImage, source: CIImage, mask m: HSLMask) -> CIImage {
        let ext = img.extent
        let maskImg = maskImage(from: source, mask: m).cropped(to: ext)
        let clear = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: ext)
        return img.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: clear,
            kCIInputMaskImageKey: maskImg,
        ]).cropped(to: ext)
    }

    // MARK: マスクプレビュー(純粋な画素計算。単体テストと描画の両方から使う)

    /// プレビュー表示した 1 画素(0〜1 の RGB → 0〜1 の RGB)。アルファは変えない前提で色だけを返す。
    /// - grayOutside: 重み w で元の色とグレーを混ぜる(外はグレー、中は元の色)。
    /// - tintInside: 重み w で元の色とマゼンタ (1, 0, 1) を混ぜる(中が色づく)。
    public static func previewed(r: Double, g: Double, b: Double, weight w: Double, mode: HSLMaskPreview) -> (r: Double, g: Double, b: Double) {
        let w = ColorHSL.clamp01(w)
        switch mode {
        case .off:
            return (r, g, b)
        case .grayOutside:
            let gray = 0.2126 * r + 0.7152 * g + 0.0722 * b
            return (gray * (1 - w) + r * w, gray * (1 - w) + g * w, gray * (1 - w) + b * w)
        case .tintInside:
            return (r * (1 - w) + w, g * (1 - w), b * (1 - w) + w)
        }
    }

    /// プレビュー表示の画像を作る。重みは `source`(エフェクト前の画素)から作り
    /// (通常のマスク適用と同じ基準)、透明度は変えない(範囲の確認専用なので、
    /// マスクとしての切り抜きはしない)。
    public static func previewImage(_ img: CIImage, source: CIImage, mask m: HSLMask) -> CIImage {
        guard m.preview != .off else { return img }
        let ext = img.extent
        let wImg = maskImage(from: source, mask: m).cropped(to: ext)
        switch m.preview {
        case .off:
            return img
        case .grayOutside:
            // グレー化した絵の上に、重みをマスクにして元の絵を重ねる
            let gray = img.applyingFilter("CIColorControls", parameters: ["inputSaturation": 0.0])
            return img.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: gray.cropped(to: ext),
                kCIInputMaskImageKey: wImg,
            ]).cropped(to: ext)
        case .tintInside:
            let tint = CIImage(color: CIColor(red: 1, green: 0, blue: 1)).cropped(to: ext)
            return tint.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: img,
                kCIInputMaskImageKey: wImg,
            ]).cropped(to: ext)
        }
    }
}
