import XCTest
@testable import MovieCutCore

/// テロップとセリフの検索・一括置換(TextSearch)の純粋な計算。
final class TextSearchTests: XCTestCase {
    private func text(_ id: String, _ s: String, start: Double = 0) -> Clip {
        var c = Clip(); c.id = id; c.type = .text; c.text = s; c.start = start; c.duration = 2; c.fontSize = 80
        return c
    }
    private func voice(_ id: String, _ s: String, start: Double = 0) -> Clip {
        var c = Clip(); c.id = id; c.type = .voice; c.text = s; c.start = start; c.duration = 2; c.charId = "c1"
        return c
    }

    /// 1 レイヤーに文字とボイス、もう 1 レイヤーにも文字。
    private func project() -> Project {
        var p = Project.new()
        p.tracks[0].clips = [text("t1", "霊夢と魔理沙"), voice("v1", "霊夢です。よろしく霊夢", start: 3)]
        p.tracks[1].clips = [text("t2", "Reimu and reimu", start: 0), text("t3", "なし")]
        return p
    }

    func testEmptyQueryFindsNothing() {
        XCTAssertEqual(TextSearch.matches("", in: project()).count, 0)
        let r = TextSearch.replaceAll("", with: "x", in: project())
        XCTAssertTrue(r.changes.isEmpty)
        XCTAssertEqual(r.count, 0)
    }

    func testMatchesCountAcrossTextAndVoiceClipsWithoutOverlap() {
        let ms = TextSearch.matches("霊夢", in: project())
        // t1 に 1 つ、v1 に 2 つ(「霊夢です」「よろしく霊夢」)
        XCTAssertEqual(ms.map(\.clipId), ["t1", "v1", "v1"])
        XCTAssertEqual(ms[1], TextSearch.Match(clipId: "v1", location: 0, length: 2))
        XCTAssertEqual(ms[2], TextSearch.Match(clipId: "v1", location: 9, length: 2))
    }

    func testNonOverlappingLeftToRight() {
        // "aaaa" に "aa" は 2 件(重ならない)
        var p = Project.new(); p.tracks[0].clips = [text("t", "aaaa")]
        XCTAssertEqual(TextSearch.matches("aa", in: p).count, 2)
        let r = TextSearch.replaceAll("aa", with: "b", in: p)
        XCTAssertEqual(r.count, 2)
        XCTAssertEqual(r.project.tracks[0].clips[0].text, "bb")
    }

    func testCaseOptionDefaultIgnoresCase() {
        XCTAssertEqual(TextSearch.matches("reimu", in: project()).count, 2)
        let strict = TextSearch.Options(caseSensitive: true)
        XCTAssertEqual(TextSearch.matches("reimu", in: project(), options: strict).count, 1)
        XCTAssertEqual(TextSearch.matches("Reimu", in: project(), options: strict).count, 1)
    }

    func testSelectionScopeLimitsMatchesAndReplacement() {
        let scope: Set<String> = ["t2"]
        XCTAssertEqual(TextSearch.matches("reimu", in: project(), scope: scope).map(\.clipId), ["t2", "t2"])
        let r = TextSearch.replaceAll("reimu", with: "Ruby", in: project(), scope: scope)
        XCTAssertEqual(r.changes.map(\.clipId), ["t2"])
        XCTAssertEqual(r.project.allClips.first { $0.id == "t1" }?.text, "霊夢と魔理沙")
        XCTAssertEqual(r.project.allClips.first { $0.id == "v1" }?.text, "霊夢です。よろしく霊夢")
    }

    func testReplaceAllMarksVoiceChangesAndKeepsOthers() {
        let r = TextSearch.replaceAll("霊夢", with: "霊夢さん", in: project())
        XCTAssertEqual(r.count, 3)
        XCTAssertEqual(r.changes, [
            TextSearch.Change(clipId: "t1", text: "霊夢さんと魔理沙", isVoice: false),
            TextSearch.Change(clipId: "v1", text: "霊夢さんです。よろしく霊夢さん", isVoice: true),
        ])
        XCTAssertEqual(r.project.allClips.first { $0.id == "t3" }?.text, "なし")
    }

    func testNoOpReplacementChangesNothing() {
        // 同じ文字に置き換えても、何も変わらない(Undo に載せない判定の元)
        let p = project()
        let r = TextSearch.replaceAll("霊夢", with: "霊夢", in: p)
        XCTAssertTrue(r.changes.isEmpty)
        XCTAssertEqual(r.count, 0)
        XCTAssertEqual(r.project, p)
        // 一致しない
        XCTAssertTrue(TextSearch.replaceAll("zzz", with: "y", in: project()).changes.isEmpty)
    }

    func testCaseOnlyChangeCounts() {
        let r = TextSearch.replaceAll("reimu", with: "REIMU", in: project())
        XCTAssertEqual(r.count, 2)
        XCTAssertEqual(r.project.allClips.first { $0.id == "t2" }?.text, "REIMU and REIMU")
    }

    func testLockedLayerIsNotReplacedButCounted() {
        var p = project()
        p.tracks[1].locked = true
        let r = TextSearch.replaceAll("reimu", with: "x", in: p)
        XCTAssertTrue(r.changes.isEmpty)
        XCTAssertEqual(r.count, 0)
        XCTAssertEqual(r.lockedMatches, 2)
        XCTAssertEqual(r.project, p)
    }

    func testVoiceThatWouldBecomeEmptyIsSkipped() {
        var p = Project.new()
        p.tracks[0].clips = [voice("v", "はい"), text("t", "はい")]
        let r = TextSearch.replaceAll("はい", with: "  ", in: p)
        XCTAssertEqual(r.skippedEmptyVoices, 1)
        XCTAssertEqual(r.changes.map(\.clipId), ["t"])
        XCTAssertEqual(r.project.allClips.first { $0.id == "v" }?.text, "はい")
    }

    func testDeleteByEmptyReplacementOnTextClip() {
        var p = Project.new(); p.tracks[0].clips = [text("t", "a-b-c")]
        let r = TextSearch.replaceAll("-", with: "", in: p)
        XCTAssertEqual(r.project.tracks[0].clips[0].text, "abc")
        XCTAssertEqual(r.count, 2)
    }

    func testOtherClipTypesAreNotTargets() {
        var p = Project.new()
        var img = Clip(); img.id = "i"; img.type = .image; img.src = "/x.png"; img.duration = 1
        p.tracks[0].clips = [img]
        XCTAssertEqual(TextSearch.matches("a", in: p).count, 0)
    }
}
