import XCTest
import AppKit
import MovieCutCore
@testable import MovieCut

/// マルチカムクリップのアプリ側: 作成・切り替え・音声アングルが 1 回ずつの Undo、メニュー項目の対象、数字キーの経路。
@MainActor
final class MulticamClipAppTests: XCTestCase {
    private func cam(_ id: String, _ file: String) -> Clip {
        var c = Clip(); c.id = id; c.type = .video; c.src = file; c.start = 0; c.duration = 6; c.srcDuration = 20
        return c
    }

    private func makeModel() -> ProjectModel {
        var p = Project.new()
        p.tracks[0].clips = [cam("cam1", "/x/c1.mov")]
        p.tracks[1].clips = [cam("cam2", "/x/c2.mov")]
        p.tracks[2].clips = [cam("cam3", "/x/c3.mov")]
        let m = ProjectModel(project: p)
        m.notices = OneTimeNotices()
        return m
    }

    private func placed() -> (ProjectModel, String) {
        let m = makeModel()
        XCTAssertTrue(m.createMulticamClip(ids: ["cam1", "cam2", "cam3"], localLags: ["cam2": 0.5, "cam3": 1.5]))
        return (m, m.selectedClipId!)
    }

    private func spec(_ m: ProjectModel, _ c: MenuCommand) -> MenuItemSpec { AppMenuSpec.all(MenuState(model: m)).first { $0.command == c }! }

    func testCreateIsOneUndoAndRestoresTheOriginalClips() throws {
        let m = makeModel(); defer { m.shutdown() }
        let base = try m.project.encoded()
        let um = m.effectiveUndoManager
        XCTAssertTrue(m.createMulticamClip(ids: ["cam1", "cam2", "cam3"], localLags: ["cam2": 0.5, "cam3": 1.5]))
        XCTAssertEqual(um.undoActionName, "マルチカムクリップを作る")
        XCTAssertEqual(m.project.allClips.count, 1)
        XCTAssertEqual(m.project.multicams.count, 0, "グループ方式のものは作らない")
        um.undo()
        XCTAssertEqual(try m.project.encoded(), base)
    }

    func testMenuCutSplitsAtPlayheadAndKeysOnlyFireForMulticamClip() throws {
        let (m, id) = placed(); defer { m.shutdown() }
        let um = m.effectiveUndoManager
        m.currentTime = 2
        XCTAssertTrue(spec(m, .multicamCut(2)).enabled); XCTAssertFalse(spec(m, .multicamCut(3)).enabled)
        AppMenu.perform(.multicamCut(1), model: m)
        XCTAssertEqual(um.undoActionName, "アングル2に切り替え")
        let clips = m.project.tracks.flatMap(\.clips).sorted { $0.start < $1.start }
        XCTAssertEqual(clips.count, 2)
        XCTAssertEqual(clips.map { $0.multicam?.activeAngle }, [0, 1])
        XCTAssertEqual(clips[1].start, 2, accuracy: 1e-9)
        XCTAssertEqual(clips[0].id, id)
        // もう 1 回切り替えて、Undo は 1 つずつ
        m.currentTime = 4
        AppMenu.perform(.multicamCut(2), model: m)
        XCTAssertEqual(m.project.allClips.count, 3)
        um.undo(); XCTAssertEqual(m.project.allClips.count, 2)
        um.undo(); XCTAssertEqual(m.project.allClips.count, 1)
    }

    func testInspectorStyleWholeClipSwitchAndAudioAngle() throws {
        let (m, id) = placed(); defer { m.shutdown() }
        let um = m.effectiveUndoManager
        XCTAssertTrue(m.multicamClipCut(angle: 2, atPlayhead: false))
        XCTAssertEqual(m.project.allClips.count, 1, "分割しない")
        XCTAssertEqual(m.project.allClips.first?.multicam?.activeAngle, 2)
        XCTAssertEqual(m.project.allClips.first?.src, "/x/c3.mov")
        XCTAssertEqual(m.project.allClips.first?.offset ?? -1, 1.5, accuracy: 1e-9)
        XCTAssertFalse(m.multicamClipCut(angle: 2, atPlayhead: false), "同じなら何も登録しない")
        XCTAssertTrue(m.setMulticamAudioAngle(1))
        XCTAssertEqual(um.undoActionName, "音声アングルを変更")
        XCTAssertEqual(m.project.allClips.first?.multicam?.audioAngle, 1)
        XCTAssertEqual(m.project.allClips.first?.src, "/x/c3.mov", "映像は変わらない")
        XCTAssertEqual(CompoundEditing.audibleClips(in: m.project).first?.src, "/x/c2.mov")
        _ = id
    }

    func testAngleKeysRouteOnlyWhenNothingElseUsesThem() {
        let router = KeyRouter()
        var fired: [Int] = []
        router.angleKeyHandler = { fired.append($0); return true }
        // 上の段の 1〜9(US/JIS 共通のキーコード)
        for (code, idx) in KeyRouter.angleKeyCodes {
            XCTAssertTrue(router.dispatch(keyCode: code, modifiers: [], firstResponder: nil))
            XCTAssertEqual(fired.last, idx)
        }
        XCTAssertEqual(Set(fired), Set(0..<9))
        let n = fired.count
        XCTAssertFalse(router.dispatch(keyCode: 18, modifiers: [.command], firstResponder: nil), "⌘+数字は奪わない")
        XCTAssertFalse(router.dispatch(keyCode: 18, modifiers: [.shift], firstResponder: nil))
        XCTAssertFalse(router.dispatch(keyCode: 18, modifiers: [], firstResponder: NSTextView()), "入力中は奪わない")
        XCTAssertEqual(fired.count, n)
        // ハンドラが false を返せば素通り
        router.angleKeyHandler = { _ in false }
        XCTAssertFalse(router.dispatch(keyCode: 18, modifiers: [], firstResponder: nil))
    }

    func testPlainKeyStillUnclaimedWithoutMulticamClip() {
        let m = makeModel(); defer { m.shutdown() }
        XCTAssertNil(m.multicamClipTarget)
        XCTAssertEqual(m.multicamCutAngleCount, 0)
        XCTAssertFalse(m.multicamClipCut(angle: 0, atPlayhead: true))
    }
}
