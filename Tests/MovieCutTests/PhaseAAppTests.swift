import XCTest
import AppKit
import MovieCutCore
@testable import MovieCut

/// 第2波バッチA のアプリ側: 範囲選択(⌥ ドラッグ)のモデル操作、重ねてクロスフェード、速度ランプのイージング変更。
/// どれも Undo は 1 回、何も変わらない操作は履歴に載せない。
@MainActor
final class PhaseAAppTests: XCTestCase {
    private func makeModel(_ build: (inout Project) -> Void) -> ProjectModel {
        var p = Project.new()
        p.width = 320; p.height = 180; p.fps = 10
        build(&p)
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

    private func text(_ id: String, _ start: Double, _ dur: Double) -> Clip {
        var c = Clip(); c.id = id; c.type = .text; c.text = id; c.start = start; c.duration = dur; c.fontSize = 60
        return c
    }

    // MARK: 範囲選択

    func testRangeSelectionSelectClipsAndDelete() {
        let m = makeModel { p in
            p.tracks[4].clips = [text("A", 0, 6)]
            p.tracks[3].clips = [text("B", 0, 6)]
        }
        m.rangeSelection = RangeSelection(start: 2, end: 4)
        XCTAssertTrue(m.hasRangeSelection)
        XCTAssertTrue(m.selectClipsInRangeSelection())
        XCTAssertEqual(m.selectedClipIDs, ["A", "B"])
        // 範囲の削除は範囲選択を優先し、選択の解除まで 1 回の Undo
        XCTAssertTrue(m.deleteRange(ripple: false))
        XCTAssertNil(m.rangeSelection)
        XCTAssertEqual(m.project.tracks[4].clips.map { [$0.start, $0.duration] }, [[0, 2], [4, 2]])
        XCTAssertEqual(m.project.tracks[3].clips.map { [$0.start, $0.duration] }, [[0, 2], [4, 2]])
        XCTAssertEqual(undoSteps(m), 1)
        // メニュー: 範囲選択があるときだけ有効な項目が並ぶ
        var s = MenuState(); s.hasDocument = true; s.canMarkRange = true; s.hasRangeSelection = true
        let items = AppMenuSpec.rangeDeleteItems(s)
        XCTAssertEqual(items.map(\.title), ["範囲を削除", "範囲をリップル削除", "範囲内のクリップを選択", "範囲選択を解除"])
        XCTAssertTrue(items.allSatisfy { item in AppMenuSpec.all(s).contains { $0.command == item.command } })
        XCTAssertTrue(items[0].enabled && items[2].enabled)
        var s2 = MenuState(); s2.hasDocument = true; s2.canMarkRange = true
        XCTAssertFalse(AppMenuSpec.rangeDeleteItems(s2)[0].enabled)   // 範囲も選択も無ければ削除は押せない
    }

    func testRangeSelectionScopedDeleteViaModel() {
        let m = makeModel { p in
            p.tracks[4].clips = [text("A", 0, 6)]
            p.tracks[3].clips = [text("B", 0, 6)]
        }
        // レイヤー 4 だけを対象にした範囲選択: レイヤー 3 は割もしない
        m.rangeSelection = RangeSelection(start: 2, end: 4, trackIndices: [4])
        XCTAssertTrue(m.deleteRange(ripple: false))
        XCTAssertEqual(m.project.tracks[4].clips.count, 2)
        XCTAssertEqual(m.project.tracks[3].clips.map { [$0.start, $0.duration] }, [[0, 6]])
    }

    // MARK: 重ねてクロスフェード

    func testOverlapCrossfadeViaModel() {
        let m = makeModel { p in
            p.tracks[4].clips = [text("A", 1, 4), text("B", 6, 4)]
        }
        m.selectOnly("B")
        XCTAssertTrue(m.overlapCrossfadeSelected())
        let b = m.project.tracks[4].clips[1]
        XCTAssertEqual(b.start, 5.5)
        XCTAssertEqual(b.transitionIn?.kind, "fade")
        XCTAssertEqual(undoSteps(m), 1)
        // メニューに並び、ショートカットは持たない
        var s = MenuState(); s.hasDocument = true; s.canTransition = true
        let quick = AppMenuSpec.transitionQuick(s)
        XCTAssertEqual(quick.map(\.title), ["クロスフェードにする", "重ねてクロスフェード", "フェードイン・アウトを付ける"])
        XCTAssertTrue(quick.allSatisfy { $0.shortcut == nil })
        XCTAssertTrue(AppMenuSpec.all(s).contains { $0.command == .overlapCrossfade })
    }

    // MARK: 速度ランプのイージング

    func testSetSpeedRampEaseViaModel() {
        let m = makeModel { p in
            var v = Clip(); v.id = "V"; v.type = .video; v.src = "/tmp/none.mp4"; v.start = 0; v.duration = 4; v.srcDuration = 100
            p.tracks[4].clips = [v]
        }
        XCTAssertTrue(m.makeSpeedRamp(clipId: "V"))
        XCTAssertTrue(m.setSpeedRampEase(clipId: "V", index: 0, ease: .easeIn))
        XCTAssertEqual(m.clip("V")?.rampPoints?.first?.ease, .easeIn)
        XCTAssertEqual(undoSteps(m), 2)   // ランプ作成 1 回 + イージング変更 1 回
        // 最後の点は次の区間が無いので変えない(履歴にも載せない)
        XCTAssertFalse(m.setSpeedRampEase(clipId: "V", index: 1, ease: .easeOut))
        XCTAssertEqual(undoSteps(m), 2)
        // 同じ値の再設定も履歴に載せない
        XCTAssertFalse(m.setSpeedRampEase(clipId: "V", index: 0, ease: .easeIn))
        XCTAssertEqual(undoSteps(m), 2)
    }
}
