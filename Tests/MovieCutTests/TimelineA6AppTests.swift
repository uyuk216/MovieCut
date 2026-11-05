import XCTest
import SwiftUI
import AppKit
import AVFoundation
import MovieCutCore
@testable import MovieCut

/// A6: タイムラインの操作(複数選択・コピー&ペースト・レイヤー・メニュー)。マウスはオフスクリーンの TimelineCanvas へ NSEvent を送って試す。
@MainActor
final class TimelineA6AppTests: XCTestCase {
    private var model: ProjectModel!
    private var canvas: TimelineCanvas!
    private var window: NSWindow!
    private var pasteboard: NSPasteboard!

    private func clip(_ id: String, _ type: ClipType = .image, start: Double, dur: Double) -> Clip {
        var c = Clip(); c.id = id; c.type = type; c.start = start; c.duration = dur
        return c
    }

    /// T0: a(1-3) b(4-6) c(8-9) / T1: d(2-4) e(5-7) / T2: f(1-2)
    override func setUp() async throws {
        var p = Project.new()
        p.tracks[0].clips = [clip("a", start: 1, dur: 2), clip("b", start: 4, dur: 2), clip("c", start: 8, dur: 1)]
        p.tracks[1].clips = [clip("d", .video, start: 2, dur: 2), clip("e", .audio, start: 5, dur: 2)]
        p.tracks[2].clips = [clip("f", .text, start: 1, dur: 1)]
        model = ProjectModel(project: p)
        model.snapEnabled = false
        model.pps = 40
        pasteboard = NSPasteboard(name: NSPasteboard.Name("jp.local.moviecut.test.\(UUID().uuidString)"))
        model.clipPasteboard = pasteboard
        canvas = TimelineCanvas(frame: NSRect(x: 0, y: 0, width: 1200, height: 320))
        window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = canvas
        canvas.model = model
        canvas.syncFromModel()
    }

    override func tearDown() async throws {
        pasteboard.releaseGlobally()
        model.shutdown()
        window = nil; canvas = nil; model = nil; pasteboard = nil
    }

    // MARK: 道具

    private func x(_ t: Double) -> CGFloat { canvas.geometry.x(forTime: t) }
    private func y(row: Int) -> CGFloat { canvas.geometry.rowTop(row) + canvas.geometry.rowHeight(row) / 2 }
    private func event(_ type: NSEvent.EventType, _ p: NSPoint, _ mods: NSEvent.ModifierFlags = [], clicks: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: canvas.convert(p, to: nil), modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }
    private func click(_ p: NSPoint, _ mods: NSEvent.ModifierFlags = [], clicks: Int = 1) {
        canvas.mouseDown(with: event(.leftMouseDown, p, mods, clicks: clicks))
        canvas.mouseUp(with: event(.leftMouseUp, p, mods, clicks: clicks))
    }
    private func drag(from a: NSPoint, to b: NSPoint, _ mods: NSEvent.ModifierFlags = [], steps: Int = 6) {
        canvas.mouseDown(with: event(.leftMouseDown, a, mods))
        for i in 1...steps {
            let f = CGFloat(i) / CGFloat(steps)
            canvas.mouseDragged(with: event(.leftMouseDragged, NSPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f), mods))
        }
        canvas.mouseUp(with: event(.leftMouseUp, b, mods))
    }
    private func find(_ id: String) -> Clip { model.project.allClips.first { $0.id == id }! }
    private func track(of id: String) -> Int { ClipEditing.locate(id, in: model.project)!.track }
    private var um: UndoManager { model.effectiveUndoManager }
    private func ids(_ s: Set<String>) -> [String] { s.sorted() }

    // MARK: 選択

    func testCommandClickTogglesAndShiftClickExtendsAlongLayer() {
        click(NSPoint(x: x(1.5), y: y(row: 0)))
        XCTAssertEqual(model.selectedClipId, "a"); XCTAssertEqual(model.selectedClipIDs, ["a"])
        click(NSPoint(x: x(5), y: y(row: 1)), .command)
        XCTAssertEqual(ids(model.selectedClipIDs), ["a", "e"]); XCTAssertEqual(model.selectedClipId, "e", "最後に足したものが主")
        click(NSPoint(x: x(1.5), y: y(row: 0)), .command)                       // トグルで外す
        XCTAssertEqual(ids(model.selectedClipIDs), ["e"])
        click(NSPoint(x: x(8.5), y: y(row: 0)))                                  // 修飾なし → 単一に戻る
        XCTAssertEqual(ids(model.selectedClipIDs), ["c"])
        click(NSPoint(x: x(1.5), y: y(row: 0)), .shift)                          // c から a まで同じレイヤーを範囲で足す
        XCTAssertEqual(ids(model.selectedClipIDs), ["a", "b", "c"])
        XCTAssertFalse(um.canUndo, "選択は Undo に積まない")
    }

    func testClickingEmptyClearsSelectionAndSeeksButModifierKeepsIt() {
        model.setSelection(ClipSelection(ids: ["a", "b"], primary: "a"))
        click(NSPoint(x: x(7.5), y: y(row: 2)), .command)                        // 修飾つき: 変えない
        XCTAssertEqual(ids(model.selectedClipIDs), ["a", "b"])
        click(NSPoint(x: x(7.5), y: y(row: 2)))
        XCTAssertTrue(model.selectedClipIDs.isEmpty); XCTAssertNil(model.selectedClipId)
        XCTAssertEqual(model.currentTime, 7.5, accuracy: 0.02)
        XCTAssertEqual(model.selectedLayerIndex, 2, "押した行が貼り付けの行き先になる")
    }

    func testRubberBandSelectsIntersectingClipsAndModifierAdds() {
        // 空き地(時刻 0.2, 行 2 の下)から、(時刻 5.5, 行 1)まで → 行 1〜2 の時刻 0.2〜5.5 にかかるもの: d, e, f と、行 0 は含まない
        let a = NSPoint(x: x(0.2), y: y(row: 2) + 12), b = NSPoint(x: x(5.5), y: y(row: 1) - 12)
        drag(from: a, to: b)
        XCTAssertEqual(ids(model.selectedClipIDs), ["d", "e", "f"])
        XCTAssertEqual(model.selectedClipId, "f", "主は開始の一番早いもの(f: 1 秒)")
        XCTAssertFalse(um.canUndo)
        XCTAssertNil(canvas.rubber)
        // ⌘ つきで別のところを囲むと足される
        drag(from: NSPoint(x: x(7.6), y: y(row: 0) - 14), to: NSPoint(x: x(9.5), y: y(row: 0) + 14), .command)
        XCTAssertTrue(model.selectedClipIDs.isSuperset(of: ["d", "e", "f", "c"]))
    }

    func testRubberBandDoesNotSeekOrChangeProject() {
        let before = model.project
        model.playback.seek(to: 3)
        drag(from: NSPoint(x: x(0.2), y: y(row: 2) + 12), to: NSPoint(x: x(2.5), y: y(row: 0)))
        XCTAssertEqual(model.currentTime, 3, accuracy: 1e-6, "ラバーバンドではシークしない")
        XCTAssertEqual(model.project, before)
    }

    func testSelectAllThroughResponderAndMenu() {
        canvas.selectAll(nil)
        XCTAssertEqual(model.selectedClipIDs.count, 6)
        XCTAssertNotNil(model.selectedClipId)
        XCTAssertFalse(model.selectAllClips(), "もう全選択なら何も変わらない")
        model.selectOnly(nil)
        AppMenu.perform(.selectAllClips, model: model)
        XCTAssertEqual(model.selectedClipIDs.count, 6)
    }

    func testPrimarySelectionStillDrivesInspectorAndSingleOps() {
        model.setSelection(ClipSelection(ids: ["a", "b", "c"], primary: "b"))
        XCTAssertEqual(model.selectedClip?.id, "b")
        XCTAssertEqual(model.inspectorMode, .multi(3))
        model.selectOnly("b")
        XCTAssertEqual(model.inspectorMode, .clip("b"))
        model.selectedClipId = "c"                     // 主を直接入れ替えれば単一選択
        XCTAssertEqual(model.selectedClipIDs, ["c"])
        model.selectedClipId = nil
        XCTAssertTrue(model.selectedClipIDs.isEmpty)
        XCTAssertEqual(model.inspectorMode, .none)
        // 項目を編集する単一クリップの操作は主だけ(分割)
        model.setSelection(ClipSelection(ids: ["a", "b"], primary: "a"))
        model.playback.seek(to: 2)
        XCTAssertTrue(model.splitSelected())
        XCTAssertEqual(model.project.allClips.count, 7)
    }

    // MARK: 複数のドラッグ・削除・複製

    func testMultiDragMovesAllKeepingOffsetsAsOneUndoStep() {
        model.setSelection(ClipSelection(ids: ["a", "e"], primary: "a"))
        let before = model.project
        // a(1-3)を押して +2 秒、1 行下へ(e は 1 行下の行 2 へ)
        drag(from: NSPoint(x: x(2), y: y(row: 0)), to: NSPoint(x: x(4), y: y(row: 1)))
        XCTAssertEqual(find("a").start, 3, accuracy: 0.05)
        XCTAssertEqual(find("e").start, 7, accuracy: 0.05)
        XCTAssertEqual(find("e").start - find("a").start, before.allClips.first { $0.id == "e" }!.start - 1, accuracy: 1e-6, "相対位置は保たれる")
        XCTAssertEqual(track(of: "a"), 1); XCTAssertEqual(track(of: "e"), 2)
        XCTAssertEqual(find("b").start, 4)
        XCTAssertEqual(ids(model.selectedClipIDs), ["a", "e"], "ドラッグしても選択は保たれる")
        XCTAssertEqual(um.undoActionName, "クリップの移動")
        um.undo()
        XCTAssertEqual(model.project, before, "1 回の Undo で全部戻る")
        XCTAssertFalse(um.canUndo)
        um.redo()
        XCTAssertEqual(find("a").start, 3, accuracy: 0.05)
    }

    func testPressWithoutDragOnMultiSelectionCollapsesToThatClipAndRegistersNothing() {
        model.setSelection(ClipSelection(ids: ["a", "b"], primary: "a"))
        let before = model.project
        click(NSPoint(x: x(5), y: y(row: 0)))        // b を動かさずに押して離す
        XCTAssertEqual(model.selectedClipIDs, ["b"])
        XCTAssertEqual(model.project, before)
        XCTAssertFalse(um.canUndo)
    }

    func testPressOnMultiSelectionKeepsItWhileDraggingStartsAndNoOpDragRegistersNothing() {
        model.setSelection(ClipSelection(ids: ["a", "b"], primary: "a"))
        let before = model.project
        drag(from: NSPoint(x: x(2), y: y(row: 0)), to: NSPoint(x: x(2) + 1, y: y(row: 0)))   // 3pt 未満
        XCTAssertEqual(model.project, before)
        XCTAssertFalse(um.canUndo)
        // 動かして元に戻す(ゼロ移動) → 何も登録しない
        canvas.debugDrag(clipId: "a", mode: .move, deltaT: 0)
        XCTAssertFalse(um.canUndo)
    }

    func testDeleteManyIsOneUndoStepAndKeyDeleteReachesIt() {
        model.setSelection(ClipSelection(ids: ["a", "d", "f"], primary: "a"))
        let before = model.project
        XCTAssertTrue(model.deleteSelected())
        XCTAssertEqual(model.project.allClips.count, 3)
        XCTAssertNil(model.selectedClipId); XCTAssertTrue(model.selectedClipIDs.isEmpty)
        XCTAssertEqual(um.undoActionName, "クリップの削除")
        um.undo()
        XCTAssertEqual(model.project, before)
        // Delete キー(KeyRouter の handler)も複数に効く
        model.installKeyboard()
        model.window = window
        model.setSelection(ClipSelection(ids: ["b", "c"], primary: "b"))
        XCTAssertNotNil(model.keyRouter.handlers[.delete])
        XCTAssertTrue(model.deleteSelected())
        XCTAssertEqual(model.project.allClips.count, 4)
    }

    func testRippleDeleteManyAndDuplicateMany() {
        model.setSelection(ClipSelection(ids: ["a", "b"], primary: "a"))
        XCTAssertTrue(model.rippleDeleteSelected())
        XCTAssertEqual(model.project.tracks[0].clips.map(\.id), ["c"])
        XCTAssertEqual(find("c").start, 4, accuracy: 1e-9, "a(2) b(2) を消した分 8 → 4")
        XCTAssertEqual(um.undoActionName, "すき間を詰めて削除")
        um.undo()
        model.setSelection(ClipSelection(ids: ["a", "d"], primary: "a"))
        XCTAssertTrue(model.duplicateSelected())
        XCTAssertEqual(model.project.allClips.count, 8)
        XCTAssertEqual(model.selectedClipIDs.count, 2, "複製の 2 つを選ぶ")
        XCTAssertFalse(model.selectedClipIDs.contains("a"))
        XCTAssertEqual(um.undoActionName, "クリップの複製")
        um.undo()
        XCTAssertEqual(model.project.allClips.count, 6)
    }

    // MARK: コピー・切り取り・貼り付け

    func testCopyPasteAtPlayheadKeepsRelativeOffsetsAsOneUndoStep() {
        model.setSelection(ClipSelection(ids: ["b", "e"], primary: "b"))       // b(4-6, 行 0), e(5-7, 行 1)
        XCTAssertTrue(model.copySelection())
        XCTAssertFalse(um.canUndo, "コピーは Undo に積まない")
        XCTAssertNotNil(pasteboard.data(forType: ProjectModel.clipPasteboardType))
        model.playback.seek(to: 20)
        let before = model.project
        XCTAssertTrue(model.pasteClips())
        XCTAssertEqual(model.project.allClips.count, 8)
        XCTAssertEqual(model.selectedClipIDs.count, 2)
        let nb = model.selectedClipIDs.map(find).sorted { $0.start < $1.start }
        XCTAssertEqual(nb[0].start, 20, accuracy: 1e-6); XCTAssertEqual(nb[1].start, 21, accuracy: 1e-6)   // 相対 +1 秒
        XCTAssertEqual(track(of: nb[0].id), 0); XCTAssertEqual(track(of: nb[1].id), 1, "元のレイヤー")
        XCTAssertEqual(um.undoActionName, "クリップの貼り付け")
        um.undo()
        XCTAssertEqual(model.project, before)
    }

    func testPasteOnSelectedLayerPutsTopOfGroupThere() {
        model.setSelection(ClipSelection(ids: ["b", "e"], primary: "b"))
        model.copySelection()
        model.playback.seek(to: 12)
        model.selectLayer(3)                           // 行 3 を選ぶ → b が行 3、e が行 4
        XCTAssertEqual(model.pasteTargetLayer, 3)
        XCTAssertTrue(model.pasteClips())
        let n = model.selectedClipIDs.map(find).sorted { $0.start < $1.start }
        XCTAssertEqual(track(of: n[0].id), 3); XCTAssertEqual(track(of: n[1].id), 4)
        XCTAssertEqual(model.project.tracks.count, 5)
    }

    func testCutIsCopyPlusDeleteInOneUndoStep() {
        model.setSelection(ClipSelection(ids: ["a", "f"], primary: "a"))
        let before = model.project
        XCTAssertTrue(model.cutSelection())
        XCTAssertEqual(model.project.allClips.count, 4)
        XCTAssertEqual(um.undoActionName, "クリップの切り取り")
        um.undo()
        XCTAssertEqual(model.project, before)
        model.selectOnly(nil)
        model.playback.seek(to: 10)
        XCTAssertTrue(model.pasteClips(), "切り取ったものを貼れる")
        XCTAssertEqual(model.project.allClips.count, 8)
    }

    func testPasteSurvivesAcrossDocumentsThroughThePasteboard() {
        model.setSelection(ClipSelection(ids: ["d"], primary: "d"))
        model.copySelection()
        let other = ProjectModel(project: .new())
        other.clipPasteboard = pasteboard
        XCTAssertNil(other.clipClipboard, "別のドキュメントはアプリ内のコピーを持たない")
        XCTAssertTrue(other.canPasteClips)
        other.playback.seek(to: 3)
        XCTAssertTrue(other.pasteClips())
        XCTAssertEqual(other.project.allClips.count, 1)
        XCTAssertEqual(other.project.allClips[0].type, .video)
        XCTAssertEqual(other.project.allClips[0].start, 3, accuracy: 1e-6)
        XCTAssertNotEqual(other.project.allClips[0].id, "d")
        other.shutdown()
    }

    func testNothingToPasteChangesNothing() {
        let empty = ProjectModel(project: .new())
        empty.clipPasteboard = NSPasteboard(name: NSPasteboard.Name("jp.local.moviecut.test.\(UUID().uuidString)"))
        XCTAssertFalse(empty.canPasteClips)
        XCTAssertFalse(empty.pasteClips())
        XCTAssertFalse(empty.effectiveUndoManager.canUndo)
        XCTAssertFalse(empty.copySelection())
        XCTAssertFalse(empty.cutSelection())
        empty.shutdown()
    }

    // MARK: 標準の編集コマンド(responder chain)と入力欄

    func testResponderChainCommandsReachTimelineWhenFocusedAndTextFieldsKeepTheirs() {
        // タイムラインが先頭: copy: / cut: / paste: / selectAll: を受ける
        window.makeFirstResponder(canvas)
        func firstResponder(responding sel: Selector) -> NSResponder? {
            var r = window.firstResponder
            while let cur = r { if cur.responds(to: sel) { return cur }; r = cur.nextResponder }
            return nil
        }
        for sel in [#selector(TimelineCanvas.copy(_:)), #selector(TimelineCanvas.cut(_:)), #selector(TimelineCanvas.paste(_:)), #selector(NSResponder.selectAll(_:))] {
            XCTAssertTrue(firstResponder(responding: sel) === canvas, "\(sel)")
        }
        // 入力欄にフォーカスがあるときは、入力欄(フィールドエディタ)が先に受ける = テキストのコピー・貼り付けが壊れない
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        canvas.addSubview(field)
        window.makeFirstResponder(field)
        XCTAssertTrue(KeyRouter.isTextInput(window.firstResponder))
        for sel in [#selector(TimelineCanvas.copy(_:)), #selector(TimelineCanvas.cut(_:)), #selector(TimelineCanvas.paste(_:)), #selector(NSResponder.selectAll(_:))] {
            XCTAssertTrue(firstResponder(responding: sel) is NSText, "\(sel) は入力欄が受ける")
        }
        field.removeFromSuperview()
    }

    func testValidationFollowsSelectionAndClipboard() {
        final class Item: NSObject, NSValidatedUserInterfaceItem {
            var action: Selector?; var tag = 0
            init(_ a: Selector) { action = a }
        }
        XCTAssertFalse(canvas.validateUserInterfaceItem(Item(#selector(TimelineCanvas.copy(_:)))))
        XCTAssertFalse(canvas.validateUserInterfaceItem(Item(#selector(TimelineCanvas.paste(_:)))))
        XCTAssertTrue(canvas.validateUserInterfaceItem(Item(#selector(NSResponder.selectAll(_:)))))
        model.selectOnly("a")
        XCTAssertTrue(canvas.validateUserInterfaceItem(Item(#selector(TimelineCanvas.copy(_:)))))
        XCTAssertTrue(canvas.validateUserInterfaceItem(Item(#selector(TimelineCanvas.cut(_:)))))
        canvas.copy(nil)
        XCTAssertTrue(canvas.validateUserInterfaceItem(Item(#selector(TimelineCanvas.paste(_:)))))
        canvas.paste(nil)
        XCTAssertEqual(model.project.allClips.count, 7)
        canvas.cut(nil)
        XCTAssertEqual(model.project.allClips.count, 6)
    }

    // MARK: レイヤー

    func testRenameLayerInPlaceIsOneUndoStepAndEmptyIsNoOp() {
        let hw = TimelineLayout.headerWidth
        click(NSPoint(x: hw / 2 - 10, y: canvas.geometry.rowTop(1) + 10), clicks: 2)          // 名前のダブルクリック
        XCTAssertEqual(canvas.renamingRow, 1)
        canvas.debugCommitRename("  セリフ  ")
        XCTAssertNil(canvas.renamingRow)
        XCTAssertEqual(model.project.tracks[1].name, "セリフ")
        XCTAssertEqual(um.undoActionName, "レイヤー名の変更")
        um.undo()
        XCTAssertEqual(model.project.tracks[1].name, "レイヤー2")
        // 空は何もしない
        canvas.beginRenameLayer(1)
        canvas.debugCommitRename("   ")
        XCTAssertFalse(um.canUndo)
        // Esc 相当(確定しない)
        canvas.beginRenameLayer(0)
        canvas.endRename(commit: false)
        XCTAssertFalse(um.canUndo)
    }

    func testLockedLayerRefusesEditsMovesDeletesAndSkipsPaste() {
        XCTAssertTrue(model.toggleLayerLock(0))
        XCTAssertEqual(um.undoActionName, "レイヤーのロック切り替え")
        let locked = model.project
        // ドラッグ移動できない
        drag(from: NSPoint(x: x(2), y: y(row: 0)), to: NSPoint(x: x(5), y: y(row: 0)))
        XCTAssertEqual(model.project, locked)
        XCTAssertNil(canvas.drag)
        XCTAssertEqual(model.selectedClipId, "a", "選ぶことはできる")
        // 削除・切り取り・すき間削除・分割・複数の中のロック分
        XCTAssertFalse(model.deleteSelected())
        XCTAssertEqual(model.statusText, ProjectModel.lockedNotice)
        XCTAssertFalse(model.rippleDeleteSelected())
        model.playback.seek(to: 2)
        XCTAssertFalse(model.splitSelected())
        XCTAssertEqual(model.project, locked)
        // 中身を直接直す(プロパティ欄の編集など)も断る
        XCTAssertFalse(model.edit("x") { $0.tracks[0].clips[0].start = 9 })
        XCTAssertEqual(model.project, locked)
        // 複数選択: ロックされていない分だけ消える
        model.setSelection(ClipSelection(ids: ["a", "d"], primary: "a"))
        XCTAssertTrue(model.deleteSelected())
        XCTAssertEqual(model.project.allClips.count, 5)
        XCTAssertNotNil(model.project.allClips.first { $0.id == "a" })
        XCTAssertEqual(model.selectedClipIDs, ["a"], "消せなかったロック分は選択に残る")
        // 貼り付けはロックされたレイヤーを飛ばす
        model.setSelection(ClipSelection(ids: ["b"], primary: "b"))
        model.copySelection()
        model.selectLayer(0)
        XCTAssertFalse(model.pasteClips(), "全部ロックされたレイヤー宛なら何もしない")
        XCTAssertEqual(model.project.allClips.count, 5)
        // ロックを外せば直せる
        XCTAssertTrue(model.toggleLayerLock(0))
        model.selectOnly("a")
        XCTAssertTrue(model.deleteSelected())
    }

    func testDragIntoLockedLayerIsRejectedByGestureGuard() {
        XCTAssertTrue(model.toggleLayerLock(1))
        let locked = model.project
        canvas.debugDrag(clipId: "a", mode: .move, deltaT: 1, targetTrack: 1)       // 行 1(ロック)へ移す
        XCTAssertEqual(model.project, locked, "ロックされたレイヤーへは動かせない")
        XCTAssertEqual(um.undoActionName, "レイヤーのロック切り替え")
    }

    func testSoloAndHeightAreOneUndoStepEachAndAffectGeometry() {
        XCTAssertTrue(model.toggleLayerSolo(2))
        XCTAssertTrue(model.project.tracks[2].isSolo)
        XCTAssertEqual(um.undoActionName, "レイヤーのソロ切り替え")
        let top1Before = canvas.geometry.rowTop(1)
        XCTAssertEqual(canvas.geometry.rowHeight(0), 40)
        XCTAssertTrue(model.setLayerHeight(0, .large))
        canvas.syncFromModel()
        XCTAssertEqual(canvas.geometry.rowHeight(0), 64)
        XCTAssertEqual(canvas.geometry.rowTop(1), top1Before + 24)
        XCTAssertEqual(canvas.geometry.clipRect(start: 0, duration: 1, track: 0).height, 58)
        XCTAssertEqual(canvas.geometry.rowIndex(forY: canvas.geometry.rowTop(1) + 5, rowCount: 5), 1)
        XCTAssertEqual(canvas.geometry.rowIndex(forY: canvas.geometry.rowTop(0) + 60, rowCount: 5), 0)
        XCTAssertFalse(model.setLayerHeight(0, .large), "同じ高さは no-op")
        XCTAssertTrue(model.setLayerHeight(0, .normal))
        canvas.syncFromModel()
        XCTAssertEqual(canvas.geometry.rowTop(1), top1Before)
        XCTAssertTrue(canvas.geometry.rowOffsets.isEmpty, "全部標準なら従来の計算")
        XCTAssertEqual(um.undoActionName, "レイヤーの高さ")
    }

    func testHeaderButtonsAndSelectionAndContextMenu() {
        let hw = TimelineLayout.headerWidth
        let top = canvas.geometry.rowTop(1)
        click(NSPoint(x: TimelineLayout.lockRect(rowTop: top).midX, y: TimelineLayout.lockRect(rowTop: top).midY))
        XCTAssertTrue(model.project.tracks[1].isLocked)
        click(NSPoint(x: TimelineLayout.soloRect(rowTop: top).midX, y: TimelineLayout.soloRect(rowTop: top).midY))
        XCTAssertTrue(model.project.tracks[1].isSolo)
        click(NSPoint(x: 20, y: top + 10))                    // 名前のあたり(1 回)= レイヤーを選ぶ
        XCTAssertEqual(model.selectedLayerIndex, 1)
        XCTAssertNil(model.selectedClipId)
        _ = hw
        let menu = canvas.layerContextMenu(row: 1)!
        XCTAssertEqual(menu.items.map(\.title).filter { !$0.isEmpty }, ["名前を変更…", "ロック", "ソロ", "レイヤーを削除…", "高さ: 小", "高さ: 標準", "高さ: 大"])
        XCTAssertEqual(menu.items.first { $0.title == "ロック" }?.state, .on)
        XCTAssertEqual(menu.items.first { $0.title == "高さ: 標準" }?.state, .on)
        let large = menu.items.first { $0.title == "高さ: 大" }!
        (large.target as? MenuAction)?.run()
        XCTAssertEqual(LayerHeight.of(model.project.tracks[1]), .large)
        XCTAssertNotNil(canvas.clipContextMenu())
    }

    func testClipSelectionClearsLayerSelectionAndTargetLayerFollows() {
        model.selectLayer(3)
        XCTAssertEqual(model.targetLayerIndex, 3)
        model.selectOnly("d")
        XCTAssertNil(model.selectedLayerIndex)
        XCTAssertEqual(model.targetLayerIndex, 1, "選んだクリップのレイヤー")
    }

    // MARK: メニュー(項目表)

    private func state() -> MenuState { MenuState(model: model) }

    func testMenuItemsHaveNoAcceleratorsAndFollowState() {
        var s = MenuState(); s.hasDocument = true
        for spec in AppMenuSpec.clipboardItems(s) + AppMenuSpec.layerItems(s) + AppMenuSpec.layerHeightItems(s) {
            XCTAssertNil(spec.shortcut, "\(spec.title)")
        }
        XCTAssertEqual(AppMenuSpec.clipboardItems(s).map(\.title), ["クリップをコピー", "クリップを切り取り", "クリップを貼り付け", "すべてのクリップを選択"])
        XCTAssertTrue(AppMenuSpec.clipboardItems(s).allSatisfy { !$0.enabled }, "何も無ければ全部無効")
        // 標準の ⌘C ⌘X ⌘V ⌘A とぶつからない(項目表の全体で重複なし)
        let all = AppMenuSpec.all(s).compactMap(\.shortcut)
        XCTAssertEqual(all.count, Set(all).count)
        model.selectOnly("a")
        let st = state()
        XCTAssertEqual(st.selectionCount, 1); XCTAssertTrue(st.hasLayerTarget); XCTAssertTrue(st.hasClips)
        XCTAssertTrue(AppMenuSpec.clipboardItems(st).first { $0.command == .copyClips }!.enabled)
        XCTAssertFalse(AppMenuSpec.clipboardItems(st).first { $0.command == .pasteClips }!.enabled)
        XCTAssertTrue(AppMenuSpec.layerItems(st).filter { $0.command != .layerTarget }.allSatisfy(\.enabled))
        XCTAssertEqual(AppMenuSpec.layerHeightItems(st).map(\.checked), [false, true, false])
        var locked = st; locked.isLocked = true
        XCTAssertTrue((AppMenuSpec.clipboardItems(locked) + AppMenuSpec.layerItems(locked)).allSatisfy { !$0.enabled }, "書き出し中は触れない")
    }

    func testMenuPerformReachesClipboardAndLayerFunctions() {
        model.setSelection(ClipSelection(ids: ["b", "c"], primary: "b"))
        AppMenu.perform(.copyClips, model: model)
        XCTAssertNotNil(model.clipClipboard)
        model.playback.seek(to: 30)
        AppMenu.perform(.pasteClips, model: model)
        XCTAssertEqual(model.project.allClips.count, 8)
        AppMenu.perform(.cutClips, model: model)
        XCTAssertEqual(model.project.allClips.count, 6)
        model.selectOnly("a")
        AppMenu.perform(.layerLock, model: model)
        XCTAssertTrue(model.project.tracks[0].isLocked)
        AppMenu.perform(.layerSolo, model: model)
        XCTAssertTrue(model.project.tracks[0].isSolo)
        AppMenu.perform(.layerHeight(.small), model: model)
        XCTAssertEqual(LayerHeight.of(model.project.tracks[0]), .small)
        // 状態が変われば項目表も変わる(チェック)
        let st = state()
        XCTAssertTrue(AppMenuSpec.layerItems(st).filter { $0.command != .layerTarget }.allSatisfy { $0.checked == true })
        XCTAssertEqual(AppMenuSpec.layerHeightItems(st).map(\.checked), [true, false, false])
    }

    func testMultiSelectionInspectorTitles() {
        XCTAssertEqual(MultiSelectionInspector.Title.selected(3), "3個のクリップを選択中")
        XCTAssertEqual(MultiSelectionInspector.Title.all, ["複製", "削除", "すき間を詰めて削除", "コピー"])
    }
}

// MARK: クリップ単位のロック
extension TimelineA6AppTests {
    func testClipLockMenuToggleUndoAndRefusals() {
        let original = model.project
        model.selectOnly("a")
        var s = MenuState(model: model)
        XCTAssertEqual(AppMenuSpec.clipLockItem(s).title, "クリップをロック")
        XCTAssertTrue(AppMenuSpec.clipLockItem(s).enabled)
        AppMenu.perform(.clipLock, model: model)
        XCTAssertEqual(model.project.allClips.first { $0.id == "a" }?.locked, true)
        s = MenuState(model: model)
        XCTAssertEqual(AppMenuSpec.clipLockItem(s).title, "クリップのロックを解除")
        let locked = model.project
        // 分割・削除・プロパティ編集は断る
        model.playback.seek(to: 2)
        XCTAssertFalse(model.splitSelected())
        XCTAssertFalse(model.deleteSelected())
        XCTAssertEqual(model.statusText, ProjectModel.lockedNotice)
        XCTAssertFalse(model.edit("x") { $0.tracks[0].clips[0].start = 9 })
        XCTAssertEqual(model.project, locked)
        // 選択はできる
        model.selectOnly("b"); model.selectOnly("a")
        XCTAssertEqual(model.selectedClipId, "a")
        // 解除は 1 回の Undo 単位、Undo で戻る
        AppMenu.perform(.clipLock, model: model)
        XCTAssertNil(model.project.allClips.first { $0.id == "a" }?.locked)
        XCTAssertEqual(um.undoActionName, "クリップのロック解除")
        um.undo()
        XCTAssertEqual(model.project, locked)
        um.undo()
        XCTAssertEqual(model.project, original, "ロックは 1 回の Undo で戻る")
    }

    func testClipLockDisabledWithoutSelectionHasReason() {
        model.setSelection(.empty)
        let s = MenuState(model: model)
        let spec = AppMenuSpec.clipLockItem(s)
        XCTAssertFalse(spec.enabled)
        XCTAssertEqual(AppMenuSpec.disabledReason(for: spec, state: s), "クリップを選んでください")
    }
}
