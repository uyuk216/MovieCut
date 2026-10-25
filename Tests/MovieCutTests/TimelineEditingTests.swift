import XCTest
import AppKit
import MovieCutCore
@testable import MovieCut

/// M4a: タイムラインの編集(マウス操作はオフスクリーンのウィンドウに入れた TimelineCanvas へ NSEvent を送って試す)。
@MainActor
final class TimelineEditingTests: XCTestCase {
    private var model: ProjectModel!
    private var canvas: TimelineCanvas!
    private var window: NSWindow!

    private func clip(_ id: String, _ type: ClipType, start: Double, dur: Double, offset: Double = 0, srcDur: Double? = nil) -> Clip {
        var c = Clip()
        c.id = id; c.type = type; c.start = start; c.duration = dur; c.offset = offset; c.srcDuration = srcDur
        return c
    }

    /// T0: a(2〜4 動画 offset 1 src 10), b(8〜10 画像) / T1: c(5〜6 音声) / T2,T3,T4: 空
    override func setUp() async throws {
        var p = Project.new()
        p.tracks[0].clips = [clip("a", .video, start: 2, dur: 2, offset: 1, srcDur: 10), clip("b", .image, start: 8, dur: 2)]
        p.tracks[1].clips = [clip("c", .audio, start: 5, dur: 1, srcDur: 3)]
        model = ProjectModel(project: p)
        model.snapEnabled = false
        model.pps = 40
        canvas = TimelineCanvas(frame: NSRect(x: 0, y: 0, width: 1000, height: 300))
        window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = canvas
        canvas.model = model
        canvas.syncFromModel()
    }

    override func tearDown() async throws {
        model.shutdown()
        window = nil; canvas = nil; model = nil
    }

    // MARK: 座標とイベント

    private func x(_ t: Double) -> CGFloat { canvas.geometry.x(forTime: t) }
    private func y(row: Int) -> CGFloat { canvas.geometry.rowTop(row) + 20 }
    private func event(_ type: NSEvent.EventType, _ p: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: canvas.convert(p, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    private func down(_ p: NSPoint) { canvas.mouseDown(with: event(.leftMouseDown, p)) }
    private func dragTo(_ p: NSPoint) { canvas.mouseDragged(with: event(.leftMouseDragged, p)) }
    private func up(_ p: NSPoint) { canvas.mouseUp(with: event(.leftMouseUp, p)) }
    /// 押す → 少しずつ動かす → 離す
    private func gesture(from a: NSPoint, to b: NSPoint, steps: Int = 6, release: Bool = true) {
        down(a)
        for i in 1...steps {
            let f = CGFloat(i) / CGFloat(steps)
            dragTo(NSPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f))
        }
        if release { up(b) }
    }
    private func find(_ id: String) -> Clip { model.project.allClips.first { $0.id == id }! }
    private var um: UndoManager { model.effectiveUndoManager }

    // MARK: クリック

    func testPressSelectsClipAndClickWithoutDragChangesNothing() {
        let original = model.project
        down(NSPoint(x: x(3), y: y(row: 0)))
        XCTAssertEqual(model.selectedClipId, "a")
        dragTo(NSPoint(x: x(3) + 2, y: y(row: 0)))     // 3pt 未満はクリック
        up(NSPoint(x: x(3) + 2, y: y(row: 0)))
        XCTAssertEqual(model.project, original)
        XCTAssertFalse(um.canUndo)
        XCTAssertNil(canvas.drag)
    }

    func testClickOnEmptyDeselectsAndSeeks() {
        model.selectedClipId = "a"
        down(NSPoint(x: x(6.5), y: y(row: 2)))
        up(NSPoint(x: x(6.5), y: y(row: 2)))
        XCTAssertNil(model.selectedClipId)
        XCTAssertEqual(model.currentTime, 6.5, accuracy: 0.01)
    }

    func testEdgeZonesChooseTrimModes() {
        let r = canvas.geometry.clipRect(start: 2, duration: 2, track: 0)
        down(NSPoint(x: r.minX + 4, y: r.midY)); XCTAssertEqual(canvas.drag?.mode, .trimLeft); up(NSPoint(x: r.minX + 4, y: r.midY))
        down(NSPoint(x: r.maxX - 4, y: r.midY)); XCTAssertEqual(canvas.drag?.mode, .trimRight); up(NSPoint(x: r.maxX - 4, y: r.midY))
        down(NSPoint(x: r.midX, y: r.midY)); XCTAssertEqual(canvas.drag?.mode, .move); up(NSPoint(x: r.midX, y: r.midY))
    }

    // MARK: ドラッグ移動

    func testDragMoveCommitsOneUndoStep() {
        let original = model.project
        gesture(from: NSPoint(x: x(3), y: y(row: 0)), to: NSPoint(x: x(3) + 80, y: y(row: 0)))    // +2 秒
        XCTAssertEqual(find("a").start, 4, accuracy: 0.05)
        XCTAssertEqual(find("a").duration, 2)
        XCTAssertEqual(find("a").offset, 1)
        XCTAssertTrue(um.canUndo)
        let moved = model.project
        um.undo()
        XCTAssertEqual(model.project, original, "1 回の Undo で完全に元に戻る")
        XCTAssertFalse(um.canUndo, "Undo の段は 1 つだけ")
        um.redo()
        XCTAssertEqual(model.project, moved)
    }

    func testNothingRegisteredWhileDraggingOnlyOnMouseUp() {
        let original = model.project
        gesture(from: NSPoint(x: x(3), y: y(row: 0)), to: NSPoint(x: x(3) + 80, y: y(row: 0)), release: false)
        XCTAssertNotEqual(model.project, original, "途中でもモデルに反映される(プレビューが追従)")
        XCTAssertFalse(um.canUndo, "ドラッグ中は Undo に積まない")
        XCTAssertNotNil(model.gestureBase)
        up(NSPoint(x: x(3) + 80, y: y(row: 0)))
        XCTAssertTrue(um.canUndo)
        XCTAssertNil(model.gestureBase)
    }

    func testDragThereAndBackRegistersNothing() {
        let original = model.project
        let a = NSPoint(x: x(3), y: y(row: 0))
        down(a)
        dragTo(NSPoint(x: a.x + 40, y: a.y))
        XCTAssertNotEqual(model.project, original)
        dragTo(a)
        up(a)
        XCTAssertEqual(model.project, original)
        XCTAssertFalse(um.canUndo, "何も変わっていなければ登録しない")
    }

    func testDragClampsStartAtZero() {
        gesture(from: NSPoint(x: x(3), y: y(row: 0)), to: NSPoint(x: x(3) - 400, y: y(row: 0)))
        XCTAssertEqual(find("a").start, 0)
    }

    func testCrossLayerMove() {
        let original = model.project
        gesture(from: NSPoint(x: x(3), y: y(row: 0)), to: NSPoint(x: x(3), y: y(row: 3)))
        XCTAssertEqual(model.project.tracks[0].clips.map(\.id), ["b"])
        XCTAssertEqual(model.project.tracks[3].clips.map(\.id), ["a"])
        XCTAssertEqual(find("a").start, 2, accuracy: 1e-9)
        um.undo()
        XCTAssertEqual(model.project, original)
    }

    func testCrossLayerKeepsLastRowWhenPointerLeavesRows() {
        let a = NSPoint(x: x(3), y: y(row: 0))
        down(a)
        dragTo(NSPoint(x: a.x, y: y(row: 1)))
        dragTo(NSPoint(x: a.x + 20, y: 5))            // ルーラーの上へ出ても、最後に指していた行のまま
        up(NSPoint(x: a.x + 20, y: 5))
        XCTAssertEqual(ClipEditing.locate("a", in: model.project)?.track, 1)
    }

    func testDragWithSnapping() {
        model.snapEnabled = true
        canvas.syncFromModel()
        // a(2〜4) の頭をつかんで +2.95 秒 → 頭 4.95 が c の頭 5 に吸着
        let start = NSPoint(x: x(3), y: y(row: 0))
        down(start)
        dragTo(NSPoint(x: start.x + 40 * 2.95, y: start.y))
        XCTAssertEqual(find("a").start, 5, accuracy: 1e-9)
        XCTAssertEqual(canvas.snapGuides, [5], "吸着の案内線が出る")
        up(NSPoint(x: start.x + 40 * 2.95, y: start.y))
        XCTAssertEqual(canvas.snapGuides, [], "離したら消える")
        XCTAssertEqual(find("a").start, 5, accuracy: 1e-9)
    }

    func testSnapDisabledDoesNotSnap() {
        model.snapEnabled = false
        gesture(from: NSPoint(x: x(3), y: y(row: 0)), to: NSPoint(x: x(3) + 40 * 2.95, y: y(row: 0)))
        XCTAssertNotEqual(find("a").start, 5)
        XCTAssertEqual(find("a").start, 4.95, accuracy: 0.03)
    }

    // MARK: トリム

    func testTrimRightDrag() {
        let r = canvas.geometry.clipRect(start: 8, duration: 2, track: 0)
        let original = model.project
        gesture(from: NSPoint(x: r.maxX - 3, y: r.midY), to: NSPoint(x: r.maxX - 3 + 40, y: r.midY))    // +1 秒
        XCTAssertEqual(find("b").duration, 3, accuracy: 0.03)
        XCTAssertEqual(find("b").start, 8)
        um.undo()
        XCTAssertEqual(model.project, original)
        XCTAssertFalse(um.canUndo)
    }

    func testTrimRightStopsAtSourceEnd() {
        // a は src 10 − offset 1 = 9 秒が上限
        let r = canvas.geometry.clipRect(start: 2, duration: 2, track: 0)
        gesture(from: NSPoint(x: r.maxX - 3, y: r.midY), to: NSPoint(x: r.maxX - 3 + 40 * 20, y: r.midY), steps: 3)
        XCTAssertEqual(find("a").duration, 9, accuracy: 1e-9)
    }

    func testTrimLeftDragMovesOffsetForVideo() {
        let r = canvas.geometry.clipRect(start: 2, duration: 2, track: 0)
        let original = model.project
        gesture(from: NSPoint(x: r.minX + 3, y: r.midY), to: NSPoint(x: r.minX + 3 + 20, y: r.midY))    // +0.5 秒
        let a = find("a")
        XCTAssertEqual(a.start, 2.5, accuracy: 0.03)
        XCTAssertEqual(a.start + a.duration, 4, accuracy: 1e-9)
        XCTAssertEqual(a.offset, 1 + (a.start - 2), accuracy: 1e-9)
        um.undo()
        XCTAssertEqual(model.project, original)
        um.redo()
        XCTAssertEqual(find("a").start, a.start, accuracy: 1e-9)
    }

    func testTrimLeftDragOnImageLeavesOffsetZero() {
        let r = canvas.geometry.clipRect(start: 8, duration: 2, track: 0)
        gesture(from: NSPoint(x: r.minX + 3, y: r.midY), to: NSPoint(x: r.minX + 3 + 40, y: r.midY))
        XCTAssertEqual(find("b").start, 9, accuracy: 0.03)
        XCTAssertEqual(find("b").offset, 0)
    }

    // MARK: 自動スクロール

    func testAutoScrollFlagAndStepWhileDragging() {
        model.project.tracks[0].clips[1].duration = 20     // 内容を長くして、スクロールできるようにする
        canvas.syncFromModel()
        let a = NSPoint(x: x(3), y: y(row: 0))
        down(a)
        dragTo(NSPoint(x: canvas.bounds.width - 10, y: a.y))        // 右端 30pt 以内
        XCTAssertEqual(canvas.autoScrollDirection, 1)
        let before = canvas.geometry.scrollX
        let startBefore = find("a").start
        canvas.autoScrollStep()
        XCTAssertGreaterThan(canvas.geometry.scrollX, before)
        XCTAssertGreaterThan(find("a").start, startBefore, "スクロールした分、クリップも追いかけて動く")
        dragTo(NSPoint(x: 400, y: a.y))
        XCTAssertEqual(canvas.autoScrollDirection, 0)
        up(NSPoint(x: 400, y: a.y))
        XCTAssertEqual(canvas.autoScrollDirection, 0)
    }

    func testAutoScrollLeftAndNoScrollWithoutDrag() {
        canvas.debugSetScroll(x: 100, y: 0)
        canvas.autoScrollStep()
        XCTAssertEqual(canvas.geometry.scrollX, 100, "ドラッグしていなければ動かない")
        let a = NSPoint(x: x(5.6), y: y(row: 1))
        down(a)
        dragTo(NSPoint(x: TimelineLayout.headerWidth + 10, y: a.y))
        XCTAssertEqual(canvas.autoScrollDirection, -1)
        canvas.autoScrollStep()
        XCTAssertLessThan(canvas.geometry.scrollX, 100)
        up(NSPoint(x: TimelineLayout.headerWidth + 10, y: a.y))
    }

    func testSelectingOffscreenRowScrollsItIntoView() {
        canvas.setFrameSize(NSSize(width: 1000, height: 160))
        canvas.syncFromModel()
        XCTAssertEqual(canvas.geometry.scrollY, 0)
        _ = model.addTextClip()                 // 一番上(5 番目)のレイヤー: 最初は画面の外
        canvas.syncFromModel()
        XCTAssertGreaterThan(canvas.geometry.scrollY, 0)
        XCTAssertLessThanOrEqual(canvas.geometry.rowTop(4) + TimelineLayout.rowHeight, canvas.bounds.height + 0.5)
    }

    // MARK: ドロップ位置

    func testDropTimeOnRowUsesPointerTime() {
        XCTAssertEqual(canvas.dropTime(at: NSPoint(x: x(7), y: y(row: 2)))!, 7, accuracy: 1e-9)
        XCTAssertNil(canvas.dropTime(at: NSPoint(x: 30, y: y(row: 2))), "ヘッダーの上は再生ヘッド")
        XCTAssertNil(canvas.dropTime(at: NSPoint(x: x(7), y: 5)), "ルーラーの上は再生ヘッド")
        XCTAssertNil(canvas.dropTime(at: NSPoint(x: x(7), y: 290)), "行の外は再生ヘッド")
    }

    // MARK: キー

    func testKeyMapAssignments() {
        XCTAssertEqual(KeyRouter.command(keyCode: 1, modifiers: [], firstResponder: nil), .split)
        XCTAssertEqual(KeyRouter.command(keyCode: 51, modifiers: [], firstResponder: nil), .delete)
        XCTAssertEqual(KeyRouter.command(keyCode: 117, modifiers: [], firstResponder: nil), .delete)
        XCTAssertEqual(KeyRouter.command(keyCode: 53, modifiers: [], firstResponder: nil), .deselect)
        XCTAssertNil(KeyRouter.command(keyCode: 1, modifiers: [.command], firstResponder: nil), "Cmd+S は保存なので奪わない")
        XCTAssertNil(KeyRouter.command(keyCode: 51, modifiers: [], firstResponder: NSTextView()), "入力欄では効かない")
        XCTAssertNil(KeyRouter.command(keyCode: 53, modifiers: [], firstResponder: NSTextField()))
    }

    // MARK: モデル: 分割 / 削除

    func testSplitSelectedAtPlayheadAndUndo() {
        let original = model.project
        model.selectedClipId = "a"
        model.currentTime = 3
        XCTAssertTrue(model.canSplit)
        XCTAssertTrue(model.splitSelected())
        let t0 = model.project.tracks[0].clips
        XCTAssertEqual(t0.count, 3)
        XCTAssertEqual(t0[0].id, "a"); XCTAssertEqual(t0[0].duration, 1, accuracy: 1e-9)
        XCTAssertEqual(t0[1].start, 3); XCTAssertEqual(t0[1].duration, 1, accuracy: 1e-9); XCTAssertEqual(t0[1].offset, 2, accuracy: 1e-9)
        XCTAssertEqual(model.selectedClipId, "a")
        um.undo()
        XCTAssertEqual(model.project, original)
        um.redo()
        XCTAssertEqual(model.project.tracks[0].clips.count, 3)
    }

    func testSplitDoesNothingAtEdgesOrWithoutSelection() {
        model.selectedClipId = "a"
        model.currentTime = 2
        XCTAssertFalse(model.canSplit); XCTAssertFalse(model.splitSelected())
        model.currentTime = 4
        XCTAssertFalse(model.splitSelected())
        model.selectedClipId = nil
        model.currentTime = 3
        XCTAssertFalse(model.canSplit); XCTAssertFalse(model.splitSelected())
        XCTAssertFalse(um.canUndo)
    }

    func testDeleteSelectedAndUndoKeepsSelectionValid() {
        let original = model.project
        model.selectedClipId = "a"
        XCTAssertTrue(model.deleteSelected())
        XCTAssertNil(model.project.allClips.first { $0.id == "a" })
        XCTAssertNil(model.selectedClipId)
        um.undo()
        XCTAssertEqual(model.project, original)
        XCTAssertFalse(model.deleteSelected(), "選択がなければ何もしない")
        um.redo()
        XCTAssertEqual(model.project.allClips.count, 2)
    }

    func testSelectionClearedWhenUndoRemovesTheClip() {
        let id = model.addTextClip()!
        XCTAssertEqual(model.selectedClipId, id)
        um.undo()
        XCTAssertNil(model.selectedClipId, "Undo でクリップが無くなったら選択も外れる")
        um.redo()
        XCTAssertNil(model.selectedClipId, "Redo では勝手に選択しない")
        model.selectedClipId = "a"
        model.edit("fps") { $0.fps = 30 }
        um.undo()
        XCTAssertEqual(model.selectedClipId, "a", "ほかの編集の Undo では選択を保つ")
    }

    // MARK: モデル: テキスト / ぼかし / 素材

    func testAddTextAndBlurGoToTopLayerAndSelect() {
        model.currentTime = 1.25
        let tid = model.addTextClip()!
        XCTAssertEqual(model.project.tracks.last!.clips.last!.id, tid)
        XCTAssertEqual(model.selectedClipId, tid)
        XCTAssertEqual(find(tid).start, 1.25); XCTAssertEqual(find(tid).fontSize, 96)
        let bid = model.addBlurClip()!
        XCTAssertEqual(model.project.tracks.last!.clips.map(\.id), [tid, bid])
        XCTAssertEqual(model.selectedClipId, bid)
        XCTAssertEqual(find(bid).strength, 24)
        um.undo()      // ぼかしだけが消える(1 操作 = 1 Undo)
        XCTAssertEqual(model.project.tracks.last!.clips.map(\.id), [tid])
        um.undo()
        XCTAssertTrue(model.project.tracks.last!.clips.isEmpty)
        um.redo(); um.redo()
        XCTAssertEqual(model.project.tracks.last!.clips.map(\.id), [tid, bid])
    }

    func testTextAndBlurAt4KAndPortrait() {
        model.applyVideoSize(3840, 2160)
        XCTAssertEqual(find(model.addTextClip()!).fontSize, 192)
        XCTAssertEqual(find(model.addBlurClip()!).strength, 48)
        model.applyVideoSize(720, 1280)
        XCTAssertEqual(find(model.addTextClip()!).fontSize, 64)
    }

    private func tempFile(_ name: String, _ data: Data = Data([0])) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("m4a-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let u = dir.appendingPathComponent(name)
        try data.write(to: u)
        return u
    }

    private func wav(seconds: Double) -> Data {
        let n = Int(8000 * seconds)
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append("RIFF".data(using: .ascii)!); u32(UInt32(36 + n * 2)); d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(1); u32(8000); u32(16000); u16(2); u16(16)
        d.append("data".data(using: .ascii)!); u32(UInt32(n * 2)); d.append(Data(count: n * 2))
        return d
    }

    func testAddMediaPlacesAtPlayheadOneUndoStepAndSelectsLast() async throws {
        let png = try tempFile("pic.PNG")
        let sound = try tempFile("voice.wav", wav(seconds: 2))
        let junk = try tempFile("notes.txt")
        let movie = try tempFile("movie.mp4")          // 読めない動画 → 5 秒
        model.currentTime = 6
        let before = model.project
        let ids = await model.addMedia(urls: [png, junk, sound, movie])
        XCTAssertEqual(ids.count, 3, "対応しない拡張子は無視")
        XCTAssertEqual(model.selectedClipId, ids.last)
        let clips = ids.map { find($0) }
        XCTAssertEqual(clips.map(\.type), [.image, .audio, .video])
        XCTAssertEqual(clips.map(\.start), [6, 6, 6])
        XCTAssertEqual(clips[0].duration, 5); XCTAssertNil(clips[0].srcDuration)
        XCTAssertEqual(clips[1].duration, 2, accuracy: 0.01); XCTAssertEqual(clips[1].srcDuration!, 2, accuracy: 0.01)
        XCTAssertEqual(clips[2].duration, 5)
        // 画像 [6,11) は T0 の b(8〜10) に重なる → T1(c は 6 で終わる)。音声 [6,8) は T0 に入る。動画 [6,11) は T0・T1 が埋まったので T2
        let tracks = ids.map { ClipEditing.locate($0, in: model.project)!.track }
        XCTAssertEqual(tracks, [1, 0, 2])
        um.undo()
        XCTAssertEqual(model.project, before, "全体で 1 回の Undo")
        XCTAssertFalse(um.canUndo)
        XCTAssertNil(model.selectedClipId)
        um.redo()
        XCTAssertEqual(model.project.allClips.count, before.allClips.count + 3)
    }

    func testAddMediaAtDropTimeAndUnsupportedOnlyDoesNothing() async throws {
        let png = try tempFile("a.jpg")
        let ids = await model.addMedia(urls: [png], at: 12.5)
        XCTAssertEqual(find(ids[0]).start, 12.5)
        let none = await model.addMedia(urls: [try tempFile("x.pdf")])
        XCTAssertTrue(none.isEmpty)
        XCTAssertEqual(model.project.allClips.count, 4)
    }

    func testLockedModelRefusesEdits() {
        model.busyMessage = "音声を作っています"
        model.selectedClipId = "a"
        model.currentTime = 3
        XCTAssertFalse(model.splitSelected())
        XCTAssertFalse(model.deleteSelected())
        XCTAssertNil(model.addTextClip())
        XCTAssertNil(model.addBlurClip())
        // ロック中はマウスで掴んでも動かない
        down(NSPoint(x: x(3), y: y(row: 0)))
        XCTAssertNil(canvas.drag)
        up(NSPoint(x: x(3), y: y(row: 0)))
    }

    // MARK: 検証用フックと同じ経路

    func testDebugDragPathMatchesMouse() {
        let original = model.project
        canvas.debugDrag(clipId: "a", mode: .move, deltaT: 2, targetTrack: nil)
        XCTAssertEqual(find("a").start, 4, accuracy: 1e-9)
        XCTAssertTrue(um.canUndo)
        um.undo()
        XCTAssertEqual(model.project, original)
        canvas.debugDrag(clipId: "a", mode: .move, deltaT: 1.3, hold: true)
        XCTAssertNotNil(canvas.drag)
        XCTAssertFalse(um.canUndo)
        canvas.mouseUp()
        XCTAssertTrue(um.canUndo)
    }
}
