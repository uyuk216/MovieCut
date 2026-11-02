import XCTest
import AppKit
import MovieCutCore
@testable import MovieCut

/// タイムラインの問い合わせのモデル操作: 前後の空白へ・再生位置のクリップを選ぶ・短いクリップを選ぶ・選んだ範囲を書き出し範囲に。
@MainActor
final class TimelineQueryAppTests: XCTestCase {
    private func clip(_ id: String, _ start: Double, _ dur: Double) -> Clip {
        var c = Clip(); c.id = id; c.type = .text; c.text = id; c.start = start; c.duration = dur; c.fontSize = 60
        return c
    }

    /// 0–1、2–3、5–6、6.5–6.6 の 1 レイヤー(空白は 1・3・6 秒から)。fps 10 なので 1 コマ = 0.1 秒。
    private func makeModel() -> ProjectModel {
        var p = Project.new()
        p.width = 320; p.height = 180; p.fps = 10
        p.tracks[4].clips = [clip("a", 0, 1), clip("b", 2, 1), clip("c", 5, 1), clip("tiny", 6.5, 0.1)]
        let m = ProjectModel(project: p)
        m.notices = OneTimeNotices()
        return m
    }

    private func undoSteps(_ m: ProjectModel) -> Int {
        let u = m.effectiveUndoManager
        var n = 0
        while u.canUndo { u.undo(); n += 1 }
        for _ in 0..<n { u.redo() }
        return n
    }

    func testSeekGapMovesToGapStartsAndStopsAtEnds() {
        let m = makeModel()
        XCTAssertTrue(m.seekGap(forward: true))
        XCTAssertEqual(m.currentTime, 1, accuracy: 1e-9, "最初の空白は 1 秒")
        XCTAssertTrue(m.seekGap(forward: true))
        XCTAssertEqual(m.currentTime, 3, accuracy: 1e-9)
        XCTAssertTrue(m.seekGap(forward: true))
        XCTAssertEqual(m.currentTime, 6, accuracy: 1e-9, "c の後ろ(tiny の手前)も空白")
        XCTAssertFalse(m.seekGap(forward: true), "最後のクリップの後ろは空白に数えない")
        XCTAssertTrue(m.seekGap(forward: false))
        XCTAssertEqual(m.currentTime, 3, accuracy: 1e-9)
        XCTAssertTrue(m.seekGap(forward: false))
        XCTAssertEqual(m.currentTime, 1, accuracy: 1e-9)
    }

    func testSelectClipAtPlayheadSelectsOneClipOrNothing() {
        let m = makeModel()
        m.currentTime = 0.5
        XCTAssertTrue(m.selectClipAtPlayhead())
        XCTAssertEqual(m.selectedClipId, "a")
        m.currentTime = 4
        XCTAssertFalse(m.selectClipAtPlayhead(), "空白の上では何も選ばない")
        XCTAssertEqual(m.selectedClipId, "a", "選びそこねたら選択は変えない")
    }

    func testSelectShortClipsSelectsOnlyTheShortOne() {
        let m = makeModel()
        XCTAssertTrue(m.selectShortClips())
        XCTAssertEqual(m.selectedClipIDs, ["tiny"])
        let plain = ProjectModel(project: Project.new())
        plain.notices = OneTimeNotices()
        XCTAssertFalse(plain.selectShortClips(), "短いクリップが無いときは何もしない")
    }

    func testRangeFromSelectionIsOneUndoStepAndNoOpWhenSame() {
        let m = makeModel()
        m.selectOnly("b")
        m.selectShortClips()          // 選択を tiny に変えてから、a と b の範囲を作る
        m.setSelection(ClipSelection(ids: ["a", "b"], primary: "a"))
        let before = undoSteps(m)
        XCTAssertTrue(m.setRangeFromSelection())
        XCTAssertEqual(m.project.rangeIn ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(m.project.rangeOut ?? -1, 3, accuracy: 1e-9)
        XCTAssertEqual(undoSteps(m), before + 1, "1 回の操作は Undo 1 回")
        XCTAssertFalse(m.setRangeFromSelection(), "同じ範囲のときは何もしない(履歴に載せない)")
    }

    func testSpeechShareStatusLine() {
        let m = makeModel()
        m.showSpeechShareStatus()
        XCTAssertEqual(m.statusText, "セリフ(声のクリップ)がありません")
        var v = clip("v", 0, 3)
        v.type = .voice
        v.text = "こんにちは"
        v.charId = m.project.characters[0].id
        m.project.tracks[4].clips.append(v)
        m.showSpeechShareStatus()
        XCTAssertTrue(m.statusText.hasPrefix("発話時間: \(m.project.characters[0].name) 100%"), m.statusText)
    }

    func testRangeFromSelectionWithoutSelectionDoesNothing() {
        let m = makeModel()
        XCTAssertFalse(m.setRangeFromSelection())
        XCTAssertNil(m.project.rangeIn)
    }
}
