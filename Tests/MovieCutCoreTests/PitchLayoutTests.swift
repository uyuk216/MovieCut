import XCTest
@testable import MovieCutCore

final class PitchLayoutTests: XCTestCase {
    private func project(clipPitch: Double? = nil, extra: [Clip] = [], lockLayer: Bool = false) -> (Project, Clip) {
        var p = Project.new()
        var c = Clip(); c.type = .audio; c.src = "a.wav"; c.start = 2; c.duration = 1; c.srcDuration = 5; c.offset = 0
        if let clipPitch { _ = AudioFxEditing.setPitch(&c, clipPitch) }
        p.tracks[0].clips = [c] + extra
        if lockLayer { p.tracks[0].locked = true }
        return (p, c)
    }
    private func other(start: Double, dur: Double) -> Clip {
        var o = Clip(); o.type = .audio; o.src = "b.wav"; o.start = start; o.duration = dur; o.srcDuration = 9
        return o
    }

    func testScaleDegrees() {
        XCTAssertEqual((0..<8).map { PitchScale.major.degree($0) }, [0, 2, 4, 5, 7, 9, 11, 12])
        XCTAssertEqual((0..<8).map { PitchScale.minor.degree($0) }, [0, 2, 3, 5, 7, 8, 10, 12])
        XCTAssertEqual((0..<13).map { PitchScale.chromatic.degree($0) }, Array(0...12))
        XCTAssertEqual((0..<6).map { PitchScale.pentatonic.degree($0) }, [0, 2, 4, 7, 9, 12])
        XCTAssertEqual((0..<3).map { PitchScale.major.degree($0, descending: true) }, [0, -2, -4])
        XCTAssertEqual(Set(PitchScale.allCases.map(\.title)).count, PitchScale.allCases.count)
    }

    func testScalePlanLaysOutBackToBack() {
        let (_, c) = project()
        let r = PitchLayout.scalePlan(clip: c, scale: .major, rootShift: 0, count: 8, descending: false)
        XCTAssertEqual(r.steps.map(\.start), (0..<8).map { 2 + Double($0) })
        XCTAssertEqual(r.steps.map(\.pitch), [0, 2, 4, 5, 7, 9, 11, 12])
        XCTAssertEqual(r.truncated, 0)
    }

    func testScalePlanStopsAtPitchLimit() {
        let (_, c) = project(clipPitch: 20)
        let r = PitchLayout.scalePlan(clip: c, scale: .chromatic, rootShift: 0, count: 12, descending: false)
        XCTAssertEqual(r.steps.count, 5, "20,21,22,23,24 まで")
        XCTAssertEqual(r.truncated, 7)
    }

    func testApplyScaleInPlaceIsDisjointAndOneChange() throws {
        let (p, c) = project(clipPitch: 1)
        let plan = PitchLayout.scalePlan(clip: c, scale: .major, rootShift: 3, count: 5, descending: false)
        let r = try XCTUnwrap(PitchLayout.apply(in: p, clipId: c.id, steps: plan.steps))
        XCTAssertFalse(r.movedToOtherLayer)
        let clips = r.project.tracks[0].clips
        XCTAssertEqual(clips.count, 5)
        XCTAssertEqual(clips[0].id, c.id, "元のクリップが 1 つ目の音")
        XCTAssertEqual(Set(clips.map(\.id)).count, 5, "id は重ならない")
        XCTAssertEqual(clips.map { $0.audioFx?.pitchSemitones ?? 0 }, [4, 6, 8, 9, 11])
        for (a, b) in zip(clips, clips.dropFirst()) { XCTAssertEqual(a.start + a.duration, b.start, accuracy: 1e-9) }
        XCTAssertEqual(r.newIds.count, 4)
    }

    func testApplyMovesToFreeLayerWhenBlocked() throws {
        let (p, c) = project(extra: [other(start: 3.5, dur: 1)])
        let plan = PitchLayout.scalePlan(clip: c, scale: .major, rootShift: 0, count: 4, descending: false)
        let r = try XCTUnwrap(PitchLayout.apply(in: p, clipId: c.id, steps: plan.steps))
        XCTAssertTrue(r.movedToOtherLayer)
        XCTAssertEqual(r.project.tracks[0].clips.count, 2, "元のレイヤーは変わらない")
        let placed = r.project.allClips.filter { r.newIds.contains($0.id) }
        XCTAssertEqual(placed.count, 4)
        // どのレイヤーでも重ならない
        for t in r.project.tracks {
            let s = t.clips.sorted { $0.start < $1.start }
            for (a, b) in zip(s, s.dropFirst()) { XCTAssertLessThanOrEqual(a.start + a.duration, b.start + 1e-9) }
        }
    }

    func testLockedLayerAndUnsupportedClipsAreRefused() {
        let (p, c) = project(lockLayer: true)
        XCTAssertFalse(PitchLayout.supports(c, in: p))
        XCTAssertNil(PitchLayout.apply(in: p, clipId: c.id, steps: [PitchStep(start: 2, duration: 1, pitch: 1)]))
        var t = Clip(); t.type = .text; t.start = 0; t.duration = 1
        var q = Project.new(); q.tracks[0].clips = [t]
        XCTAssertFalse(PitchLayout.supports(t, in: q))
    }

    func testBeatPlanTrimsToGapAndStepsPitch() {
        let (_, c) = project()   // 長さ 1
        let r = PitchLayout.beatPlan(clip: c, times: [2, 2.4, 3.9, 6], pitchStep: 2, limit: 0)
        XCTAssertEqual(r.steps.map(\.start), [2, 2.4, 3.9, 6])
        XCTAssertEqual(r.steps.map(\.duration).map { ($0 * 1000).rounded() / 1000 }, [0.4, 1, 1, 1], "間隔より長くならない")
        XCTAssertEqual(r.steps.map(\.pitch), [0, 2, 4, 6])
        XCTAssertEqual(PitchLayout.beatPlan(clip: c, times: [2, 3, 4], pitchStep: 0, limit: 2).steps.count, 2)
    }

    func testMarkerTimesFiltering() {
        var p = Project.new()
        p.markers = [Marker(time: 1, name: "ビート"), Marker(time: 2, name: "メモ"), Marker(time: 2.001, name: "ビート"), Marker(time: 3, name: "ビート")]
        XCTAssertEqual(PitchLayout.markerTimes(in: p, from: 1.5, beatsOnly: false), [2, 3])
        XCTAssertEqual(PitchLayout.markerTimes(in: p, from: 0, beatsOnly: true), [1, 2.001, 3])
        XCTAssertEqual(PitchLayout.markerTimes(in: p, from: 10, beatsOnly: false), [])
    }

    func testApplyBeatPlanMovesOriginalToFirstBeat() throws {
        let (p, c) = project()
        let plan = PitchLayout.beatPlan(clip: c, times: [5, 5.5, 7], pitchStep: 1, limit: 0)
        let r = try XCTUnwrap(PitchLayout.apply(in: p, clipId: c.id, steps: plan.steps))
        let clips = r.project.tracks[0].clips
        XCTAssertEqual(clips.map(\.start), [5, 5.5, 7])
        XCTAssertEqual(clips[0].id, c.id)
        XCTAssertEqual(clips.map { $0.audioFx?.pitchSemitones ?? 0 }, [0, 1, 2])
        XCTAssertNil(clips[0].audioFx, "音程 0 のクリップに audioFx は書かない")
    }

    func testOldProjectBytesUnchangedWhenNoPitchUsed() throws {
        let (p, _) = project()
        let data = try JSONEncoder().encode(p)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("audioFx"))
    }
}
