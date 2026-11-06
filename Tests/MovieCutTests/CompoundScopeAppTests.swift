import XCTest
import MovieCutCore
@testable import MovieCut

/// 複合クリップの中を編集する: 入る・出る・中での編集(分割・動かす・削除・追加)・共通の Undo・ロック・メニュー。
@MainActor
final class CompoundScopeAppTests: XCTestCase {

    private func clip(_ id: String, start: Double, duration: Double = 4) -> Clip {
        var c = Clip(); c.id = id; c.type = .image; c.start = start; c.duration = duration
        return c
    }

    /// a(0〜4)・b(1〜5)をまとめた複合クリップを 1 つ持つモデル(まとめた直後は複合クリップを選んでいる)。
    private func makeModel() throws -> (m: ProjectModel, compoundId: String) {
        var p = Project.new()
        p.tracks[0].clips = [clip("a", start: 0)]
        p.tracks[1].clips = [clip("b", start: 1)]
        let m = ProjectModel(project: p)
        m.notices = OneTimeNotices()
        m.selectedClipIDs = ["a", "b"]; m.selectedClipId = "a"
        XCTAssertTrue(m.groupSelectedCompound())
        return (m, try XCTUnwrap(m.selectedClipId))
    }

    private func undoSteps(_ m: ProjectModel) -> Int {
        let u = m.effectiveUndoManager
        var n = 0
        while u.canUndo { u.undo(); n += 1 }
        for _ in 0..<n { u.redo() }
        return n
    }

    func testEnterShowsInnerLayersAndExitRestores() throws {
        let (m, id) = try makeModel()
        let root = m.project
        XCTAssertTrue(m.enterCompound())
        XCTAssertTrue(m.isInsideCompound)
        XCTAssertEqual(m.project.allClips.map(\.id).sorted(), ["a", "b"])
        XCTAssertEqual(m.compoundBreadcrumb, ["プロジェクト", "複合クリップ 1"])
        XCTAssertEqual(m.rootProject, root, "入っただけでは書類は変わらない")
        XCTAssertEqual(m.mirror.get(), root, "保存用の写しは書類全体のまま")
        XCTAssertTrue(m.exitCompound())
        XCTAssertFalse(m.isInsideCompound)
        XCTAssertEqual(m.project, root)
        XCTAssertEqual(m.selectedClipId, id, "出たら複合クリップを選ぶ")
        XCTAssertFalse(m.exitCompound(), "一番上では何もしない")
        XCTAssertEqual(undoSteps(m), 1, "入る・出るは Undo に載らない(まとめの 1 回だけ)")
    }

    func testEnterRejectsNonCompound() throws {
        var p = Project.new(); p.tracks[0].clips = [clip("a", start: 0)]
        let m = ProjectModel(project: p); m.notices = OneTimeNotices()
        m.selectOnly("a")
        XCTAssertFalse(m.enterCompound())
        XCTAssertFalse(m.isInsideCompound)
    }

    func testInnerSplitIsOneUndoStepAndReachesRootDocument() throws {
        let (m, id) = try makeModel()
        XCTAssertTrue(m.enterCompound())
        m.selectOnly("a")
        m.currentTime = 2
        XCTAssertTrue(m.splitSelected())
        XCTAssertEqual(m.project.allClips.count, 3)
        let inner = try XCTUnwrap(CompoundScope.innerTracks(of: m.rootProject, path: [id]))
        XCTAssertEqual(inner.flatMap(\.clips).count, 3, "根の複合クリップの中身が変わっている")
        XCTAssertEqual(m.mirror.get().allClips.first { $0.id == id }?.tracks?.flatMap(\.clips).count, 3, "保存の写しにも入る")
        m.effectiveUndoManager.undo()
        XCTAssertEqual(m.project.allClips.count, 2, "中にいたまま Undo すると中が戻る(1 回で)")
        XCTAssertTrue(m.isInsideCompound)
        m.effectiveUndoManager.redo()
        XCTAssertEqual(m.project.allClips.count, 3)
        XCTAssertTrue(m.exitCompound())
        XCTAssertEqual(undoSteps(m), 2, "まとめ 1 回 + 分割 1 回(Undo の列は共通)")
    }

    func testUndoAfterExitStillUndoesTheInnerEdit() throws {
        let (m, id) = try makeModel()
        XCTAssertTrue(m.enterCompound())
        m.selectOnly("b")
        XCTAssertTrue(m.deleteSelected())
        XCTAssertEqual(m.project.allClips.map(\.id), ["a"])
        XCTAssertTrue(m.exitCompound())
        XCTAssertEqual(m.project.allClips.first { $0.id == id }?.tracks?.flatMap(\.clips).count, 1)
        m.effectiveUndoManager.undo()
        XCTAssertEqual(m.project.allClips.first { $0.id == id }?.tracks?.flatMap(\.clips).count, 2, "出た後の Undo で中の削除が戻る")
        XCTAssertEqual(undoSteps(m), 1, "残りはまとめの 1 回")
    }

    func testUndoOfGroupWhileInsideLeavesTheCompound() throws {
        let (m, _) = try makeModel()
        XCTAssertTrue(m.enterCompound())
        m.effectiveUndoManager.undo()   // まとめを取り消す = 複合クリップが無くなる → 外へ出る
        XCTAssertFalse(m.isInsideCompound)
        XCTAssertEqual(m.project.allClips.map(\.id).sorted(), ["a", "b"])
        m.effectiveUndoManager.redo()
        XCTAssertTrue(m.project.allClips.contains { $0.type == .compound })
    }

    func testInnerMoveTrimAndAdd() throws {
        let (m, id) = try makeModel()
        XCTAssertTrue(m.enterCompound())
        // 動かす
        let mv = try XCTUnwrap(ClipEditing.move(in: m.project, clipId: "a", deltaT: 0.5, targetTrackIndex: nil, playhead: 0, pps: 100, snapEnabled: false).project)
        XCTAssertTrue(m.edit("クリップの移動") { $0 = mv })
        XCTAssertEqual(m.project.allClips.first { $0.id == "a" }?.start ?? -1, 0.5, accuracy: 1e-9)
        // 右端をトリム
        let tr = try XCTUnwrap(ClipEditing.trimRight(in: m.project, clipId: "b", deltaT: -1, playhead: 0, pps: 100, snapEnabled: false).project)
        XCTAssertTrue(m.edit("右端のトリム") { $0 = tr })
        XCTAssertEqual(m.project.allClips.first { $0.id == "b" }?.duration ?? -1, 3, accuracy: 1e-9)
        // 追加
        var ids: [String] = []
        XCTAssertTrue(m.edit("素材の追加") { ids = ClipEditing.place(media: [("/tmp/x.png", .image, 2)], at: 1, in: &$0) })
        XCTAssertEqual(m.project.allClips.count, 3)
        XCTAssertTrue(m.exitCompound())
        XCTAssertEqual(undoSteps(m), 4, "まとめ + 3 つの編集 = 各 1 回")
        _ = id
    }

    func testLockedInnerLayerAndLockedCompoundAreRespected() throws {
        let (m, id) = try makeModel()
        XCTAssertTrue(m.enterCompound())
        // 中のレイヤーをロック → 中のクリップは消せない
        let ti = try XCTUnwrap(m.project.tracks.firstIndex { $0.clips.contains { $0.id == "a" } })
        XCTAssertTrue(m.edit("ロック") { $0.tracks[ti].locked = true })
        m.selectOnly("a")
        XCTAssertFalse(m.deleteSelected())
        XCTAssertEqual(m.project.allClips.count, 2)
        // 複合クリップ自身がロックされていれば、中の編集は(ロックされていないレイヤーでも)断る
        XCTAssertTrue(m.exitCompound())
        let before = m.project
        XCTAssertTrue(m.edit("ロック") { p in
            let t = p.tracks.firstIndex { $0.clips.contains { $0.id == id } }!
            p.tracks[t].locked = true
        })
        XCTAssertTrue(m.enterCompound(id), "ロックされていても中は見られる")
        let inner = m.project
        XCTAssertFalse(m.edit("削除") { $0.tracks = $0.tracks.map { var t = $0; t.clips = []; return t } }, "編集は断られる")
        XCTAssertEqual(m.project, inner)
        XCTAssertEqual(m.statusText, ProjectModel.lockedNotice)
        _ = before
    }

    func testExportLeavesTheCompoundAndMenuWiring() throws {
        let (m, id) = try makeModel()
        let s0 = MenuState()
        XCTAssertFalse(AppMenuSpec.clipEdit(s0).first { $0.command == .compoundExit }!.enabled)
        AppMenu.perform(.compoundEnter, model: m)
        XCTAssertTrue(m.isInsideCompound)
        var s = MenuState(); s.hasDocument = true; s.isInsideCompound = true
        let exit = try XCTUnwrap(AppMenuSpec.clipEdit(s).first { $0.command == .compoundExit })
        XCTAssertTrue(exit.enabled)
        XCTAssertEqual(exit.title, "複合クリップから出る")
        XCTAssertNil(exit.shortcut)
        _ = m.directExportBlocked()
        XCTAssertFalse(m.isInsideCompound, "書き出しの前に一番上へ戻る")
        XCTAssertTrue(m.project.allClips.contains { $0.id == id })
        AppMenu.perform(.compoundEnter, model: m)
        AppMenu.perform(.compoundExit, model: m)
        XCTAssertFalse(m.isInsideCompound)
    }
}
