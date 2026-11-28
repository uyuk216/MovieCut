import XCTest
import MovieCutCore
@testable import MovieCut

/// 自動リフレームのアスペクト選択(キャンバス寸法への反映)。
@MainActor
final class AutoReframeOptionsAppTests: XCTestCase {
    func testSquareAspectSetsCanvasAndWritesKeysInOneUndo() throws {
        var c = Clip(); c.id = "v1"; c.type = .video; c.start = 0; c.duration = 2; c.src = "/tmp/none.mov"; c.srcDuration = 2
        var p = Project.new(); p.tracks[0].clips = [c]
        let m = ProjectModel(project: p)
        m.notices = OneTimeNotices()
        m.selectedClipId = "v1"
        var o = ReframeOptions(); o.aspect = .square; o.zoomEnabled = true
        let samples = (0...10).map { SubjectSample(t: Double($0) / 5, rects: [CGRect(x: 0.5, y: 0.4, width: 0.1 + 0.01 * Double($0), height: 0.2)]) }
        let plan = try XCTUnwrap(AutoReframe.plan(samples: samples, sourceWidth: 1920, sourceHeight: 1080, options: o))
        m.applyAutoReframe(plan, clipId: "v1")
        XCTAssertEqual(m.project.width, 1080)
        XCTAssertEqual(m.project.height, 1080)
        XCTAssertEqual(m.selectedClip?.keyframes["x"]?.count, samples.count)
        let u = m.effectiveUndoManager
        u.undo()
        XCTAssertEqual(m.project.width, 1920)
        XCTAssertFalse(u.canUndo)
    }
}
