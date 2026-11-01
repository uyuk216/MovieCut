import XCTest
@testable import MovieCutCore

/// ぴったり揃える(吸着)の候補: クリップの端・再生ヘッド・マーカー・範囲の印。
final class SnapTargetTests: XCTestCase {
    private func project() -> Project {
        var p = Project.new()
        var c = Clip(); c.type = .voice; c.src = "/tmp/a.wav"; c.start = 0; c.duration = 2
        p.tracks[0].clips.append(c)
        var m = Marker(); m.time = 5.0
        p.markers = [m]
        return p
    }

    func testSnapsToMarkerWithinThreshold() {
        let p = project()
        // 1pt = 1/100 秒(pps 100)。8pt 以内なら吸着する
        XCTAssertEqual(ClipEditing.snapPoint(4.95, excluding: nil, project: p, playhead: 0, pps: 100, enabled: true), 5.0)
        XCTAssertNil(ClipEditing.snapPoint(4.5, excluding: nil, project: p, playhead: 0, pps: 100, enabled: true))
    }

    func testSnapsToRangeMarks() {
        var p = project()
        p.rangeIn = 10
        p.rangeOut = 12.5
        XCTAssertEqual(ClipEditing.snapPoint(9.97, excluding: nil, project: p, playhead: 0, pps: 100, enabled: true), 10)
        XCTAssertEqual(ClipEditing.snapPoint(12.52, excluding: nil, project: p, playhead: 0, pps: 100, enabled: true), 12.5)
    }

    func testNoRangeMarksMeansNoExtraTargets() {
        let p = project()
        XCTAssertEqual(ClipEditing.snapCandidates(excluding: nil, project: p, playhead: 1).count, 2 + 2 + 1)   // 0・再生ヘッド・クリップの頭と終わり・マーカー
    }

    func testDisabledSnapsToNothing() {
        let p = project()
        XCTAssertNil(ClipEditing.snapPoint(5.0, excluding: nil, project: p, playhead: 0, pps: 100, enabled: false))
        XCTAssertEqual(ClipEditing.snapTime(4.99, excluding: nil, project: p, playhead: 0, pps: 100, enabled: false), 4.99)
    }

    func testMarkerSnapAppliesToClipTrim() {
        var p = project()
        // 右端を 4.97 付近へ伸ばす → マーカー 5.0 に揃う
        p.tracks[0].clips[0].duration = 2
        let r = ClipEditing.trimRight(in: p, clipId: p.tracks[0].clips[0].id, deltaT: 2.97, playhead: 0, pps: 100, snapEnabled: true)
        XCTAssertEqual(r.project.tracks[0].clips[0].duration, 5.0, accuracy: 1e-9)
    }
}
