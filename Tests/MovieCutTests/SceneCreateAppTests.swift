import XCTest
import MovieCutCore
@testable import MovieCut

/// 選択からシーンを作成(R2-3)のアプリ側: モデルの作成(1 操作 = 1 回の Undo・選択・既定名)・
/// メニュー仕様・シーンの中での作成・専用表示(タイムラインの色/ラベル、インスペクタの概要文)。
@MainActor
final class SceneCreateAppTests: XCTestCase {

    private func clip(_ id: String, start: Double) -> Clip {
        var c = Clip(); c.id = id; c.type = .image; c.start = start; c.duration = 2
        return c
    }

    /// 2 レイヤーに 1 本ずつクリップのあるモデル。
    private func makeModel() -> ProjectModel {
        var p = Project.new()
        p.tracks[0].clips = [clip("a", start: 0)]
        p.tracks[1].clips = [clip("b", start: 1)]
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

    func testCreateIsOneUndoStepAndSelectsTheSceneClip() throws {
        let m = makeModel()
        let before = m.project
        m.selectedClipIDs = ["a", "b"]
        m.selectedClipId = "a"
        let made = try XCTUnwrap(m.createSceneFromSelection())
        XCTAssertEqual(m.rootProject.scenes.count, 1)
        XCTAssertEqual(m.rootProject.scenes[0].name, "シーン 1", "名前は自動で付く")
        let sceneClip = try XCTUnwrap(m.rootProject.allClips.first { $0.type == .scene })
        XCTAssertEqual(sceneClip.id, made.clipId)
        XCTAssertEqual(sceneClip.sceneId, made.sceneId)
        XCTAssertEqual(m.selectedClipId, sceneClip.id, "作ったシーンクリップを選ぶ")
        XCTAssertEqual(undoSteps(m), 1, "作成は 1 回の Undo")
        m.effectiveUndoManager.undo()
        XCTAssertEqual(m.project, before, "Undo で元のプロジェクトに戻る")
        XCTAssertTrue(m.rootProject.scenes.isEmpty)
    }

    func testCreateNeedsSelection() {
        let m = makeModel()
        XCTAssertNil(m.createSceneFromSelection())
        XCTAssertTrue(m.rootProject.scenes.isEmpty)
        XCTAssertEqual(undoSteps(m), 0)
    }

    /// 既定名は重ならないように増える(2 回目は「シーン 2」。2 回目はシーンクリップ自体を選択から作る入れ子)。
    func testDefaultSceneNamesIncrement() throws {
        let m = makeModel()
        m.selectedClipIDs = ["a", "b"]
        m.selectedClipId = "a"
        XCTAssertEqual(m.defaultSceneName(), "シーン 1")
        _ = try XCTUnwrap(m.createSceneFromSelection())
        XCTAssertEqual(m.defaultSceneName(), "シーン 2")
        // いま選ばれているシーンクリップから、もう 1 段シーンを作れる
        _ = try XCTUnwrap(m.createSceneFromSelection())
        XCTAssertEqual(m.rootProject.scenes.map(\.name), ["シーン 1", "シーン 2"])
    }

    func testMenuItemExistsWithoutShortcutAndPerformCreates() throws {
        var s = MenuState()
        s.hasDocument = true; s.canExport = true
        s.resolutionKey = "1920x1080"; s.codec = "h264"; s.bg = "#000000"
        let item = try XCTUnwrap(AppMenuSpec.clipEdit(s).first { $0.command == .sceneCreateFromSelection })
        XCTAssertEqual(item.title, "選択からシーンを作成")
        XCTAssertNil(item.shortcut)
        XCTAssertFalse(item.enabled, "クリップを選んでいないときは使えない")
        s.canSceneCreate = true
        XCTAssertTrue(try XCTUnwrap(AppMenuSpec.clipEdit(s).first { $0.command == .sceneCreateFromSelection }).enabled)

        let m = makeModel()
        m.selectedClipIDs = ["a", "b"]
        m.selectedClipId = "a"
        AppMenu.perform(.sceneCreateFromSelection, model: m)
        XCTAssertEqual(m.rootProject.scenes.count, 1)
        XCTAssertEqual(m.rootProject.allClips.filter { $0.type == .scene }.count, 1)
    }

    /// シーンの中を編集中は、その中の選択から作れて、シーンクリップはホストのシーン定義の中へ置かれる。
    func testCreateInsideSceneScope() throws {
        var p = Project.new()
        var scene = SceneDefinition(); scene.name = "導入"
        var t = Track(name: "中身"); t.clips = [clip("in1", start: 0), clip("in2", start: 3)]
        scene.tracks = [t]
        p.scenes = [scene]
        let m = ProjectModel(project: p)
        m.notices = OneTimeNotices()
        XCTAssertTrue(m.enterScene(scene.id))
        m.selectedClipIDs = ["in1", "in2"]
        m.selectedClipId = "in1"
        let made = try XCTUnwrap(m.createSceneFromSelection(name: "内側"))
        XCTAssertEqual(m.rootProject.scenes.count, 2)
        let host = try XCTUnwrap(m.rootProject.scene(withId: scene.id))
        let inner = try XCTUnwrap(host.tracks[0].clips.first { $0.type == .scene })
        XCTAssertEqual(inner.sceneId, made.sceneId, "シーンクリップはホストのシーンの中へ")
        let newScene = try XCTUnwrap(m.rootProject.scene(withId: made.sceneId))
        XCTAssertEqual(newScene.tracks.flatMap { $0.clips }.map(\.id).sorted(), ["in1", "in2"])
        XCTAssertTrue(m.exitSceneScope())
        XCTAssertEqual(undoSteps(m), 1, "シーンの中での作成も 1 回の Undo")
    }

    // MARK: 専用表示

    func testDisplayLabelAndSummary() throws {
        let m = makeModel()
        m.selectedClipIDs = ["a", "b"]
        m.selectedClipId = "a"
        let made = try XCTUnwrap(m.createSceneFromSelection(name: "導入"))
        let root = m.rootProject
        let sceneClip = try XCTUnwrap(root.allClips.first { $0.id == made.clipId })
        XCTAssertEqual(SceneClipDisplay.label(for: sceneClip, in: root), "シーン「導入」")
        let summary = try XCTUnwrap(SceneClipDisplay.summary(for: sceneClip, in: root))
        XCTAssertTrue(summary.contains("クリップ 2"), summary)
        XCTAssertTrue(summary.contains("参照 1 箇所"), summary)
        // 参照切れは、そのことが分かるラベルになり、概要は出ない
        var dangling = Clip(); dangling.type = .scene; dangling.sceneId = "missing"
        XCTAssertEqual(SceneClipDisplay.label(for: dangling, in: root), "シーン（参照切れ）")
        XCTAssertNil(SceneClipDisplay.summary(for: dangling, in: root))
        // 通常クリップにはシーン表示を出さない
        XCTAssertEqual(SceneClipDisplay.label(for: clip("z", start: 0), in: root), "")
    }

    func testScenePaletteColorIsDistinct() {
        let scene = TimelinePalette.color(for: .scene)
        XCTAssertTrue(scene.isEqual(TimelinePalette.scene))
        for other in [ClipType.video, .image, .audio, .text, .blur, .compound, .tachie] {
            XCTAssertFalse(scene.isEqual(TimelinePalette.color(for: other)), "\(other.rawValue) と見分けられる色")
        }
    }
}
