import XCTest
import MovieCutCore
@testable import MovieCut

/// 素材ブラウザ(App 側)と、クリップの位置合わせメニュー(再生ヘッドに揃える・つなげて並べる)。
@MainActor
final class MediaBrowserAppTests: XCTestCase {
    private func clip(_ id: String, start: Double, duration: Double) -> Clip {
        var c = Clip()
        c.id = id; c.start = start; c.duration = duration
        return c
    }

    private func model(_ clips: [Clip]) -> ProjectModel {
        var p = Project.new()
        p.tracks = [Track(name: "レイヤー1")]
        p.tracks[0].clips = clips
        return ProjectModel(project: p)
    }

    // MARK: メニュー

    func testAlignmentItemsAreInClipMenuWithoutShortcuts() {
        var s = MenuState(); s.hasDocument = true
        let titles = AppMenuSpec.clipEdit(s).map(\.title)
        XCTAssertTrue(titles.contains("選択クリップを再生ヘッドに揃える"))
        XCTAssertTrue(titles.contains("選択クリップをつなげて並べる"))
        XCTAssertTrue(AppMenuSpec.clipEdit(s).filter { [.alignToPlayhead, .concatenateClips].contains($0.command) }.allSatisfy { $0.shortcut == nil })
    }

    func testAlignmentItemsEnablement() {
        var s = MenuState(); s.hasDocument = true
        func item(_ c: MenuCommand) -> MenuItemSpec? { AppMenuSpec.clipEdit(s).first { $0.command == c } }
        XCTAssertFalse(item(.alignToPlayhead)?.enabled ?? true, "選択が無いとき無効")
        s.hasSelection = true; s.selectionCount = 1
        XCTAssertTrue(item(.alignToPlayhead)?.enabled ?? false)
        XCTAssertFalse(item(.concatenateClips)?.enabled ?? true, "1 つだけなら並べられない(無効)")
        s.selectionCount = 2
        XCTAssertTrue(item(.concatenateClips)?.enabled ?? false)
        s.isLocked = true
        XCTAssertFalse(item(.alignToPlayhead)?.enabled ?? true, "ロック中は無効")
    }

    // MARK: 操作(1 回の Undo・変わらないときは登録しない)

    func testAlignSelectedToPlayheadIsOneUndoStep() {
        let m = model([clip("a", start: 2, duration: 1), clip("b", start: 5, duration: 1)])
        m.selectedClipIDs = ["a", "b"]; m.selectedClipId = "a"
        m.currentTime = 10
        let before = m.project
        XCTAssertTrue(m.alignSelectedToPlayhead())
        XCTAssertEqual(m.clip("a")?.start ?? -1, 10, accuracy: 1e-9)
        XCTAssertEqual(m.clip("b")?.start ?? -1, 13, accuracy: 1e-9)
        m.effectiveUndoManager.undo()
        XCTAssertEqual(m.project, before, "取り消しは 1 回で元に戻る")
    }

    func testAlignNoChangeRegistersNothing() {
        let m = model([clip("a", start: 4, duration: 1)])
        m.selectedClipId = "a"; m.selectedClipIDs = ["a"]
        m.currentTime = 4
        XCTAssertFalse(m.alignSelectedToPlayhead())
        XCTAssertFalse(m.effectiveUndoManager.canUndo, "変わらない位置合わせは履歴に載せない")
    }

    func testConcatenateSelectedIsOneUndoStep() {
        let m = model([clip("a", start: 3, duration: 2), clip("b", start: 9, duration: 1)])
        m.selectedClipIDs = ["a", "b"]; m.selectedClipId = "a"
        let before = m.project
        XCTAssertTrue(m.concatenateSelectedClips())
        XCTAssertEqual(m.clip("a")?.start ?? -1, 3, accuracy: 1e-9)
        XCTAssertEqual(m.clip("b")?.start ?? -1, 5, accuracy: 1e-9)
        m.effectiveUndoManager.undo()
        XCTAssertEqual(m.project, before)
    }

    func testMenuPerformRunsTheAlignment() {
        let m = model([clip("a", start: 1, duration: 1)])
        m.selectedClipId = "a"; m.selectedClipIDs = ["a"]
        m.currentTime = 7
        AppMenu.perform(.alignToPlayhead, model: m)
        XCTAssertEqual(m.clip("a")?.start ?? -1, 7, accuracy: 1e-9)
    }

    // MARK: 素材ブラウザの追加(再生ヘッド・1 回の Undo)

    func testBrowserAddPlacesAtPlayheadAndUndoesOnce() async throws {
        let m = ProjectModel(project: .new())
        m.currentTime = 6
        let before = m.project
        let url = URL(fileURLWithPath: "/nonexistent/still.png")
        let ids = await AudioLibrarySheet.addToTimeline(url: url, model: m)
        XCTAssertEqual(ids.count, 1)
        XCTAssertEqual(m.clip(ids[0])?.start ?? -1, 6, accuracy: 1e-9)
        m.effectiveUndoManager.undo()
        XCTAssertEqual(m.project, before)
    }

    /// ドロップ: 落とした時刻へ吸着し、落とした行のレイヤーに入る。1 回の Undo。
    func testDropPlacesOnDroppedLayerSnappedAndUndoesOnce() async throws {
        let m = ProjectModel(project: .new())
        m.project.tracks = [Track(name: "A"), Track(name: "B")]
        m.project.tracks[0].clips = [clip("edge", start: 0, duration: 4)]
        m.currentTime = 20
        m.snapEnabled = true
        let before = m.project
        let ids = await m.dropMedia(urls: [URL(fileURLWithPath: "/nonexistent/still.png")], dropTime: 4.03, rowIndex: 1)
        XCTAssertEqual(ids.count, 1)
        XCTAssertEqual(m.project.tracks[1].clips.map(\.id), ids, "落とした行(B)に入る")
        XCTAssertEqual(m.clip(ids[0])?.start ?? -1, 4, accuracy: 1e-9, "既存クリップの終わりへ吸着")
        assertNoLayerOverlaps(m.project)
        m.effectiveUndoManager.undo()
        XCTAssertEqual(m.project, before, "1 回の取り消しで戻る")
    }

    /// 重なるレイヤーに落としたら、空いている別のレイヤーへ回る(重ねない)。
    func testDropOntoOccupiedLayerFallsBackWithoutOverlap() async {
        let m = ProjectModel(project: .new())
        m.project.tracks = [Track(name: "A")]
        m.project.tracks[0].clips = [clip("x", start: 0, duration: 10)]
        m.snapEnabled = false
        let ids = await m.dropMedia(urls: [URL(fileURLWithPath: "/nonexistent/still.png")], dropTime: 2, rowIndex: 0)
        XCTAssertEqual(ids.count, 1)
        XCTAssertEqual(m.project.tracks[0].clips.map(\.id), ["x"])
        assertNoLayerOverlaps(m.project)
    }

    func testKindTextIsJapanese() {
        XCTAssertEqual(AudioLibrarySheet.kindText(.video), "動画")
        XCTAssertEqual(AudioLibrarySheet.kindText(.audio), "音声")
        XCTAssertEqual(AudioLibrarySheet.kindText(.image), "画像")
    }
}

/// 同梱素材: 素材ブラウザの「Movie Cut 同梱」から、他の素材と同じ経路で置ける。
@MainActor
final class BuiltInLibraryAppTests: XCTestCase {
    func testBuiltInItemPlacesLikeOtherMedia() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("builtin-app-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let items = BuiltInLibrary.items(in: DataLocations(edition: .personal, applicationSupport: tmp))
        let sound = try XCTUnwrap(items.first { $0.name == "効果音-ポップ.wav" })
        let bg = try XCTUnwrap(items.first { $0.name == "背景-夕焼け.png" })
        let m = ProjectModel(project: .new()); m.notices = OneTimeNotices()
        m.currentTime = 1
        let a = await AudioLibrarySheet.addToTimeline(url: sound.url, model: m)
        let b = await AudioLibrarySheet.addToTimeline(url: bg.url, model: m)
        XCTAssertEqual(a.count, 1); XCTAssertEqual(b.count, 1)
        let c = try XCTUnwrap(m.clip(a[0]))
        XCTAssertEqual(c.type, .audio)
        XCTAssertEqual(c.start, 1, accuracy: 1e-9)
        XCTAssertEqual(c.duration, 0.15, accuracy: 0.01)
        XCTAssertEqual(m.clip(b[0])?.type, .image)
        XCTAssertEqual(m.effectiveUndoManager.canUndo, true)
    }
}
