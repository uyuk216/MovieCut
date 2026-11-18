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
}

/// アクセント編集用の純粋関数と、audio_query 応答との変換。
public enum VoicevoxAccent {
    /// 核位置を 0...moraCount に収める(0 = 平板)。moraCount が負でも 0 に収める。
    public static func clampAccent(_ accent: Int, moraCount: Int) -> Int {
        min(max(accent, 0), max(moraCount, 0))
    }

    /// 句ごとに核位置をクランプした配列。
    public static func clamped(_ phrases: [VoicevoxAccentPhrase]) -> [VoicevoxAccentPhrase] {
        phrases.map { $0.withClampedAccent() }
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
