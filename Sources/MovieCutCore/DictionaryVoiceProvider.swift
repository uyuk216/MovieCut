import Foundation

/// 合成の直前に読み辞書を適用する VoiceProvider のラッパー。
/// text だけを変換して内側へ委譲する(キャラ・出力先はそのまま)。
/// 辞書が空なら text を一切触らず素通しするので、合成手順・キャッシュキー・生成音声は従来と同一。
public final class DictionaryVoiceProvider: VoiceProvider {
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
}
