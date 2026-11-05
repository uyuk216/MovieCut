import XCTest
@testable import MovieCutCore

/// リップルトリム(Core の純粋な計算)。
final class ClipRippleTrimTests: XCTestCase {
    private func video(_ id: String, start: Double, dur: Double, offset: Double = 0, src: Double = 20) -> Clip {
        var c = Clip(); c.id = id; c.type = .video; c.src = "/x/\(id).mov"; c.start = start; c.duration = dur
        c.offset = offset; c.srcDuration = src
        return c
    }
    private func get(_ p: Project, _ id: String) -> Clip { p.allClips.first { $0.id == id }! }

    /// レイヤー 0: a 0-4(素材 2-6)/ b 4-6 / c 8-9。レイヤー 1: d 5-7 / e 1-2(前にある)。
    private func base() -> Project {
        var p = Project.new()
        p.tracks[0].clips = [video("a", start: 0, dur: 4, offset: 2), video("b", start: 4, dur: 2), video("c", start: 8, dur: 1)]
        p.tracks[1].clips = [video("d", start: 5, dur: 2), video("e", start: 1, dur: 1)]
        return p
    }

    private func trim(_ p: Project, _ id: String, _ edge: ClipRippleTrim.Edge, _ d: Double, all: Bool = false) -> Project? {
        ClipRippleTrim.trim(in: p, clipId: id, edge: edge, deltaT: d, allLayers: all, playhead: 0, pps: 1, snapEnabled: false)?.project
    }

    func testTailShortenShiftsLaterClipsOnSameLayerOnly() throws {
        let p = try XCTUnwrap(trim(base(), "a", .tail, -1))
        XCTAssertEqual(get(p, "a").duration, 3, accuracy: 1e-9)
        XCTAssertEqual(get(p, "b").start, 3, accuracy: 1e-9)
        XCTAssertEqual(get(p, "c").start, 7, accuracy: 1e-9)
        XCTAssertEqual(get(p, "d").start, 5, accuracy: 1e-9, "別のレイヤーは動かさない")
        XCTAssertEqual(get(p, "b").duration, 2, accuracy: 1e-9)
    }

    func testTailExtendOpensGapAndRespectsSourceEnd() throws {
        let p = try XCTUnwrap(trim(base(), "a", .tail, 1.5))
        XCTAssertEqual(get(p, "a").duration, 5.5, accuracy: 1e-9)
        XCTAssertEqual(get(p, "b").start, 5.5, accuracy: 1e-9)
        XCTAssertEqual(get(p, "c").start, 9.5, accuracy: 1e-9)
        // 素材は 20 秒まで(offset 2 + 長さ ≤ 20)。延ばしすぎると素材の終わりで止まり、後ろもその分だけずれる
        let q = try XCTUnwrap(trim(base(), "a", .tail, 100))
        XCTAssertEqual(get(q, "a").duration, 18, accuracy: 1e-9)
        XCTAssertEqual(get(q, "b").start, 18, accuracy: 1e-9)
    }

    func testHeadTrimKeepsStartAndPullsLaterClipsBack() throws {
        let p = try XCTUnwrap(trim(base(), "a", .head, 1))
        let a = get(p, "a")
        XCTAssertEqual(a.start, 0, accuracy: 1e-9, "頭の位置は動かさない")
        XCTAssertEqual(a.duration, 3, accuracy: 1e-9)
        XCTAssertEqual(a.offset, 3, accuracy: 1e-9, "使う素材の頭が進む")
        XCTAssertEqual(get(p, "b").start, 3, accuracy: 1e-9)
        XCTAssertEqual(get(p, "c").start, 7, accuracy: 1e-9)
    }

    func testHeadExtendIsLimitedBySourceHeadAndNotByZero() throws {
        // b: 素材 0 から。頭は延ばせない(素材の頭より前がない)
        XCTAssertNil(trim(base(), "b", .head, -1))
        // a: offset 2 なので 2 秒まで延ばせる。開始位置が 0 でも 0 の下限に邪魔されない
        let p = try XCTUnwrap(trim(base(), "a", .head, -5))
        let a = get(p, "a")
        XCTAssertEqual(a.start, 0, accuracy: 1e-9)
        XCTAssertEqual(a.offset, 0, accuracy: 1e-9)
        XCTAssertEqual(a.duration, 6, accuracy: 1e-9)
        XCTAssertEqual(get(p, "b").start, 6, accuracy: 1e-9)
    }

    func testAllLayersShiftsLaterClipsOfEveryLayer() throws {
        let p = try XCTUnwrap(trim(base(), "a", .tail, -1, all: true))
        XCTAssertEqual(get(p, "d").start, 4, accuracy: 1e-9)
        XCTAssertEqual(get(p, "e").start, 1, accuracy: 1e-9, "終わりより前のクリップは動かさない")
        XCTAssertEqual(get(p, "c").start, 7, accuracy: 1e-9)
    }

    func testLockedLayerOrClipRefusesWholeEdit() {
        var p = base()
        p.tracks[0].locked = true
        XCTAssertNil(trim(p, "a", .tail, -1))
        XCTAssertNotNil(ClipRippleTrim.blockedReason(in: p, clipId: "a", edge: .tail, playhead: 2, allLayers: false))
        // 後ろのクリップだけがロック
        var q = base()
        q.tracks[0].clips[2].locked = true
        XCTAssertNil(trim(q, "a", .tail, -1), "後ろのクリップがロックなら全体を断る")
        XCTAssertEqual(ClipRippleTrim.blockedReason(in: q, clipId: "a", edge: .tail, playhead: 2, allLayers: false), ClipRippleTrim.lockedNotice)
        // 別レイヤーのロック: 同じレイヤーだけなら関係なし、すべてのレイヤーなら断る
        var r = base()
        r.tracks[1].locked = true
        XCTAssertNotNil(trim(r, "a", .tail, -1))
        XCTAssertNil(trim(r, "a", .tail, -1, all: true))
        // ロックされたレイヤーでも、後ろにクリップが無ければ関係なし
        var s = base()
        s.tracks[1].clips = [video("e", start: 1, dur: 1)]
        s.tracks[1].locked = true
        XCTAssertNotNil(trim(s, "a", .tail, -1, all: true))
    }

    func testNoOpAndMissingReturnNil() {
        XCTAssertNil(trim(base(), "a", .tail, 0))
        XCTAssertNil(trim(base(), "zzz", .tail, -1))
        XCTAssertNil(trim(base(), "a", .tail, .nan))
        // 最短の長さで止まり、すでに最短なら何も変わらない
        var p = base()
        p.tracks[0].clips[2].duration = ClipEditing.minDuration
        XCTAssertNil(trim(p, "c", .tail, -1))
    }

    func testNoNewOverlapsAndNoNegativeStarts() throws {
        // 元から重なっているクリップは、悪化させない限り許す
        var p = base()
        p.tracks[0].clips.append(video("o", start: 1, dur: 2))        // a と重なる(元から)
        XCTAssertEqual(ClipRippleTrim.overlapCount(p.tracks[0].clips), 1)
        let q = try XCTUnwrap(trim(p, "a", .tail, -1))
        XCTAssertEqual(ClipRippleTrim.overlapCount(q.tracks[0].clips), 1)
        // 一般の編集結果に新しい重なりが無く、開始が負にならない
        for d in stride(from: -3.9, through: 3.0, by: 0.7) {
            for edge in [ClipRippleTrim.Edge.head, .tail] {
                guard let r = trim(base(), "b", edge, d, all: true) else { continue }
                XCTAssertEqual(ClipRippleTrim.overlapCount(r.tracks[0].clips), 0)
                XCTAssertTrue(r.allClips.allSatisfy { $0.start >= 0 && $0.duration >= ClipEditing.minDuration - 1e-9 }, "\(edge) \(d)")
            }
        }
    }

    func testReverseAndSpeedClipsFollowTrimRules() throws {
        var p = base()
        p.tracks[0].clips[0].speed = 2            // 速度 2: 長さ 4 は素材 8 秒分
        let q = try XCTUnwrap(trim(p, "a", .head, 1))
        XCTAssertEqual(get(q, "a").offset, 4, accuracy: 1e-9, "1 秒 × 速度 2 = 素材 2 秒進む")
        XCTAssertEqual(get(q, "b").start, 3, accuracy: 1e-9)
    }

    func testToPlayheadOnlyInsideTheClip() throws {
        let p = base()
        let h = try XCTUnwrap(ClipRippleTrim.trimToPlayhead(in: p, clipId: "a", edge: .head, playhead: 1.5, allLayers: false))
        XCTAssertEqual(get(h, "a").duration, 2.5, accuracy: 1e-9)
        XCTAssertEqual(get(h, "b").start, 2.5, accuracy: 1e-9)
        let t = try XCTUnwrap(ClipRippleTrim.trimToPlayhead(in: p, clipId: "a", edge: .tail, playhead: 1.5, allLayers: false))
        XCTAssertEqual(get(t, "a").duration, 1.5, accuracy: 1e-9)
        XCTAssertEqual(get(t, "b").start, 1.5, accuracy: 1e-9)
        XCTAssertNil(ClipRippleTrim.trimToPlayhead(in: p, clipId: "a", edge: .tail, playhead: 9, allLayers: false))
        XCTAssertNil(ClipRippleTrim.trimToPlayhead(in: p, clipId: "a", edge: .head, playhead: 0, allLayers: false))
        XCTAssertNotNil(ClipRippleTrim.blockedReason(in: p, clipId: "a", edge: .head, playhead: 9, allLayers: false))
        XCTAssertNotNil(ClipRippleTrim.blockedReason(in: p, clipId: nil, edge: .head, playhead: 1, allLayers: false))
    }

    func testSnapAppliesToHeadAndTail() throws {
        let p = base()
        // 尻を -1.95(≒ 2.05 の位置)へ。マーカー相当の候補 e の終わり 2.0 に吸着する(pps 100 → 8pt = 0.08 秒)
        let r = try XCTUnwrap(ClipRippleTrim.trim(in: p, clipId: "a", edge: .tail, deltaT: -1.95, allLayers: false, playhead: 0, pps: 100, snapEnabled: true))
        XCTAssertEqual(get(r.project, "a").duration, 2, accuracy: 1e-9)
        XCTAssertEqual(r.guides, [2])
    }
}
