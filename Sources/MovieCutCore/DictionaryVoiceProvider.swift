import Foundation

/// 合成の直前に読み辞書を適用する VoiceProvider のラッパー。
/// text だけを変換して内側へ委譲する(キャラ・出力先はそのまま)。
/// 辞書が空なら text を一切触らず素通しするので、合成手順・キャッシュキー・生成音声は従来と同一。
public final class DictionaryVoiceProvider: VoicevoxAccentProviding {
    public let inner: any VoiceProvider
    public let entries: [ReadingEntry]

    public init(inner: any VoiceProvider, entries: [ReadingEntry]) {
        self.inner = inner
        self.entries = entries
    }

    public func synthesize(character: Character, text: String, in directory: URL) async throws -> VoiceResult {
        guard !entries.isEmpty else {
            return try await inner.synthesize(character: character, text: text, in: directory)
        }
        return try await inner.synthesize(character: character, text: ReadingDictionary.apply(to: text, entries: entries), in: directory)
    }

    /// 内側がアクセントに対応していれば、辞書変換後のテキストとアクセント句の両方を渡す。非対応なら通常の synthesize に委譲する。
    public func synthesizeWithAccent(character: Character, text: String, accentPhrases: [VoicevoxAccentPhrase], in directory: URL) async throws -> VoiceResult {
        guard let accent = inner as? any VoicevoxAccentProviding else {
            return try await synthesize(character: character, text: text, in: directory)
        }
        let converted = entries.isEmpty ? text : ReadingDictionary.apply(to: text, entries: entries)
        return try await accent.synthesizeWithAccent(character: character, text: converted, accentPhrases: accentPhrases, in: directory)
    }
}
