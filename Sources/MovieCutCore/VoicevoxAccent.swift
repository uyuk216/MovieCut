import Foundation

/// VOICEVOX の mora(音の最小単位)。audio_query 応答の accent_phrases[].moras[] と同じ形。
public struct VoicevoxAccentMora: Codable, Equatable, Sendable {
    public var text: String
    public var consonant: String?
    public var consonantLength: Double?
    public var vowel: String
    public var vowelLength: Double
    public var pitch: Double

    public init(text: String, consonant: String? = nil, consonantLength: Double? = nil, vowel: String, vowelLength: Double, pitch: Double) {
        self.text = text
        self.consonant = consonant
        self.consonantLength = consonantLength
        self.vowel = vowel
        self.vowelLength = vowelLength
        self.pitch = pitch
    }

    enum CodingKeys: String, CodingKey {
        case text, consonant, vowel, pitch
        case consonantLength = "consonant_length"
        case vowelLength = "vowel_length"
    }

    /// モーラ全体の長さ(秒)。子音の長さ + 母音の長さ。子音が無いモーラは母音の長さだけ。
    public var totalLength: Double { (consonantLength ?? 0) + vowelLength }

    /// 長さ(子音・母音)と音高を、エンジンが受け付ける範囲に収めた複製。
    /// VOICEVOX が返した通常の値(母音 0.05〜0.5 秒前後、音高 5〜6 前後、ポーズの音高 0)は範囲内なので変わらない。
    public func sanitized() -> VoicevoxAccentMora {
        var m = self
        m.vowelLength = VoicevoxAccent.clampVowelLength(vowelLength)
        if let c = consonantLength { m.consonantLength = VoicevoxAccent.clampConsonantLength(c) }
        m.pitch = VoicevoxAccent.clampMoraPitch(pitch)
        return m
    }
}

/// VOICEVOX のアクセント句。`accent` は核位置(0 = 平板、n = n モーラ目の直後で下がる)。
public struct VoicevoxAccentPhrase: Codable, Equatable, Sendable {
    public var moras: [VoicevoxAccentMora]
    public var accent: Int
    public var pauseMora: VoicevoxAccentMora?
    public var isInterrogative: Bool?

    public init(moras: [VoicevoxAccentMora], accent: Int, pauseMora: VoicevoxAccentMora? = nil, isInterrogative: Bool? = nil) {
        self.moras = moras
        self.accent = accent
        self.pauseMora = pauseMora
        self.isInterrogative = isInterrogative
    }

    enum CodingKeys: String, CodingKey {
        case moras, accent
        case pauseMora = "pause_mora"
        case isInterrogative = "is_interrogative"
    }

    /// 核位置を 0...moras.count に収めた複製。
    public func withClampedAccent() -> VoicevoxAccentPhrase {
        var p = self
        p.accent = VoicevoxAccent.clampAccent(accent, moraCount: moras.count)
        return p
    }

    /// 全モーラ(ポーズモーラを含む)の長さ・音高を範囲に収めた複製。
    public func withSanitizedMoras() -> VoicevoxAccentPhrase {
        var p = self
        p.moras = moras.map { $0.sanitized() }
        p.pauseMora = pauseMora?.sanitized()
        return p
    }
}

/// アクセント編集用の純粋関数と、audio_query 応答との変換。
public enum VoicevoxAccent {
    /// 核位置を 0...moraCount に収める(0 = 平板)。moraCount が負でも 0 に収める。
    public static func clampAccent(_ accent: Int, moraCount: Int) -> Int {
        min(max(accent, 0), max(moraCount, 0))
    }

    /// 句ごとに核位置をクランプし、各モーラの長さ・音高も範囲に収めた配列。
    /// VOICEVOX が返した通常の範囲の値は変わらない(未調整の句に適用しても同一)。
    public static func clamped(_ phrases: [VoicevoxAccentPhrase]) -> [VoicevoxAccentPhrase] {
        phrases.map { $0.withClampedAccent().withSanitizedMoras() }
    }

    // MARK: モーラ単位の長さ・音高(R2-1)

    /// 母音の長さ(秒)の許容範囲。VOICEVOX の通常値(0.05〜0.5 前後)を十分に含む。
    public static let vowelLengthRange: ClosedRange<Double> = 0.01...1.0
    /// 子音の長さ(秒)の許容範囲。
    public static let consonantLengthRange: ClosedRange<Double> = 0.0...1.0
    /// モーラ全体の長さ(子音+母音、秒)の許容範囲。スライダーの「長さ」はこの合計を指す。
    public static let moraLengthRange: ClosedRange<Double> = 0.02...1.0
    /// モーラの音高(log f0)の許容範囲。0 は無声・ポーズの値で、そのまま保つ。
    public static let moraPitchRange: ClosedRange<Double> = 0.0...10.0
    /// 音高スライダーの表示範囲(有声モーラ用)。通常値は 5〜6 前後。
    public static let moraPitchSliderRange: ClosedRange<Double> = 3.0...8.0
    /// 長さスライダーの表示範囲(モーラ全体、秒)。
    public static let moraLengthSliderRange: ClosedRange<Double> = 0.02...0.50

    private static func clampValue(_ v: Double, _ range: ClosedRange<Double>, fallback: Double) -> Double {
        v.isFinite ? min(max(v, range.lowerBound), range.upperBound) : fallback
    }

    /// 母音の長さを範囲に収める。NaN・無限大は下限に落とす。
    public static func clampVowelLength(_ v: Double) -> Double { clampValue(v, vowelLengthRange, fallback: vowelLengthRange.lowerBound) }
    /// 子音の長さを範囲に収める。NaN・無限大は 0 に落とす。
    public static func clampConsonantLength(_ v: Double) -> Double { clampValue(v, consonantLengthRange, fallback: 0) }
    /// モーラ全体の長さを範囲に収める。
    public static func clampMoraLength(_ v: Double) -> Double { clampValue(v, moraLengthRange, fallback: moraLengthRange.lowerBound) }
    /// モーラの音高を範囲に収める。0(無声・ポーズ)は 0 のまま。
    public static func clampMoraPitch(_ v: Double) -> Double { clampValue(v, moraPitchRange, fallback: 0) }

    /// 指定した句・モーラを取り出す。範囲外は nil。
    public static func mora(phrase: Int, mora: Int, in phrases: [VoicevoxAccentPhrase]) -> VoicevoxAccentMora? {
        guard phrases.indices.contains(phrase), phrases[phrase].moras.indices.contains(mora) else { return nil }
        return phrases[phrase].moras[mora]
    }

    /// 1 モーラを差し替えた配列を作る共通処理。範囲外はそのまま返す。
    private static func updatingMora(phrase: Int, mora: Int, in phrases: [VoicevoxAccentPhrase], _ edit: (inout VoicevoxAccentMora) -> Void) -> [VoicevoxAccentPhrase] {
        guard phrases.indices.contains(phrase), phrases[phrase].moras.indices.contains(mora) else { return phrases }
        var out = phrases
        edit(&out[phrase].moras[mora])
        return out
    }

    /// モーラの音高を(クランプして)差し替えた配列。
    public static func settingMoraPitch(_ pitch: Double, phrase: Int, mora: Int, in phrases: [VoicevoxAccentPhrase]) -> [VoicevoxAccentPhrase] {
        updatingMora(phrase: phrase, mora: mora, in: phrases) { $0.pitch = clampMoraPitch(pitch) }
    }

    /// モーラ全体の長さを(クランプして)差し替えた配列。
    /// 子音と母音の比率は保ったまま両方を伸縮する。子音が無いモーラは母音だけを変える。
    public static func settingMoraLength(_ totalLength: Double, phrase: Int, mora: Int, in phrases: [VoicevoxAccentPhrase]) -> [VoicevoxAccentPhrase] {
        updatingMora(phrase: phrase, mora: mora, in: phrases) { m in
            let target = clampMoraLength(totalLength)
            guard let c = m.consonantLength else { m.vowelLength = clampVowelLength(target); return }
            let old = c + m.vowelLength
            if old > 0 {
                m.consonantLength = clampConsonantLength(c * target / old)
                m.vowelLength = clampVowelLength(m.vowelLength * target / old)
            } else {
                m.consonantLength = 0
                m.vowelLength = clampVowelLength(target)
            }
        }
    }

    /// モーラの母音の長さだけを(クランプして)差し替えた配列。子音の長さは変えない。
    public static func settingMoraVowelLength(_ length: Double, phrase: Int, mora: Int, in phrases: [VoicevoxAccentPhrase]) -> [VoicevoxAccentPhrase] {
        updatingMora(phrase: phrase, mora: mora, in: phrases) { $0.vowelLength = clampVowelLength(length) }
    }

    /// モーラの子音の長さだけを(クランプして)差し替えた配列。
    /// 子音が無いモーラ(撥音など)は何も変えない(子音を捏造しない)。
    public static func settingMoraConsonantLength(_ length: Double, phrase: Int, mora: Int, in phrases: [VoicevoxAccentPhrase]) -> [VoicevoxAccentPhrase] {
        updatingMora(phrase: phrase, mora: mora, in: phrases) { m in
            guard m.consonant != nil || m.consonantLength != nil else { return }
            m.consonantLength = clampConsonantLength(length)
        }
    }

    /// index の句の核位置を(クランプして)差し替えた配列。範囲外の index はそのまま返す。
    public static func settingAccent(_ accent: Int, at index: Int, in phrases: [VoicevoxAccentPhrase]) -> [VoicevoxAccentPhrase] {
        guard phrases.indices.contains(index) else { return phrases }
        var out = phrases
        out[index].accent = clampAccent(accent, moraCount: out[index].moras.count)
        return out
    }

    /// 句の全モーラ数(pause_mora は含めない)。
    public static func moraCount(_ phrases: [VoicevoxAccentPhrase]) -> Int {
        phrases.reduce(0) { $0 + $1.moras.count }
    }

    /// audio_query 応答の辞書 → アクセント句。`accent_phrases` が無い・読めないときは nil。
    /// 未知キーは捨てる(moras / accent / pause_mora / is_interrogative は保つ)。
    public static func phrases(fromQuery query: [String: Any]) -> [VoicevoxAccentPhrase]? {
        guard let raw = query["accent_phrases"] else { return nil }
        return phrases(fromJSONObject: raw)
    }

    /// `accent_phrases` の JSON オブジェクト(配列)→ アクセント句。
    public static func phrases(fromJSONObject raw: Any) -> [VoicevoxAccentPhrase]? {
        guard JSONSerialization.isValidJSONObject(raw),
              let data = try? JSONSerialization.data(withJSONObject: raw) else { return nil }
        return try? JSONDecoder().decode([VoicevoxAccentPhrase].self, from: data)
    }

    /// アクセント句 → `accent_phrases` に差し込める JSON オブジェクト([Any])。
    public static func jsonObject(from phrases: [VoicevoxAccentPhrase]) throws -> Any {
        let data = try JSONEncoder().encode(phrases)
        return try JSONSerialization.jsonObject(with: data)
    }

    /// 安定した JSON 文字列(キー順固定)。キャッシュキーの要素に使う。
    public static func stableJSON(_ phrases: [VoicevoxAccentPhrase]) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? enc.encode(phrases)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}

/// アクセント句を受け取れる音声プロバイダ(任意)。`VoiceProvider` 自体は変えない(プラグイン互換のため)。
/// VOICEVOX のキャラのときだけアクセント句を使い、それ以外のエンジンは通常合成に落とす。
public protocol VoicevoxAccentProviding: VoiceProvider {
    func synthesizeWithAccent(character: Character, text: String, accentPhrases: [VoicevoxAccentPhrase], in directory: URL) async throws -> VoiceResult
}
