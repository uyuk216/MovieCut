import XCTest
import SwiftUI
import AppKit
import MovieCutCore
@testable import MovieCut

@MainActor
final class EaseCurveAppTests: XCTestCase {
    private func makeModel() -> ProjectModel {
        var p = Project.new()
        p.fps = 60
        var c = Clip(); c.id = "a"; c.type = .image; c.start = 0; c.duration = 4; c.src = "/tmp/none.png"
        c.keyframes["x"] = [Keyframe(t: 0, v: 0.2), Keyframe(t: 1, v: 0.8), Keyframe(t: 2, v: 0.2)]
        p.tracks[0].clips = [c]
        let m = ProjectModel(project: p)
        m.notices = OneTimeNotices()
        m.selectedClipId = "a"
        m.playback.seek(to: 1)
        return m
    }

    private func ease(_ m: ProjectModel, _ i: Int) -> Ease { m.clip("a")!.keyframes["x"]![i].ease }

    func testSetKeyEaseIsOneUndoStep() {
        let m = makeModel()
        let e = Ease.bezier(0.34, 1.56, 0.64, 1)
        XCTAssertTrue(m.setKeyEase("x", e))
        XCTAssertEqual(ease(m, 1), e)
        XCTAssertEqual(ease(m, 0), .linear)
        m.effectiveUndoManager.undo()
        XCTAssertEqual(ease(m, 1), .linear)
        XCTAssertFalse(m.effectiveUndoManager.canUndo)
        m.effectiveUndoManager.redo()
        XCTAssertEqual(ease(m, 1), e)
    }

    func testNoOpRegistersNothing() throws {
        let m = makeModel()
        let before = try m.project.encoded()
        XCTAssertFalse(m.setKeyEase("x", .linear))            // 同じ
        XCTAssertFalse(m.setKeyEase("y", .easeIn))            // キー無し
        XCTAssertEqual(try m.project.encoded(), before)
        XCTAssertFalse(m.effectiveUndoManager.canUndo)
    }

    func testNoOpAtMidTimeAndLocked() throws {
        let m = makeModel()
        m.playback.seek(to: 0.5)
        let before = try m.project.encoded()
        XCTAssertFalse(m.setKeyEase("x", .easeIn))
        XCTAssertFalse(m.effectiveUndoManager.canUndo)
        XCTAssertEqual(try m.project.encoded(), before)
    }

    func testEditorViewRendersNonBlank() throws {
        let host = NSHostingView(rootView: EaseCurveEditor(ease: .bezier(0.34, 1.56, 0.64, 1), onCommit: { _ in })
            .background(Color(nsColor: .windowBackgroundColor)))
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 480)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        for _ in 0..<5 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let bg = try XCTUnwrap(rep.colorAt(x: 2, y: 2))
        var differing = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                if abs(c.redComponent - bg.redComponent) + abs(c.greenComponent - bg.greenComponent) + abs(c.blueComponent - bg.blueComponent) > 0.1 { differing += 1 }
            }
        }
        XCTAssertGreaterThan(differing, 300)
    }
}
