import XCTest
import AVFoundation
@testable import MovieCutCore

/// 同じ台詞の別テイクの比較(候補 35)。
final class TakeCompareTests: XCTestCase {
    private func voice(_ id: String, _ text: String, start: Double, dur: Double = 2) -> Clip {
        var c = Clip(); c.id = id; c.type = .voice; c.text = text; c.start = start; c.duration = dur; c.charId = "c"; c.src = "/nonexistent/\(id).wav"
        return c
    }

    func testKeyIgnoresTagsSpacesWidthAndCase() {
        XCTAssertEqual(TakeCompare.key(of: "[笑顔]こんにちは、 世界"), TakeCompare.key(of: "こんにちは、世界"))
        XCTAssertEqual(TakeCompare.key(of: "ＡＢＣ　ｄｅｆ"), TakeCompare.key(of: "abc def"))
        XCTAssertNil(TakeCompare.key(of: "  \n "))
        XCTAssertNil(TakeCompare.key(of: nil))
        XCTAssertNotEqual(TakeCompare.key(of: "こんにちは"), TakeCompare.key(of: "こんばんは"))
    }

    func testGroupsNeedTwoOrMoreAndAreTimeOrdered() {
        var p = Project()
        p.tracks[0].clips = [voice("a", "おはよう", start: 8), voice("single", "ひとつだけ", start: 1), voice("b", "[怒り]おはよう", start: 3)]
        p.tracks[1].clips = [voice("c", "おはよう ", start: 0), voice("d", "別", start: 20), voice("e", "別", start: 21)]
        var text = Clip(); text.id = "t"; text.type = .text; text.text = "おはよう"; text.start = 0; text.duration = 1
        p.tracks[2].clips = [text]
        let g = TakeCompare.groups(in: p)
        XCTAssertEqual(g.count, 2)
        XCTAssertEqual(g[0].takes.map(\.clipId), ["c", "b", "a"], "時刻順。文字クリップは数えない")
        XCTAssertEqual(g[0].takes.map(\.trackName), ["レイヤー2", "レイヤー1", "レイヤー1"])
        XCTAssertEqual(g[1].takes.map(\.clipId), ["d", "e"])
        XCTAssertTrue(TakeCompare.groups(in: Project()).isEmpty)
    }

    func testMetricsFromProfile() {
        // 0.2 秒無音 → 0.5 秒の声(−20 dB)→ 0.3 秒無音
        var levels = [Float](repeating: -120, count: 20) + [Float](repeating: -20, count: 50) + [Float](repeating: -120, count: 30)
        levels[40] = -10
        let m = TakeCompare.metrics(of: LevelProfile(levels: levels, duration: 1.0))
        XCTAssertEqual(m.leadSilence, 0.2, accuracy: 1e-9)
        XCTAssertEqual(m.trailSilence, 0.3, accuracy: 1e-9)
        XCTAssertEqual(m.speechLength, 0.5, accuracy: 1e-9)
        XCTAssertEqual(m.peakDb!, -10, accuracy: 1e-9)
        let expected = 10 * log10((49 * pow(10, -2.0) + pow(10, -1.0)) / 50)
        XCTAssertEqual(m.averageDb!, expected, accuracy: 1e-6)
    }

    func testMetricsOfSilentProfile() {
        let m = TakeCompare.metrics(of: LevelProfile(levels: [Float](repeating: -120, count: 10), duration: 0.1))
        XCTAssertNil(m.averageDb); XCTAssertNil(m.peakDb)
        XCTAssertEqual(m.speechLength, 0)
    }

    func testMetricsOfRealToneFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("take-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try ToneVoiceProvider.writeTone(to: url, duration: 1.0, frequency: 440, amplitude: 0.5)
        var c = voice("a", "x", start: 0, dur: 1.0); c.src = url.path; c.srcDuration = 1
        let m = try XCTUnwrap(TakeCompare.metrics(of: c))
        XCTAssertGreaterThan(m.speechLength, 0.5)
        XCTAssertLessThan(m.averageDb!, 0)
        XCTAssertNil(TakeCompare.metrics(of: voice("z", "x", start: 0)), "読めない音は nil")
    }

    func testKeepOnlyRemovesOthers() throws {
        var p = Project()
        p.tracks[0].clips = [voice("a", "こんにちは", start: 0), voice("b", "こんにちは", start: 3), voice("x", "別のセリフ", start: 6)]
        p.tracks[1].clips = [voice("c", "こんにちは", start: 0)]
        let r = try XCTUnwrap(TakeCompare.keepOnly("b", in: p))
        XCTAssertEqual(Set(r.removed), ["a", "c"])
        XCTAssertEqual(r.project.allClips.map(\.id).sorted(), ["b", "x"])
        XCTAssertNil(TakeCompare.keepOnly("x", in: p), "テイクが無いセリフ")
        XCTAssertNil(TakeCompare.keepOnly("nope", in: p))
    }

    func testKeepOnlyKeepsLockedTakes() throws {
        var p = Project()
        p.tracks[0].clips = [voice("a", "こんにちは", start: 0), voice("b", "こんにちは", start: 3)]
        p.tracks[1].clips = [voice("c", "こんにちは", start: 0)]
        p.tracks[1].locked = true
        let r = try XCTUnwrap(TakeCompare.keepOnly("b", in: p))
        XCTAssertEqual(r.removed, ["a"]); XCTAssertEqual(r.skippedLocked, 1)
        XCTAssertEqual(r.project.tracks[1].clips.count, 1)
        p.tracks[0].clips[0].locked = true
        XCTAssertNil(TakeCompare.keepOnly("b", in: p), "取り除けるものが無い")
    }
}
