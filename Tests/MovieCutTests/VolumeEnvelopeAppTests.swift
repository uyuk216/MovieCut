import XCTest
import MovieCutCore
@testable import MovieCut

/// 音量包絡線UI(監査 #64 / W3-23): モデルの追加・削除が各 1 回の Undo になること、
/// タイムライン上のダブルクリック追加・点ドラッグ・Option+クリック削除が 1 回の Undo にまとまること。
@MainActor
final class VolumeEnvelopeAppTests: XCTestCase {
    private func makeModel() -> ProjectModel {
        var p = Project.new()
        p.fps = 60
        var c = Clip(); c.id = "m"; c.type = .audio; c.start = 0; c.duration = 6
        c.src = "/tmp/none.wav"; c.srcDuration = 6; c.volume = 0.8
        p.tracks[0].clips = [c]
        let m = ProjectModel(project: p)
        m.notices = OneTimeNotices()
        m.selectedClipId = "m"
        return m
    }

    private func undoSteps(_ m: ProjectModel) -> Int {
        let u = m.effectiveUndoManager
        var n = 0
        while u.canUndo { u.undo(); n += 1 }
        for _ in 0..<n { u.redo() }
        return n
    }

    func testModelAddAndRemoveAreOneUndoStepEach() {
        let m = makeModel()
        let idx = m.addVolumePoint(clipId: "m", at: 3, gain: 0.2)
        XCTAssertEqual(idx, 1)
        XCTAssertEqual(m.clip("m").map { VolumeEnvelopeEditing.points($0).count }, 3)
        XCTAssertEqual(undoSteps(m), 1)
        XCTAssertTrue(m.removeVolumePoint(clipId: "m", index: 1))
        XCTAssertEqual(m.clip("m").map { VolumeEnvelopeEditing.points($0).count }, 2)
        XCTAssertEqual(undoSteps(m), 2)
        XCTAssertFalse(m.removeVolumePoint(clipId: "m", index: 42))
        XCTAssertEqual(undoSteps(m), 2, "無い点の削除は履歴に載せない")
    }

    func testProjectMovingVolumePointBuildsFromBase() {
        let m = makeModel()
        _ = m.addVolumePoint(clipId: "m", at: 3, gain: 0.2)
        let base = m.project
        let moved = m.projectMovingVolumePoint(base: base, clipId: "m", index: 1, toTime: 4, gain: 1.5)
        XCTAssertEqual(moved.flatMap { ClipEditing.locate("m", in: $0) }.map { _ in true }, true)
        let c = moved!.tracks[0].clips[0]
        XCTAssertEqual(VolumeEnvelopeEditing.points(c)[1].t, 4)
        XCTAssertEqual(VolumeEnvelopeEditing.points(c)[1].v, 1.5)
        // base は変わらない(ドラッグの作り直し用)
        XCTAssertEqual(VolumeEnvelopeEditing.points(base.tracks[0].clips[0])[1].t, 3)
    }

    // MARK: タイムライン操作

    private func makeCanvas(_ m: ProjectModel) -> (TimelineCanvas, NSWindow) {
        let canvas = TimelineCanvas(frame: NSRect(x: 0, y: 0, width: 1000, height: 300))
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = canvas
        canvas.model = m
        canvas.syncFromModel()
        return (canvas, window)
    }

    func testTimelineDoubleClickAddsDragMovesOptionClickDeletes() {
        let m = makeModel()
        m.pps = 100; m.snapEnabled = false
        let (canvas, window) = makeCanvas(m)
        _ = window
        let c = m.clip("m")!
        let r = canvas.geometry.clipRect(start: c.start, duration: c.duration, track: 0)
        let area = canvas.volumeEnvelopeRect(r)
        // クリップ中央(頭から 3 秒)・等倍より少し上(音量 1.2 → 割合 0.6)をダブルクリックで追加
        let addPoint = NSPoint(x: r.minX + 300, y: area.maxY - area.height * 0.6)
        canvas.mouseDown(at: addPoint, clickCount: 2); canvas.mouseUp()
        var pts = VolumeEnvelopeEditing.points(m.clip("m")!)
        XCTAssertEqual(pts.count, 3, "基準点 2 + 追加 1")
        XCTAssertEqual(pts[1].t, 3, accuracy: 0.02)
        XCTAssertEqual(pts[1].v, 1.2, accuracy: 0.05)
        XCTAssertEqual(undoSteps(m), 1, "追加は 1 回の Undo")
        // 点を右へ 100pt(=1 秒)・下へドラッグ: 時刻 4、音量は下がる。離すまで Undo に積まない
        let centers = canvas.volumePointCenters(m.clip("m")!, rect: r)
        XCTAssertEqual(centers.count, 3)
        let p1 = centers[1].point
        canvas.mouseDown(at: p1)
        for i in 1...5 { canvas.mouseDragged(to: NSPoint(x: p1.x + 20 * CGFloat(i), y: p1.y + 4 * CGFloat(i))) }
        canvas.mouseUp()
        pts = VolumeEnvelopeEditing.points(m.clip("m")!)
        XCTAssertEqual(pts[1].t, 4, accuracy: 0.02)
        XCTAssertLessThan(pts[1].v, 1.2)
        XCTAssertEqual(m.effectiveUndoManager.undoActionName, ProjectModel.volumeEnvelopeUndoName)
        XCTAssertEqual(undoSteps(m), 2, "ドラッグは 1 回の Undo にまとまる")
        // Option+クリックで削除
        let centers2 = canvas.volumePointCenters(m.clip("m")!, rect: r)
        canvas.mouseDown(at: centers2[1].point, modifiers: [.option]); canvas.mouseUp()
        XCTAssertEqual(VolumeEnvelopeEditing.points(m.clip("m")!).count, 2)
        XCTAssertEqual(undoSteps(m), 3)
    }
}
