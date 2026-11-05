import XCTest
import AppKit
import MovieCutCore
@testable import MovieCut

/// リップルトリム(クリップ ▸ リップルトリム(頭 / 尻)を再生位置へ、⌘ ドラッグ)のアプリ側。
@MainActor
final class RippleTrimAppTests: XCTestCase {
    private var model: ProjectModel!
    private var canvas: TimelineCanvas!
    private var window: NSWindow!

    private func video(_ id: String, start: Double, dur: Double, offset: Double = 0) -> Clip {
        var c = Clip(); c.id = id; c.type = .video; c.src = "/nonexistent/\(id).mov"; c.start = start; c.duration = dur
        c.offset = offset; c.srcDuration = 30
        return c
    }

    /// T0: a(0-4) b(4-6) c(8-9) / T1: d(5-7)
    override func setUp() async throws {
        var p = Project.new()
        p.fps = 30
        p.tracks[0].clips = [video("a", start: 0, dur: 4, offset: 2), video("b", start: 4, dur: 2), video("c", start: 8, dur: 1)]
        p.tracks[1].clips = [video("d", start: 5, dur: 2)]
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

    // MARK: メニュー

    func testMenuItemsAreInTheSpecTableWithoutShortcutsAndWithReasons() {
        for c in [MenuCommand.rippleTrimHead, .rippleTrimTail, .rippleAllLayersToggle] {
            XCTAssertNil(spec(c).shortcut, "\(c)")
        }
        XCTAssertEqual(spec(.rippleTrimHead).title, "リップルトリム(頭)を再生位置へ")
        XCTAssertEqual(spec(.rippleTrimTail).title, "リップルトリム(尻)を再生位置へ")
        XCTAssertTrue(AppMenuSpec.clipMenu(state()).flatMap { $0 }.contains { $0.command == .rippleTrimTail })
        // 選択なし: 無効で、理由は専用の文
        XCTAssertFalse(spec(.rippleTrimHead).enabled); XCTAssertFalse(spec(.rippleTrimTail).enabled)
        let r = AppMenuSpec.disabledReason(for: spec(.rippleTrimTail), state: state())
        XCTAssertNotNil(r); XCTAssertNotEqual(r, "今の状態では使えません")
        // 再生位置がクリップの途中
        model.selectedClipId = "a"; model.currentTime = 1
        XCTAssertTrue(spec(.rippleTrimHead).enabled); XCTAssertTrue(spec(.rippleTrimTail).enabled)
        XCTAssertNil(AppMenuSpec.disabledReason(for: spec(.rippleTrimTail), state: state()))
        // クリップの外
        model.currentTime = 4.5
        XCTAssertFalse(spec(.rippleTrimTail).enabled)
    }

    func testPerformTrimsTailAndShiftsLaterClipsOnSameLayer() throws {
        model.selectedClipId = "a"; model.currentTime = 3
        let before = try model.project.encoded()
        AppMenu.perform(.rippleTrimTail, model: model)
        XCTAssertEqual(find("a").duration, 3, accuracy: 1e-9)
        XCTAssertEqual(find("b").start, 3, accuracy: 1e-9)
        XCTAssertEqual(find("c").start, 7, accuracy: 1e-9)
        XCTAssertEqual(find("d").start, 5, "別のレイヤーはそのまま")
        XCTAssertEqual(um.undoActionName, "リップルトリム")
        um.undo()
        XCTAssertEqual(try model.project.encoded(), before)
        XCTAssertFalse(um.canUndo, "1 回で元に戻る")
        um.redo()
        XCTAssertEqual(find("b").start, 3, accuracy: 1e-9)
    }

    func testHeadToPlayheadAndAllLayersSetting() {
        model.selectedClipId = "a"; model.currentTime = 1
        AppMenu.perform(.rippleAllLayersToggle, model: model)
        XCTAssertTrue(model.rippleTrimAllLayers)
        XCTAssertEqual(spec(.rippleAllLayersToggle).checked, true)
        XCTAssertFalse(um.canUndo, "設定の切り替えは履歴に載せない")
        AppMenu.perform(.rippleTrimHead, model: model)
        XCTAssertEqual(find("a").start, 0, accuracy: 1e-9)
        XCTAssertEqual(find("a").duration, 3, accuracy: 1e-9)
        XCTAssertEqual(find("a").offset, 3, accuracy: 1e-9)
        XCTAssertEqual(find("b").start, 3, accuracy: 1e-9)
        XCTAssertEqual(find("d").start, 4, accuracy: 1e-9, "すべてのレイヤー")
        AppMenu.perform(.rippleAllLayersToggle, model: model)
        XCTAssertEqual(spec(.rippleAllLayersToggle).checked, false)
    }

    func testNoOpAndLockedRegisterNothing() {
        // 再生位置がクリップの外: 何もしない
        model.selectedClipId = "a"; model.currentTime = 4.5
        AppMenu.perform(.rippleTrimTail, model: model)
        XCTAssertFalse(um.canUndo)
        // 後ろのクリップがロック: 全体を断る
        model.edit("lock") { $0.tracks[0].clips[2].locked = true }
        let afterLock = model.project
        um.removeAllActions()
        model.currentTime = 2
        XCTAssertFalse(spec(.rippleTrimTail).enabled)
        XCTAssertFalse(model.rippleTrimSelectedToPlayhead(edge: .tail))
        XCTAssertEqual(model.project, afterLock)
        XCTAssertFalse(um.canUndo)
        XCTAssertEqual(model.statusText, ProjectModel.lockedNotice)
    }

    // MARK: ⌘ ドラッグ

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

    func testCommandDragOnRightEdgeRipplesAndIsOneUndo() {
        // a の右端を ⌘ で掴み、40pt(1 秒)左へ
        drag(from: NSPoint(x: x(4) - 2, y: y(row: 0)), to: NSPoint(x: x(4) - 2 - 40, y: y(row: 0)), .command)
        XCTAssertEqual(find("a").duration, 3, accuracy: 0.03)
        XCTAssertEqual(find("b").start, find("a").start + find("a").duration, accuracy: 1e-9, "後ろは詰まる")
        XCTAssertEqual(find("c").start, find("b").start + 4, accuracy: 1e-9, "後ろの間隔は保つ")
        XCTAssertEqual(find("d").start, 5)
        XCTAssertEqual(um.undoActionName, "リップルトリム")
        um.undo()
        XCTAssertEqual(find("a").duration, 4); XCTAssertEqual(find("b").start, 4)
        XCTAssertFalse(um.canUndo, "ドラッグ全体で 1 回")
    }

    func testCommandDragOnLeftEdgeKeepsHeadInPlace() {
        drag(from: NSPoint(x: x(4) + 2, y: y(row: 0)), to: NSPoint(x: x(4) + 2 + 40, y: y(row: 0)), .command)
        XCTAssertEqual(find("b").start, 4, accuracy: 1e-9, "頭の位置は動かさない")
        XCTAssertEqual(find("b").duration, 1, accuracy: 0.03)
        XCTAssertEqual(find("c").start, 7, accuracy: 0.03)
    }

    func testCommandDragRefusedOnLockedAndNoChangeRegistersNothing() {
        model.edit("lock") { $0.tracks[0].clips[1].locked = true }
        um.removeAllActions()
        let before = model.project
        drag(from: NSPoint(x: x(4) - 2, y: y(row: 0)), to: NSPoint(x: x(4) - 2 - 40, y: y(row: 0)), .command)
        XCTAssertEqual(model.project, before, "後ろのクリップがロックなら全体を断る")
        XCTAssertFalse(um.canUndo)
    }

    func testCommandClickOnEdgeWithoutDraggingTogglesSelection() {
        let p = NSPoint(x: x(4) - 2, y: y(row: 0))
        canvas.mouseDown(with: event(.leftMouseDown, p, .command)); canvas.mouseUp(with: event(.leftMouseUp, p, .command))
        XCTAssertEqual(model.selectedClipIDs, ["a"])
        XCTAssertFalse(um.canUndo)
    }

    func testCommandClickOnBodyStillTogglesSelection() {
        let p = NSPoint(x: x(2), y: y(row: 0))
        canvas.mouseDown(with: event(.leftMouseDown, p, .command)); canvas.mouseUp(with: event(.leftMouseUp, p, .command))
        XCTAssertTrue(model.selectedClipIDs.contains("a"))
        XCTAssertFalse(um.canUndo)
    }
}
