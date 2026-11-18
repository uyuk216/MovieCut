import XCTest
@testable import MovieCutCore

/// 受け取った text を記録するだけのモック。
private final class DictTextRecorderVoice: VoiceProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var _texts: [String] = []
    var texts: [String] { lock.withLock { _texts } }
    func synthesize(character: Character, text: String, in directory: URL) async throws -> VoiceResult {
        lock.withLock { _texts.append(text) }
        return VoiceResult(url: URL(fileURLWithPath: "/tmp/mock-\(UUID().uuidString).wav"), duration: 1.0)
    }
}

/// 辞書の合成時適用: DictionaryVoiceProvider と ScriptTimeline.regenerateVoice 経由。
final class VoiceDictionarySynthesisTests: XCTestCase {
    private var entries: [ReadingEntry] {
        [ReadingEntry(word: "相棒", reading: "あいぼう"),
         ReadingEntry(word: "本音", reading: "ほんね")]
    }

    private func project(dict: [ReadingEntry]) -> Project {
        var p = Project.new()
        p.readingDictionary = dict
        return p
    }

    private func voiceClip(_ p: Project, text: String) -> Clip {
        var c = Clip(); c.type = .voice; c.charId = p.characters[0].id; c.text = text; c.duration = 9; c.src = "/old.wav"
        return c
    }

    // MARK: テスト1: DictionaryVoiceProvider

    func testWrapperPassesConvertedText() async throws {
        let mock = DictTextRecorderVoice()
        let w = DictionaryVoiceProvider(inner: mock, entries: entries)
        let ch = Project.new().characters[0]
        _ = try await w.synthesize(character: ch, text: "相棒と本音", in: FileManager.default.temporaryDirectory)
        XCTAssertEqual(mock.texts, ["あいぼうとほんね"])
    }

    func testWrapperEmptyDictionaryPassesThrough() async throws {
        let mock = DictTextRecorderVoice()
        let w = DictionaryVoiceProvider(inner: mock, entries: [])
        let ch = Project.new().characters[0]
        _ = try await w.synthesize(character: ch, text: "相棒と本音", in: FileManager.default.temporaryDirectory)
        XCTAssertEqual(mock.texts, ["相棒と本音"])
    }

    func testWrapperKeepsExpressionTag() async throws {
        let mock = DictTextRecorderVoice()
        let w = DictionaryVoiceProvider(inner: mock, entries: [ReadingEntry(word: "相棒", reading: "あいぼう"), ReadingEntry(word: "笑顔", reading: "えがお")])
        let ch = Project.new().characters[0]
        _ = try await w.synthesize(character: ch, text: "[笑顔]相棒", in: FileManager.default.temporaryDirectory)
        XCTAssertEqual(mock.texts, ["[笑顔]あいぼう"])   // タグ内は変換しない
    }

    // MARK: テスト2: regenerateVoice 経由

    func testRegenerateAppliesProjectDictionary() async throws {
        let p = project(dict: entries)
        var clip = voiceClip(p, text: "相棒に本音を話す")
        let mock = DictTextRecorderVoice()
        try await ScriptTimeline.regenerateVoice(clip: &clip, project: p, provider: mock)
        XCTAssertEqual(mock.texts, ["あいぼうにほんねを話す"])
        XCTAssertEqual(clip.duration, 1.15, accuracy: 1e-9)
    }

    func testRegenerateWithoutDictionaryIsUnchanged() async throws {
        let p = project(dict: [])
        var clip = voiceClip(p, text: "相棒に本音を話す")
        let mock = DictTextRecorderVoice()
        try await ScriptTimeline.regenerateVoice(clip: &clip, project: p, provider: mock)
        XCTAssertEqual(mock.texts, ["相棒に本音を話す"])
    }

    func testRegenerateDoesNotChangeClipTextOrSubtitle() async throws {
        let p = project(dict: entries)
        var clip = voiceClip(p, text: "相棒")
        clip.subtitleText = "相棒の字幕"
        let mock = DictTextRecorderVoice()
        try await ScriptTimeline.regenerateVoice(clip: &clip, project: p, provider: mock)
        XCTAssertEqual(mock.texts, ["あいぼう"])
        XCTAssertEqual(clip.text, "相棒")
        XCTAssertEqual(clip.subtitleText, "相棒の字幕")
    }

    func testRegenerateStripsTagThenAppliesDictionary() async throws {
        let p = project(dict: entries)
        var clip = voiceClip(p, text: "[笑顔]相棒")
        let mock = DictTextRecorderVoice()
        try await ScriptTimeline.regenerateVoice(clip: &clip, project: p, provider: mock)
        XCTAssertEqual(mock.texts, ["あいぼう"])
        XCTAssertEqual(clip.text, "[笑顔]相棒")
    }

    /// 台本由来(生成時に適用済み)の読みへ通常の辞書(漢字表記→かな)を再適用しても不変。
    func testReapplyingDictionaryToAlreadyAppliedTextIsInvariant() async throws {
        let p = project(dict: entries)
        let once = ReadingDictionary.apply(to: "相棒に本音を話す", entries: p.readingDictionary)
        XCTAssertEqual(once, "あいぼうにほんねを話す")
        XCTAssertEqual(ReadingDictionary.apply(to: once, entries: p.readingDictionary), once)
        // 再合成経路でも、適用済みの clip.text は同じ文字列で合成される
        var clip = voiceClip(p, text: once)
        let mock = DictTextRecorderVoice()
        try await ScriptTimeline.regenerateVoice(clip: &clip, project: p, provider: mock)
        XCTAssertEqual(mock.texts, [once])
        XCTAssertEqual(clip.text, once)
    }
}
