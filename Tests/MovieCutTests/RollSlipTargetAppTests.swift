import XCTest
import AppKit
import MovieCutCore
@testable import MovieCut

/// ロール編集・スリップ編集(メニュー+シート+⌥ ドラッグ)とトラックターゲットのアプリ側。
@MainActor
final class RollSlipTargetAppTests: XCTestCase {
    private var model: ProjectModel!
    private var canvas: TimelineCanvas!
    private var window: NSWindow!

    private func video(_ id: String, start: Double, dur: Double, offset: Double = 0) -> Clip {
        var c = Clip(); c.id = id; c.type = .video; c.src = "/nonexistent/\(id).mov"; c.start = start; c.duration = dur
        c.offset = offset; c.srcDuration = 20
        return c
    }

    /// T0: a(0-2, 素材 3-5) b(2-5, 素材 1-4) / T1 は空
    override func setUp() async throws {
        var p = Project.new()
        p.fps = 30
        p.tracks[0].clips = [video("a", start: 0, dur: 2, offset: 3), video("b", start: 2, dur: 3, offset: 1)]
        model = ProjectModel(project: p)
        model.snapEnabled = false
        model.pps = 40
        canvas = TimelineCanvas(frame: NSRect(x: 0, y: 0, width: 1200, height: 320))
        window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = canvas
        canvas.model = model
        canvas.syncFromModel()
    }

    override func tearDown() async throws {
        model.shutdown()
        window = nil; canvas = nil; model = nil
    }

    private var um: UndoManager { model.effectiveUndoManager }
    private func find(_ id: String) -> Clip { model.project.allClips.first { $0.id == id }! }
    private func x(_ t: Double) -> CGFloat { canvas.geometry.x(forTime: t) }
    private func y(row: Int) -> CGFloat { canvas.geometry.rowTop(row) + canvas.geometry.rowHeight(row) / 2 }
    private func state() -> MenuState { MenuState(model: model) }
    private func spec(_ c: MenuCommand) -> MenuItemSpec { AppMenuSpec.all(state()).first { $0.command == c }! }

    // MARK: モデル

    func testRollSelectedIsOneUndoStep() throws {
        model.selectedClipId = "a"
        let before = try model.project.encoded()
        XCTAssertTrue(model.rollSelected(frames: 15))
        XCTAssertEqual(find("a").duration, 2.5, accuracy: 1e-9)
        XCTAssertEqual(find("b").start, 2.5, accuracy: 1e-9)
        XCTAssertEqual(um.undoActionName, "ロール編集")
        um.undo()
        XCTAssertEqual(try model.project.encoded(), before)
        XCTAssertFalse(um.canUndo, "1 回で元に戻る")
        um.redo()
        XCTAssertEqual(find("a").duration, 2.5, accuracy: 1e-9)
    }

    func testRollFromRightClipUsesItsHeadBoundary() {
        model.selectedClipId = "b"
        XCTAssertTrue(model.rollSelected(frames: -30))
        XCTAssertEqual(find("a").duration, 1, accuracy: 1e-9)
        XCTAssertEqual(find("b").start, 1, accuracy: 1e-9)
    }

    func testNoOpAndLockedRegisterNothing() {
        model.selectedClipId = "a"
        XCTAssertFalse(model.rollSelected(frames: 0))
        XCTAssertFalse(model.slipSelected(frames: 0))
        XCTAssertFalse(um.canUndo)
        // 素材の頭で止まっている側へはこれ以上動かない(変化なし = 履歴に載せない)
        model.project.tracks[0].clips[1].offset = 0
        model.selectedClipId = "b"
        XCTAssertFalse(model.rollSelected(frames: -5))
        XCTAssertFalse(model.slipSelected(frames: -5))
        XCTAssertFalse(um.canUndo)
    }

    func testLockedClipsRefused() {
        model.edit("lock") { $0.tracks[0].clips[1].locked = true }
        model.selectedClipId = "a"
        let before = model.project
        XCTAssertFalse(model.canRoll)
        XCTAssertFalse(model.rollSelected(frames: 5))
        XCTAssertEqual(model.project, before)
        model.selectedClipId = "b"
        XCTAssertFalse(model.slipSelected(frames: 5))
        XCTAssertEqual(model.project, before)
    }

    func testSlipSelectedKeepsPositionAndUndoes() throws {
        model.selectedClipId = "b"
        let before = try model.project.encoded()
        XCTAssertTrue(model.slipSelected(frames: 30))
        XCTAssertEqual(find("b").offset, 2, accuracy: 1e-9)
        XCTAssertEqual(find("b").start, 2); XCTAssertEqual(find("b").duration, 3)
        XCTAssertEqual(um.undoActionName, "スリップ編集")
        um.undo()
        XCTAssertEqual(try model.project.encoded(), before)
    }

    func testMultiSelectionDisablesBoth() {
        model.setSelection(ClipSelection(ids: ["a", "b"], primary: "a"))
        XCTAssertFalse(model.canRoll); XCTAssertFalse(model.canSlip)
        XCTAssertFalse(model.rollSelected(frames: 3))
    }

    // MARK: メニュー

    func testMenuItemsEnabledAndSheetsOpen() {
        model.selectedClipId = nil
        XCTAssertFalse(spec(.rollEdit).enabled); XCTAssertFalse(spec(.slipEdit).enabled)
        XCTAssertNotNil(AppMenuSpec.disabledReason(for: spec(.rollEdit), state: state()))
        XCTAssertNotEqual(AppMenuSpec.disabledReason(for: spec(.rollEdit), state: state()), "今の状態では使えません")
        XCTAssertNotEqual(AppMenuSpec.disabledReason(for: spec(.slipEdit), state: state()), "今の状態では使えません")
        model.selectedClipId = "a"
        XCTAssertTrue(spec(.rollEdit).enabled); XCTAssertTrue(spec(.slipEdit).enabled)
        XCTAssertEqual(spec(.rollEdit).title, "ロール編集…")
        XCTAssertEqual(spec(.slipEdit).title, "スリップ編集…")
        XCTAssertNil(spec(.rollEdit).shortcut); XCTAssertNil(AppMenuSpec.disabledReason(for: spec(.rollEdit), state: state()))
        AppMenu.perform(.rollEdit, model: model)
        XCTAssertTrue(model.showRollSheet)
        AppMenu.perform(.slipEdit, model: model)
        XCTAssertTrue(model.showSlipSheet)
        XCTAssertFalse(um.canUndo, "シートを開くだけでは履歴に載せない")
    }

    func testSlipDisabledForImagesRollDisabledWithoutNeighbor() {
        var p = model.project
        var img = Clip(); img.id = "i"; img.type = .image; img.start = 10; img.duration = 2
        p.tracks[1].clips = [img]
        model.edit("x") { $0 = p }
        model.selectedClipId = "i"
        XCTAssertFalse(spec(.slipEdit).enabled)
        XCTAssertFalse(spec(.rollEdit).enabled)
    }

    // MARK: タイムラインの ⌥ ドラッグ

    private func event(_ type: NSEvent.EventType, _ p: NSPoint, _ mods: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: canvas.convert(p, to: nil), modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    private func drag(from a: NSPoint, to b: NSPoint, _ mods: NSEvent.ModifierFlags) {
        canvas.mouseDown(with: event(.leftMouseDown, a, mods))
        for i in 1...6 {
            let f = CGFloat(i) / 6
            canvas.mouseDragged(with: event(.leftMouseDragged, NSPoint(x: a.x + (b.x - a.x) * f, y: a.y), mods))
        }
        canvas.mouseUp(with: event(.leftMouseUp, b, mods))
    }

    func testOptionDragOnBoundaryRolls() {
        // a の右端(境界の少し左)を ⌥ で掴んで 20pt(0.5 秒)右へ
        drag(from: NSPoint(x: x(2) - 2, y: y(row: 0)), to: NSPoint(x: x(2) - 2 + 20, y: y(row: 0)), .option)
        XCTAssertEqual(find("a").duration, 2.5, accuracy: 0.02)
        XCTAssertEqual(find("b").start, find("a").start + find("a").duration, accuracy: 1e-9)
        XCTAssertEqual(find("b").start + find("b").duration, 5, accuracy: 1e-9)
        XCTAssertEqual(um.undoActionName, "ロール編集")
        um.undo()
        XCTAssertEqual(find("a").duration, 2)
        XCTAssertEqual(find("b").start, 2)
        XCTAssertFalse(um.canUndo, "ドラッグ全体で 1 回")
    }

    func testOptionDragFromRightClipHeadAlsoRolls() {
        drag(from: NSPoint(x: x(2) + 2, y: y(row: 0)), to: NSPoint(x: x(2) + 2 - 20, y: y(row: 0)), .option)
        XCTAssertEqual(find("a").duration, 1.5, accuracy: 0.02)
        XCTAssertEqual(find("b").offset, 0.5, accuracy: 0.02)
    }

    func testOptionShiftDragOnBodySlips() {
        // b の真ん中を ⌥⇧ で 40pt(1 秒)右へ = 素材の区間は 1 秒前へ(offset 1 → 0 で止まる)
        drag(from: NSPoint(x: x(3.5), y: y(row: 0)), to: NSPoint(x: x(3.5) + 40, y: y(row: 0)), [.option, .shift])
        XCTAssertEqual(find("b").offset, 0, accuracy: 1e-9)
        XCTAssertEqual(find("b").start, 2); XCTAssertEqual(find("b").duration, 3)
        XCTAssertEqual(um.undoActionName, "スリップ編集")
        // 左へ 20pt(0.5 秒)= 区間は 0.5 秒後ろへ
        drag(from: NSPoint(x: x(3.5), y: y(row: 0)), to: NSPoint(x: x(3.5) - 20, y: y(row: 0)), [.option, .shift])
        XCTAssertEqual(find("b").offset, 0.5, accuracy: 0.02)
    }

    func testOptionDragOnLockedDoesNothingAndPlainDragStillTrims() {
        model.edit("lock") { $0.tracks[0].locked = true }
        let before = model.project
        drag(from: NSPoint(x: x(2) - 2, y: y(row: 0)), to: NSPoint(x: x(2) + 18, y: y(row: 0)), .option)
        XCTAssertEqual(model.project, before)
    }

    func testOptionDragWithoutNeighborFallsBackToTrim() {
        // b の右端(隣がない)の ⌥ ドラッグは、いつもの右端トリム
        drag(from: NSPoint(x: x(5) - 2, y: y(row: 0)), to: NSPoint(x: x(5) - 2 - 20, y: y(row: 0)), .option)
        XCTAssertEqual(find("b").duration, 2.5, accuracy: 0.02)
        XCTAssertEqual(find("a").duration, 2)
    }

    // MARK: トラックターゲット

    func testTargetButtonTogglesAndOnlyOne() {
        let top0 = canvas.geometry.rowTop(0), top2 = canvas.geometry.rowTop(2)
        func click(_ r: CGRect) {
            let p = NSPoint(x: r.midX, y: r.midY)
            canvas.mouseDown(with: event(.leftMouseDown, p)); canvas.mouseUp(with: event(.leftMouseUp, p))
        }
        click(TimelineLayout.targetRect(rowTop: top2))
        XCTAssertEqual(TrackTarget.index(in: model.project), 2)
        XCTAssertEqual(um.undoActionName, "トラックターゲットの切り替え")
        click(TimelineLayout.targetRect(rowTop: top0))
        XCTAssertEqual(TrackTarget.index(in: model.project), 0, "1 つだけ")
        click(TimelineLayout.targetRect(rowTop: top0))
        XCTAssertNil(model.project.targetTrackId)
        XCTAssertFalse(String(decoding: (try? model.project.encoded()) ?? Data(), as: UTF8.self).contains("targetTrackId"))
        XCTAssertFalse(TimelineLayout.targetRect(rowTop: 0).intersects(TimelineLayout.lockRect(rowTop: 0)))
    }

    func testTargetMenuItemToggles() {
        model.selectLayer(2)
        XCTAssertEqual(spec(.layerTarget).checked, false)
        AppMenu.perform(.layerTarget, model: model)
        XCTAssertEqual(TrackTarget.index(in: model.project), 2)
        XCTAssertEqual(spec(.layerTarget).checked, true)
        um.undo()
        XCTAssertNil(model.project.targetTrackId)
    }

    func testTextAddAndAddMediaGoToTarget() async {
        model.edit("t") { $0 = TrackTarget.set(in: $0, index: 3, on: true)! }
        model.currentTime = 20
        let tid = model.addTextClip()!
        XCTAssertEqual(ClipEditing.locate(tid, in: model.project)?.track, 3)
        let ids = await model.addMedia(urls: [URL(fileURLWithPath: "/nonexistent/new.png")], at: 30)
        XCTAssertEqual(ids.count, 1)
        XCTAssertEqual(ClipEditing.locate(ids[0], in: model.project)?.track, 3)
    }

    func testNoTargetKeepsExistingBehavior() async {
        model.currentTime = 20
        let tid = model.addTextClip()!
        XCTAssertEqual(ClipEditing.locate(tid, in: model.project)?.track, model.project.tracks.count - 1)
    }

    func testSubtitleSheetUsesTarget() {
        model.edit("t") { $0 = TrackTarget.set(in: $0, index: 1, on: true)! }
        model.currentTime = 12
        model.openSubtitleSheet()
        XCTAssertTrue(model.commitSubtitleSheet(text: "字幕です", duration: 2))
        let id = model.selectedClipId!
        XCTAssertEqual(ClipEditing.locate(id, in: model.project)?.track, 1)
    }

    func testLockedTargetFallsBack() async {
        model.edit("t") { p in
            p = TrackTarget.set(in: p, index: 3, on: true)!
            p.tracks[3].locked = true
        }
        model.currentTime = 20
        let tid = model.addTextClip()!
        XCTAssertNotEqual(ClipEditing.locate(tid, in: model.project)?.track, 3)
    }
}
