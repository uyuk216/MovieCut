import XCTest
import MovieCutCore
@testable import MovieCut

/// 編集 ▸ 検索と置換…: モデルの一括置換(Undo は 1 回・何も変えないなら登録しない・セリフは音声を作り直す)、
/// 件数の表示、メニューの項目。
@MainActor
final class FindReplaceAppTests: XCTestCase {
    private func text(_ id: String, _ s: String, start: Double = 0) -> Clip {
        var c = Clip(); c.id = id; c.type = .text; c.text = s; c.start = start; c.duration = 2; c.fontSize = 80
        return c
    }

    private func voice(_ id: String, _ s: String, charId: String, start: Double = 3) -> Clip {
        var c = Clip(); c.id = id; c.type = .voice; c.text = s; c.start = start; c.duration = 2; c.charId = charId; c.src = "/tmp/none.wav"
        return c
    }

    private func makeModel() -> (ProjectModel, String) {
        var p = Project.new()
        let charId = p.characters[0].id
        p.tracks[0].clips = [text("t1", "霊夢のテロップ"), voice("v1", "霊夢です", charId: charId)]
        p.tracks[1].clips = [text("t2", "魔理沙と霊夢", start: 0)]
        let m = ProjectModel(project: p)
        m.notices = OneTimeNotices()
        m.voiceProviderFactory = { _ in ToneVoiceProvider(durations: [1.0], frequencies: [330]) }
        return (m, charId)
    }

    private func undoCount(_ m: ProjectModel) -> Int {
        let u = m.effectiveUndoManager
        var n = 0
        while u.canUndo { u.undo(); n += 1 }
        for _ in 0..<n { u.redo() }
        return n
    }

    func testReplaceAllIsOneUndoStepAndUndoRestoresEverything() async {
        let (m, _) = makeModel()
        let before = m.project
        let n = await m.replaceAllText("霊夢", with: "霊夢さん", options: TextSearch.Options(), selectionOnly: false)
        XCTAssertEqual(n, 3)
        XCTAssertEqual(m.project.allClips.first { $0.id == "t1" }?.text, "霊夢さんのテロップ")
        XCTAssertEqual(m.project.allClips.first { $0.id == "t2" }?.text, "魔理沙と霊夢さん")
        XCTAssertEqual(m.effectiveUndoManager.undoActionName, ProjectModel.findReplaceUndoName)
        XCTAssertEqual(undoCount(m), 1)
        m.effectiveUndoManager.undo()
        XCTAssertEqual(m.project, before)
    }

    func testNoOpRegistersNothing() async {
        let (m, _) = makeModel()
        let n = await m.replaceAllText("霊夢", with: "霊夢", options: TextSearch.Options(), selectionOnly: false)
        XCTAssertEqual(n, 0)
        XCTAssertFalse(m.effectiveUndoManager.canUndo)
        let none = await m.replaceAllText("存在しない", with: "x", options: TextSearch.Options(), selectionOnly: false)
        XCTAssertEqual(none, 0)
        XCTAssertFalse(m.effectiveUndoManager.canUndo)
    }

    func testVoiceLineChangeRegeneratesAudioInSameUndoStep() async {
        let (m, _) = makeModel()
        let oldSrc = m.project.allClips.first { $0.id == "v1" }?.src
        _ = await m.replaceAllText("霊夢", with: "霊夢ちゃん", options: TextSearch.Options(), selectionOnly: false)
        let v = m.project.allClips.first { $0.id == "v1" }
        XCTAssertEqual(v?.text, "霊夢ちゃんです")
        XCTAssertNotNil(v?.src)
        XCTAssertNotEqual(v?.src, oldSrc, "セリフの文字が変わったので音声を作り直す")
        XCTAssertEqual(v?.offset, 0)
        XCTAssertEqual(undoCount(m), 1)
    }

    func testSelectionOnlyLeavesOtherClipsAlone() async {
        let (m, _) = makeModel()
        m.selectedClipIDs = ["t2"]
        m.selectedClipId = "t2"
        XCTAssertEqual(m.findTextMatchCount("霊夢", selectionOnly: true, options: TextSearch.Options()), 1)
        let n = await m.replaceAllText("霊夢", with: "X", options: TextSearch.Options(), selectionOnly: true)
        XCTAssertEqual(n, 1)
        XCTAssertEqual(m.project.allClips.first { $0.id == "t1" }?.text, "霊夢のテロップ")
        XCTAssertEqual(m.project.allClips.first { $0.id == "t2" }?.text, "魔理沙とX")
    }

    func testCountFollowsCaseOption() {
        let (m, _) = makeModel()
        XCTAssertEqual(m.findTextMatchCount("REIMU", selectionOnly: false, options: TextSearch.Options()), 0)
        XCTAssertEqual(m.findTextMatchCount("霊夢", selectionOnly: false, options: TextSearch.Options(caseSensitive: true)), 3)
    }

    func testFindReplaceMenuItemIsInEditMenuWithoutShortcut() {
        let (m, _) = makeModel()
        let s = MenuState(model: m)
        let item = AppMenuSpec.findReplace(s)
        XCTAssertEqual(item.title, "検索と置換…")
        XCTAssertNil(item.shortcut)
        XCTAssertTrue(item.enabled)
        XCTAssertTrue(AppMenuSpec.all(s).contains(item))
        // 文字もセリフもないプロジェクトでは無効
        let empty = ProjectModel(project: Project.new())
        XCTAssertFalse(AppMenuSpec.findReplace(MenuState(model: empty)).enabled)
    }
}
