import XCTest
import MovieCutCore
@testable import MovieCut

/// Remix(アプリ側): 作成が 1 回の Undo で戻ること、元クリップを変えないこと、
/// 作れないときは何もしないこと、メニュー項目の有効/無効。
@MainActor
final class RemixAppTests: XCTestCase {
    /// 20 秒の音声クリップ 1 本だけのプロジェクト。
    private func makeModel() -> ProjectModel {
        var p = Project.new()
        var c = Clip(); c.id = "a"; c.type = .audio; c.start = 0; c.duration = 20; c.src = "/x.wav"
        var t = Track(name: "音"); t.clips = [c]
        p.tracks = [t]
        let m = ProjectModel(project: p)
        m.notices = OneTimeNotices()
        m.selectedClipId = "a"
        return m
    }

    /// 0.5 秒間隔のビート候補。
    private var candidates: [Double] { (1..<40).map { Double($0) * 0.5 } }

    func testApplyRemixIsOneUndoStepAndKeepsOriginal() {
        let m = makeModel()
        let original = m.project.tracks[0].clips[0]
        XCTAssertTrue(m.applyRemix(clipId: "a", candidates: candidates, usedFallback: false,
                                   params: RemixParams(targetDuration: 10)))
        XCTAssertEqual(m.effectiveUndoManager.undoActionName, "Remix")
        let clips = m.project.tracks[0].clips.sorted { $0.start < $1.start }
        XCTAssertGreaterThan(clips.count, 1)
        XCTAssertEqual(clips.first { $0.id == "a" }, original, "元クリップは変更しない")
        let made = clips.filter { $0.id != "a" }
        XCTAssertEqual(made.first?.start ?? -1, 20, accuracy: 1e-9, "レイヤーの末尾から配置")
        XCTAssertLessThanOrEqual(abs(made.map(\.duration).reduce(0, +) - 10), 0.5, "目標尺に近い")
        m.effectiveUndoManager.undo()
        XCTAssertEqual(m.project.tracks[0].clips, [original], "1 回の Undo で元に戻る")
    }

    func testApplyRemixFailureChangesNothingAndRegistersNoUndo() {
        let m = makeModel()
        let before = m.project
        XCTAssertFalse(m.applyRemix(clipId: "a", candidates: [], usedFallback: false,
                                    params: RemixParams(targetDuration: 10)), "候補が無ければ作らない")
        XCTAssertEqual(m.project, before)
        XCTAssertFalse(m.effectiveUndoManager.canUndo, "Undo に載らない")
        XCTAssertFalse(m.statusText.isEmpty, "理由を状態欄に出す")
    }

    func testMenuItemNeedsARemixableClip() {
        var s = MenuState(); s.hasDocument = true
        let item = AppMenuSpec.remixItem(s)
        XCTAssertEqual(item.title, "Remixツール…")
        XCTAssertNil(item.shortcut)
        XCTAssertFalse(item.enabled, "対象クリップを選んでいないときは押せない")
        s.canRemix = true
        XCTAssertTrue(AppMenuSpec.remixItem(s).enabled)
        XCTAssertTrue(AppMenuSpec.all(s).contains { $0.command == .remix }, "全体の項目表にも入っている")
    }
}
