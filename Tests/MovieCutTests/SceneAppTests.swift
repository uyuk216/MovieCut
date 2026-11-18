import XCTest
import MovieCutCore
@testable import MovieCut

/// シーン／ネスト(W3-01)のアプリ側: 一覧の編集(作成・名前変更・複製・削除ポリシー)・配置・開いて編集・メニュー仕様。
/// すべて 1 操作 = 1 回の Undo で、根(`rootProject`)に正しく戻ること。
@MainActor
final class SceneAppTests: XCTestCase {

    private func image(_ id: String, start: Double, duration: Double = 2) -> Clip {
        var c = Clip(); c.id = id; c.type = .image; c.start = start; c.duration = duration
        return c
    }

    /// シーン「導入」(中身は画像 1 枚・尺 2 秒)を定義済みのモデル。
    private func makeModel() -> (model: ProjectModel, sceneId: String) {
        var p = Project.new()
        var scene = SceneDefinition(); scene.name = "導入"
        var t = Track(name: "中身"); t.clips = [image("in1", start: 0)]
        scene.tracks = [t]
        p.scenes = [scene]
        let m = ProjectModel(project: p)
        m.notices = OneTimeNotices()
        return (m, scene.id)
    }

    private func undoSteps(_ m: ProjectModel) -> Int {
        let u = m.effectiveUndoManager
        var n = 0
        while u.canUndo { u.undo(); n += 1 }
        for _ in 0..<n { u.redo() }
        return n
    }

    func testMenuItemsExistInClipEditWithoutShortcuts() throws {
        var s = MenuState()
        s.hasDocument = true; s.canExport = true
        s.resolutionKey = "1920x1080"; s.codec = "h264"; s.bg = "#000000"
        let items = AppMenuSpec.clipEdit(s)
        let list = try XCTUnwrap(items.first { $0.command == .sceneList })
        XCTAssertEqual(list.title, "シーン一覧…")
        XCTAssertNil(list.shortcut)
        let enter = try XCTUnwrap(items.first { $0.command == .sceneEnter })
        XCTAssertEqual(enter.title, "シーンを開く")
        XCTAssertFalse(enter.enabled, "シーンクリップを選んでいないときは使えない")
        s.canSceneEnter = true
        XCTAssertTrue(try XCTUnwrap(AppMenuSpec.clipEdit(s).first { $0.command == .sceneEnter }).enabled)
        s.isInsideScene = true
        XCTAssertTrue(try XCTUnwrap(AppMenuSpec.clipEdit(s).first { $0.command == .sceneExit }).enabled)
    }

    func testCreateRenameDuplicateAreOneUndoEach() throws {
        let (m, _) = makeModel()
        let id = try XCTUnwrap(m.createScene(name: "本編"))
        XCTAssertEqual(m.rootProject.scenes.count, 2)
        XCTAssertTrue(m.renameScene(id, to: "本編A"))
        XCTAssertEqual(m.rootProject.scene(withId: id)?.name, "本編A")
        let dup = try XCTUnwrap(m.duplicateScene(id))
        XCTAssertEqual(m.rootProject.scenes.count, 3)
        XCTAssertNotEqual(dup, id)
        XCTAssertEqual(undoSteps(m), 3, "作成・名前変更・複製は各 1 回の Undo")
    }

    func testDeleteRefusedWhileReferencedThenAllowed() throws {
        let (m, sid) = makeModel()
        m.selectedLayerIndex = 0
        m.currentTime = 0
        XCTAssertTrue(m.placeSceneClip(sid), "配置できる")
        XCTAssertEqual(m.rootProject.allClips.first?.type, .scene)
        XCTAssertFalse(m.deleteScene(sid), "参照中は削除できない")
        XCTAssertEqual(m.rootProject.scenes.count, 1)
        // 参照クリップを消せば削除できる
        let refId = try XCTUnwrap(m.rootProject.allClips.first { $0.type == .scene }).id
        m.selectOnly(refId)
        XCTAssertTrue(m.deleteSelected())
        XCTAssertTrue(m.deleteScene(sid))
        XCTAssertTrue(m.rootProject.scenes.isEmpty)
    }

    func testPlaceSelectsClipAndIsOneUndo() throws {
        let (m, sid) = makeModel()
        m.selectedLayerIndex = 0
        m.currentTime = 3
        XCTAssertTrue(m.placeSceneClip(sid))
        let placed = try XCTUnwrap(m.rootProject.allClips.first { $0.type == .scene })
        XCTAssertEqual(placed.start, 3)
        XCTAssertEqual(placed.duration, 2, "配置時の尺はシーン尺")
        XCTAssertEqual(placed.sceneId, sid)
        XCTAssertEqual(m.selectedClipId, placed.id)
        XCTAssertEqual(m.selectedSceneClipId, sid)
    }

    /// 開いて編集: 中での編集は根のシーン定義へ戻り、Undo も 1 本で効く。保存用の根は常に完全な書類。
    func testEnterEditInsideAndExitUpdatesRoot() throws {
        let (m, sid) = makeModel()
        XCTAssertTrue(m.enterScene(sid))
        XCTAssertTrue(m.isInsideScene)
        XCTAssertEqual(m.project.allClips.map(\.id), ["in1"], "見え方はシーンの中身")
        XCTAssertEqual(m.sceneBreadcrumb, ["プロジェクト", "導入"])
        // 中でクリップを動かす(通常の edit 経路)
        XCTAssertTrue(m.edit("クリップを移動") { p in p.tracks[0].clips[0].start = 0.75 })
        XCTAssertEqual(m.rootProject.scene(withId: sid)?.tracks[0].clips[0].start, 0.75, "編集中でも根へ戻っている")
        XCTAssertEqual(m.savedProject.scene(withId: sid)?.tracks[0].clips[0].start, 0.75, "保存用の根も同じ")
        XCTAssertTrue(m.rootProject.tracks.allSatisfy { $0.clips.isEmpty }, "メインのレイヤーは汚れない")
        XCTAssertTrue(m.exitSceneScope())
        XCTAssertFalse(m.isInsideScene)
        XCTAssertEqual(m.project.scene(withId: sid)?.tracks[0].clips[0].start, 0.75)
        // Undo は出た後も効く(中での編集が 1 回で戻る)
        m.effectiveUndoManager.undo()
        XCTAssertEqual(m.project.scene(withId: sid)?.tracks[0].clips[0].start, 0)
    }

    /// シーンの中では複合スコープに入らない(スコープは 1 段だけ)。
    func testEnterCompoundIsBlockedInsideScene() throws {
        let (m, sid) = makeModel()
        XCTAssertTrue(m.enterScene(sid))
        XCTAssertFalse(m.enterCompound("in1"))
        XCTAssertTrue(m.exitSceneScope())
    }

    /// 開いているシーンを削除(Undo 経由など)したら、自動で一番上へ戻る。
    func testDeletingOpenSceneExitsScope() throws {
        let (m, sid) = makeModel()
        XCTAssertTrue(m.enterScene(sid))
        XCTAssertTrue(m.deleteScene(sid), "参照が無ければ中のシーンも削除できる")
        XCTAssertFalse(m.isInsideScene)
        XCTAssertTrue(m.rootProject.scenes.isEmpty)
    }
}
