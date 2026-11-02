import XCTest
import AppKit
import MovieCutCore
@testable import MovieCut

/// 移動のドラッグ中に、移動先の前後のコマの帯を出す(タイムラインのドラッグ操作と同じ経路。1 回の Undo は変わらない)。
@MainActor
final class DragNeighborStripAppTests: XCTestCase {
    private var model: ProjectModel!
    private var canvas: TimelineCanvas!
    private var window: NSWindow!

    private func solid(_ name: String, r: CGFloat, g: CGFloat, b: CGFloat) throws -> String {
        let n = 32
        let c = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(red: r, green: g, blue: b, alpha: 1); c.fill(CGRect(x: 0, y: 0, width: n, height: n))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nb-\(UUID().uuidString)-\(name).png")
        let d = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(d, c.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(d))
        return url.path
    }

    override func setUp() async throws {
        var p = Project.new()
        p.width = 320; p.height = 180; p.fps = 30; p.characters = []
        func img(_ id: String, _ src: String, _ s: Double, _ d: Double) -> Clip {
            var c = Clip(); c.id = id; c.type = .image; c.src = src; c.start = s; c.duration = d; c.x = 0.5; c.y = 0.5; c.scale = 1
            return c
        }
        p.tracks[0].clips = [img("red", try solid("r", r: 1, g: 0, b: 0), 0, 2), img("blue", try solid("b", r: 0, g: 0, b: 1), 4, 2)]
        model = ProjectModel(project: p)
        model.snapEnabled = false
        model.pps = 40
        canvas = TimelineCanvas(frame: NSRect(x: 0, y: 0, width: 1000, height: 300))
        window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = canvas
        canvas.model = model
        canvas.neighborRenderer.synchronous = true
        canvas.syncFromModel()
    }

    override func tearDown() async throws {
        model.shutdown()
        window = nil; canvas = nil; model = nil
    }

    private func x(_ t: Double) -> CGFloat { canvas.geometry.x(forTime: t) }
    private func y(row: Int) -> CGFloat { canvas.geometry.rowTop(row) + 20 }
    private func event(_ type: NSEvent.EventType, _ p: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: canvas.convert(p, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    private var um: UndoManager { model.effectiveUndoManager }

    func testStripAppearsDuringMoveDragAndDisappearsOnRelease() throws {
        XCTAssertNil(canvas.neighborStrip)
        let a = NSPoint(x: x(5), y: y(row: 0))
        canvas.mouseDown(with: event(.leftMouseDown, a))
        XCTAssertNil(canvas.neighborStrip, "押しただけ(3pt 動くまではクリック)では出さない")
        // 青(4〜6)を 2 秒左へ → 2〜4 秒。頭は赤(0〜2)の終わりのすぐ後
        for i in 1...6 { canvas.mouseDragged(with: event(.leftMouseDragged, NSPoint(x: a.x - CGFloat(i) * (x(2) - x(0)) / 6, y: a.y))) }
        XCTAssertNotNil(canvas.neighborStrip, "移動のドラッグ中は出る")
        let times = try XCTUnwrap(canvas.neighborRenderer.lastTimes)
        XCTAssertEqual(times.headAfter, 2.0, accuracy: 1.0 / 30 + 1e-9)
        XCTAssertEqual(try XCTUnwrap(times.headBefore), times.headAfter - 1.0 / 30, accuracy: 1e-9)
        XCTAssertFalse(um.canUndo, "ドラッグ中は Undo に積まない")
        canvas.mouseUp(with: event(.leftMouseUp, a))
        XCTAssertNil(canvas.neighborStrip, "離したら消える")
        XCTAssertEqual(um.undoActionName, "クリップの移動")
        XCTAssertEqual(model.project.allClips.first { $0.id == "blue" }?.start ?? 0, 2, accuracy: 0.1)
    }

    func testStripHasNoEffectOnTheDragResultOrUndoSteps() {
        // 帯なし(同じ移動を debugDrag で)と、帯あり(マウス)で、結果が同じで Undo が 1 回
        let original = model.project
        canvas.debugDrag(clipId: "blue", mode: .move, deltaT: -2)
        let viaDebug = model.project
        um.undo()
        XCTAssertEqual(model.project, original)
        XCTAssertFalse(um.canUndo)
        canvas.debugDrag(clipId: "blue", mode: .move, deltaT: -2, hold: true)
        XCTAssertNotNil(canvas.neighborStrip, "debugDrag(hold) も同じ経路")
        canvas.mouseUp()
        XCTAssertNil(canvas.neighborStrip)
        XCTAssertEqual(model.project, viaDebug)
        um.undo()
        XCTAssertEqual(model.project, original)
        XCTAssertFalse(um.canUndo, "ちょうど 1 回の Undo")
    }

    func testTrimDragsDoNotShowTheStrip() {
        canvas.debugDrag(clipId: "blue", mode: .trimLeft, deltaT: 0.5, hold: true)
        XCTAssertNil(canvas.neighborStrip)
        canvas.mouseUp()
        canvas.debugDrag(clipId: "red", mode: .trimRight, deltaT: -0.5, hold: true)
        XCTAssertNil(canvas.neighborStrip)
        canvas.mouseUp()
    }

    func testStripIsDrawnOverTheTimeline() throws {
        canvas.debugDrag(clipId: "blue", mode: .move, deltaT: -2, hold: true)
        XCTAssertNotNil(canvas.neighborStrip)
        let rep = try XCTUnwrap(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
        canvas.cacheDisplay(in: canvas.bounds, to: rep)
        // 右上(ポインタが左寄り)に帯。幅は 1000 − 区切り幅 − 24 に収まる縮小(k < 1)。帯の位置の中央付近は、ほぼ黒の背板か映像の色
        let hw = TimelineLayout.headerWidth, rh = TimelineLayout.rulerHeight
        let k = min(1, (1000 - hw - 24) / CGFloat(canvas.neighborStrip!.width))
        let w = CGFloat(canvas.neighborStrip!.width) * k
        let px = Int(1000 - w - 12 + (CGFloat(DragNeighborFrames.cellWidth) * k) * 1.5 + 3 * k + 12 * k / 2)   // 「頭」と「終」の間あたり
        let py = Int(rh + 8 + CGFloat(canvas.neighborStrip!.height) * k / 2)
        let c = try XCTUnwrap(rep.colorAt(x: px, y: py)).usingColorSpace(.sRGB)!
        let bg = TimelinePalette.areaBG.usingColorSpace(.sRGB)!
        XCTAssertGreaterThan(abs(c.redComponent - bg.redComponent) + abs(c.greenComponent - bg.greenComponent) + abs(c.blueComponent - bg.blueComponent), 0.02,
                             "帯の背板が、タイムラインの背景と違う色で描かれている")
        canvas.mouseUp()
    }
}
