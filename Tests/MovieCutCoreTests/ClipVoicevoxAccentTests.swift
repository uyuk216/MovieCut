import XCTest
@testable import MovieCutCore

private final class AccentMockVoice: VoicevoxAccentProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _normal: [String] = []
    private var _accent: [(text: String, phrases: [VoicevoxAccentPhrase])] = []
    var normal: [String] { lock.withLock { _normal } }
    var accent: [(text: String, phrases: [VoicevoxAccentPhrase])] { lock.withLock { _accent } }
    private func result() -> VoiceResult { VoiceResult(url: URL(fileURLWithPath: "/tmp/mock-\(UUID().uuidString).wav"), duration: 1.0) }
    func synthesize(character: Character, text: String, in directory: URL) async throws -> VoiceResult {
        lock.withLock { _normal.append(text) }; return result()
    }
    func synthesizeWithAccent(character: Character, text: String, accentPhrases: [VoicevoxAccentPhrase], in directory: URL) async throws -> VoiceResult {
        lock.withLock { _accent.append((text, accentPhrases)) }; return result()
    }
}

private final class PlainMockVoice: VoiceProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var _texts: [String] = []
    var texts: [String] { lock.withLock { _texts } }
    func synthesize(character: Character, text: String, in directory: URL) async throws -> VoiceResult {
        lock.withLock { _texts.append(text) }
        return VoiceResult(url: URL(fileURLWithPath: "/tmp/mock-\(UUID().uuidString).wav"), duration: 1.0)
    }
}

final class ClipVoicevoxAccentTests: XCTestCase {
    private let phrases = [VoicevoxAccentPhrase(moras: [
        VoicevoxAccentMora(text: "コ", consonant: "k", consonantLength: 0.1, vowel: "o", vowelLength: 0.1, pitch: 5.5),
        VoicevoxAccentMora(text: "ン", vowel: "N", vowelLength: 0.1, pitch: 5.6)], accent: 1, pauseMora: nil, isInterrogative: false)]

    private func json(_ c: Clip) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(c)) as! [String: Any]
    }
    private func voiceClip(_ p: Project, text: String) -> Clip {
        var c = Clip(); c.type = .voice; c.charId = p.characters[0].id; c.text = text; c.duration = 9; c.src = "/old.wav"
        return c
    }

    // MARK: テスト5 保存

    func testRoundTrip() throws {
        var c = Clip(); c.voicevoxAccent = phrases
        let back = try JSONDecoder().decode(Clip.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(back.voicevoxAccent, phrases)
        XCTAssertNil(back.extra["voicevoxAccent"])
        XCTAssertEqual(back, c)
    }

    func testNotWrittenWhenNilOrEmpty() throws {
        var c = Clip()
        XCTAssertNil(try json(c)["voicevoxAccent"])
        c.voicevoxAccent = []
        XCTAssertNil(try json(c)["voicevoxAccent"])
        c.voicevoxAccent = phrases
        XCTAssertNotNil(try json(c)["voicevoxAccent"])
    }

    func testOldFileReadsAsNil() throws {
        let c = try JSONDecoder().decode(Clip.self, from: Data(#"{"id":"a","type":"voice","start":0,"duration":1,"offset":0}"#.utf8))
        XCTAssertNil(c.voicevoxAccent)
        let e = try JSONDecoder().decode(Clip.self, from: Data(#"{"id":"a","type":"voice","start":0,"duration":1,"offset":0,"voicevoxAccent":[]}"#.utf8))
        XCTAssertNil(e.voicevoxAccent)
    }

    func testUnreadableValueIsKeptInExtra() throws {
        let c = try JSONDecoder().decode(Clip.self, from: Data(#"{"id":"a","type":"voice","start":0,"duration":1,"offset":0,"voicevoxAccent":"x"}"#.utf8))
        XCTAssertNil(c.voicevoxAccent)
        XCTAssertEqual(try json(c)["voicevoxAccent"] as? String, "x")
    }

    // MARK: 整合判定

    func testShouldUseAccent() {
        let d = [ReadingEntry(word: "相棒", reading: "あいぼう")]
        XCTAssertTrue(ScriptTimeline.shouldUseAccent(bodyText: "相棒", entries: []))
        XCTAssertTrue(ScriptTimeline.shouldUseAccent(bodyText: "こんにちは", entries: d))
        XCTAssertFalse(ScriptTimeline.shouldUseAccent(bodyText: "相棒", entries: d))
    }

    // MARK: テスト6 regenerateVoice

    func testRegenerateUsesAccent() async throws {
        let p = Project.new()
        var clip = voiceClip(p, text: "[笑顔]こんにちは"); clip.voicevoxAccent = phrases
        let mock = AccentMockVoice()
        try await ScriptTimeline.regenerateVoice(clip: &clip, project: p, provider: mock)
        XCTAssertEqual(mock.normal, [])
        XCTAssertEqual(mock.accent.count, 1)
        XCTAssertEqual(mock.accent[0].phrases, phrases)
        XCTAssertEqual(mock.accent[0].text, "こんにちは")
        XCTAssertEqual(clip.text, "[笑顔]こんにちは")
        XCTAssertEqual(clip.voicevoxAccent, phrases)
    }

    func testRegenerateUsesAccentWithUnrelatedDictionary() async throws {
        var p = Project.new(); p.readingDictionary = [ReadingEntry(word: "相棒", reading: "あいぼう")]
        var clip = voiceClip(p, text: "こんにちは"); clip.voicevoxAccent = phrases
        let mock = AccentMockVoice()
        try await ScriptTimeline.regenerateVoice(clip: &clip, project: p, provider: mock)
        XCTAssertEqual(mock.accent.count, 1)
        XCTAssertEqual(mock.normal, [])
    }

    func testNoAccentUsesNormalSynthesis() async throws {
        let p = Project.new()
        var clip = voiceClip(p, text: "こんにちは")
        let mock = AccentMockVoice()
        try await ScriptTimeline.regenerateVoice(clip: &clip, project: p, provider: mock)
        XCTAssertEqual(mock.normal, ["こんにちは"])
        XCTAssertEqual(mock.accent.count, 0)
        clip.voicevoxAccent = []
        try await ScriptTimeline.regenerateVoice(clip: &clip, project: p, provider: mock)
        XCTAssertEqual(mock.accent.count, 0)
    }

    func testNonConformingProviderFallsBackToNormal() async throws {
        let p = Project.new()
        var clip = voiceClip(p, text: "こんにちは"); clip.voicevoxAccent = phrases
        let mock = PlainMockVoice()
        try await ScriptTimeline.regenerateVoice(clip: &clip, project: p, provider: mock)
        XCTAssertEqual(mock.texts, ["こんにちは"])
    }

    func testDictionaryChangedTextFallsBackToNormal() async throws {
        var p = Project.new(); p.readingDictionary = [ReadingEntry(word: "相棒", reading: "あいぼう")]
        var clip = voiceClip(p, text: "相棒"); clip.voicevoxAccent = phrases
        let mock = AccentMockVoice()
        try await ScriptTimeline.regenerateVoice(clip: &clip, project: p, provider: mock)
        XCTAssertEqual(mock.accent.count, 0)
        XCTAssertEqual(mock.normal, ["あいぼう"])
        XCTAssertEqual(clip.text, "相棒")
    }
}
