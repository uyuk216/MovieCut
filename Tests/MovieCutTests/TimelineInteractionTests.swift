import XCTest
import MovieCutCore
@testable import MovieCut

/// タイムラインの操作の判定(端のトリム・ダブルクリックの対象)と、右クリックメニュー・ダブルクリックの動き。
@MainActor
final class TimelineInteractionTests: XCTestCase {
    func testZoneEdgesAndBody() {
        XCTAssertEqual(TimelineHit.zone(x: 100, minX: 100, maxX: 300, edgeZone: 8), .left)
        XCTAssertEqual(TimelineHit.zone(x: 107.9, minX: 100, maxX: 300, edgeZone: 8), .left)
        XCTAssertEqual(TimelineHit.zone(x: 108, minX: 100, maxX: 300, edgeZone: 8), .body)
        XCTAssertEqual(TimelineHit.zone(x: 293, minX: 100, maxX: 300, edgeZone: 8), .right)
        XCTAssertEqual(TimelineHit.zone(x: 292, minX: 100, maxX: 300, edgeZone: 8), .body)
    }

    func testNarrowClipKeepsAMiddleToMove() {
        // 幅 12pt: 端は 4pt ずつ、真ん中 4pt は移動
        XCTAssertEqual(TimelineHit.zone(x: 106, minX: 100, maxX: 112, edgeZone: 8), .body)
        XCTAssertEqual(TimelineHit.zone(x: 103, minX: 100, maxX: 112, edgeZone: 8), .left)
        XCTAssertEqual(TimelineHit.zone(x: 109, minX: 100, maxX: 112, edgeZone: 8), .right)
    }

    func testDoubleClickTextTypes() {
        XCTAssertTrue(TimelineHit.editsTextOnDoubleClick(.text))
        XCTAssertTrue(TimelineHit.editsTextOnDoubleClick(.voice))
        XCTAssertFalse(TimelineHit.editsTextOnDoubleClick(.image))
        XCTAssertFalse(TimelineHit.editsTextOnDoubleClick(.video))
    }

    func testDoubleClickOnTextClipRequestsFocusButEdgeAndSingleClickDoNot() {
        var p = Project.new()
        var t = Clip(); t.id = "t"; t.type = .text; t.start = 1; t.duration = 4; t.text = "a"
        p.tracks[0].clips = [t]
        let m = ProjectModel(project: p)
        m.pps = 40
        let canvas = TimelineCanvas(frame: NSRect(x: 0, y: 0, width: 1200, height: 320))
        let w = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = canvas
        canvas.model = m
        canvas.syncFromModel()
        let y = canvas.geometry.rowTop(0) + canvas.geometry.rowHeight(0) / 2
        let mid = NSPoint(x: canvas.geometry.x(forTime: 3), y: y)
        canvas.mouseDown(at: mid, clickCount: 1); canvas.mouseUp()
        XCTAssertEqual(m.textFocusRequest, 0)
        canvas.mouseDown(at: mid, clickCount: 2); canvas.mouseUp()
        XCTAssertEqual(m.textFocusRequest, 1)
        canvas.mouseDown(at: NSPoint(x: canvas.geometry.x(forTime: 1) + 2, y: y), clickCount: 2); canvas.mouseUp()
        XCTAssertEqual(m.textFocusRequest, 1, "端のダブルクリックはトリムなので入力へ移らない")
        m.shutdown()
    }

    func testClipContextMenuHasSplit() {
        var p = Project.new()
        var a = Clip(); a.id = "a"; a.type = .image; a.start = 0; a.duration = 4; a.src = "/tmp/none.png"
        p.tracks[0].clips = [a]
        let m = ProjectModel(project: p)
        let canvas = TimelineCanvas(frame: NSRect(x: 0, y: 0, width: 1200, height: 320))
        canvas.model = m
        m.selectOnly("a")
        let titles = canvas.clipContextMenu()?.items.map(\.title) ?? []
        XCTAssertTrue(titles.contains("再生位置で分割"))
        m.shutdown()
    }
}
