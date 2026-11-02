import XCTest
import AVFoundation
@testable import MovieCutCore

/// 重なったクリップの音だけの試聴(スクラブ試聴): 対象の選び方・巡回・範囲・実際に鳴る音(他のクリップが混ざらない)。
final class AudioAuditionTests: XCTestCase {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("audition-tests-\(UUID().uuidString)")
    override func setUpWithError() throws { try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    func wav(_ name: String, amp: Float, seconds: Double = 4) throws -> String {
        let u = tmp.appendingPathComponent(name)
        try AudioFixture.writeSine(u, segments: [(seconds, amp)])
        return u.path
    }

    func clip(_ id: String, _ type: ClipType = .audio, src: String?, start: Double, duration: Double, offset: Double = 0) -> Clip {
        var c = Clip(); c.id = id; c.type = type; c.src = src; c.start = start; c.duration = duration; c.offset = offset
        return c
    }

    func project(_ tracks: [[Clip]]) -> Project {
        var p = Project()
        p.tracks = tracks.enumerated().map { i, cs in var t = Track(name: "L\(i)"); t.clips = cs; return t }
        return p
    }

    // MARK: 候補・巡回・対象

    func testAudibleIdsFollowTimeMuteAndFreeze() {
        var low = clip("low", src: "/a.wav", start: 0, duration: 4)
        let mid = clip("mid", src: "/b.wav", start: 2, duration: 4)
        var frozen = clip("frozen", .video, src: "/c.mov", start: 0, duration: 6); frozen.freeze = true
        let image = clip("image", .image, src: "/d.png", start: 0, duration: 6)
        let noSrc = clip("nosrc", src: nil, start: 0, duration: 6)
        low.duration = 4
        var p = project([[low, frozen, image, noSrc], [mid]])
        XCTAssertEqual(AudioAudition.audibleIds(at: 1, in: p), ["low"])
        XCTAssertEqual(AudioAudition.audibleIds(at: 3, in: p), ["low", "mid"], "下のレイヤーから順に")
        XCTAssertEqual(AudioAudition.audibleIds(at: 4, in: p), ["mid"], "終わりちょうどは含まない")
        XCTAssertEqual(AudioAudition.audibleIds(at: 7, in: p), [])
        XCTAssertEqual(AudioAudition.audibleIds(at: .nan, in: p), [])
        p.tracks[1].muted = true
        XCTAssertEqual(AudioAudition.audibleIds(at: 3, in: p), ["low"], "消音レイヤーは鳴らない")
    }

    func testCompoundChildrenAreAudibleAtAbsoluteTime() {
        var comp = clip("comp", .compound, src: nil, start: 10, duration: 4)
        var kt = Track(name: "中"); kt.clips = [clip("kid", src: "/k.wav", start: 1, duration: 2)]
        comp.tracks = [kt]
        let p = project([[comp]])
        XCTAssertEqual(AudioAudition.audibleIds(at: 10.5, in: p), [])
        XCTAssertEqual(AudioAudition.audibleIds(at: 11.5, in: p), ["kid"])
    }

    func testNextCyclesAndFallsBackToFirst() {
        XCTAssertNil(AudioAudition.next(after: nil, in: []))
        XCTAssertEqual(AudioAudition.next(after: nil, in: ["a", "b", "c"]), "a")
        XCTAssertEqual(AudioAudition.next(after: "a", in: ["a", "b", "c"]), "b")
        XCTAssertEqual(AudioAudition.next(after: "c", in: ["a", "b", "c"]), "a")
        XCTAssertEqual(AudioAudition.next(after: "zzz", in: ["a", "b"]), "a")
        XCTAssertEqual(AudioAudition.next(after: "a", in: ["a"]), "a")
    }

    func testTargetPrefersCurrentThenSelectionThenFirst() {
        let p = project([[clip("a", src: "/a.wav", start: 0, duration: 4)], [clip("b", src: "/b.wav", start: 1, duration: 4)]])
        XCTAssertEqual(AudioAudition.target(current: "b", selected: "a", at: 2, in: p), "b")
        XCTAssertEqual(AudioAudition.target(current: "b", selected: "a", at: 0.5, in: p), "a", "対象が鳴っていない時刻は選択へ")
        XCTAssertEqual(AudioAudition.target(current: nil, selected: nil, at: 2, in: p), "a")
        XCTAssertNil(AudioAudition.target(current: nil, selected: nil, at: 9, in: p))
    }

    func testSnippetRangeIsClippedToTheClip() {
        let c = clip("a", src: "/a.wav", start: 2, duration: 3)
        XCTAssertEqual(AudioAudition.snippetRange(clip: c, at: 3, length: 0.5), ExportRange(start: 3, end: 3.5))
        XCTAssertEqual(AudioAudition.snippetRange(clip: c, at: 4.8, length: 0.5)?.end ?? 0, 5, accuracy: 1e-9, "クリップの終わりで切る")
        XCTAssertNil(AudioAudition.snippetRange(clip: c, at: 4.99, length: 0.5), "残りが短すぎる")
        XCTAssertNil(AudioAudition.snippetRange(clip: c, at: 6, length: 0.5))
        XCTAssertEqual(AudioAudition.snippetRange(clip: c, at: 1.9, length: 0.5)?.start ?? 0, 2, accuracy: 1e-9, "頭より前は頭から")
    }

    func testSoloProjectKeepsOnlyTheClipAndDoesNotTouchTheSource() throws {
        let p = project([[clip("a", src: "/a.wav", start: 0, duration: 4)], [clip("b", src: "/b.wav", start: 1, duration: 4)]])
        let before = try p.encoded()
        let solo = try XCTUnwrap(AudioAudition.soloProject(p, clipId: "b"))
        XCTAssertEqual(solo.allClips.map(\.id), ["b"])
        XCTAssertNil(AudioAudition.soloProject(p, clipId: "nope"))
        XCTAssertEqual(try p.encoded(), before, "元のプロジェクトは変わらない")
    }

    // MARK: 実際の音

    func testSnippetContainsOnlyTheAuditionedClip() throws {
        let quiet = try wav("quiet.wav", amp: 0.1), loud = try wav("loud.wav", amp: 0.5)
        let p = project([[clip("quiet", src: quiet, start: 0, duration: 4)], [clip("loud", src: loud, start: 0, duration: 4)]])
        // 全体のミックスは両方の和(約 0.6)
        let all = tmp.appendingPathComponent("all.caf")
        try AudioMixer.mixdown(project: p, assets: RenderAssets(), to: all)
        XCTAssertEqual(try AudioFixture.peak(all, from: 1, to: 2), 0.6, accuracy: 0.03)
        for (id, amp) in [("quiet", Float(0.1)), ("loud", Float(0.5))] {
            let out = tmp.appendingPathComponent("\(id).caf")
            let d = try AudioAudition.renderSnippet(project: p, clipId: id, at: 1, to: out)
            XCTAssertEqual(try XCTUnwrap(d), 0.5, accuracy: 0.001)
            XCTAssertEqual(try AudioFixture.peak(out, from: 0.05, to: 0.45), amp, accuracy: 0.02, "\(id) だけが鳴る")
        }
    }

    func testSnippetStartsAtThePlayheadInsideTheSource() throws {
        // 前半 0.1・後半 0.7 の 4 秒の音。クリップは 10 秒から置いて offset 0。再生位置 12.5 → 素材の 2.5 秒(後半)
        let u = tmp.appendingPathComponent("two.wav")
        try AudioFixture.writeSine(u, segments: [(2, 0.1), (2, 0.7)])
        let p = project([[clip("c", src: u.path, start: 10, duration: 4)]])
        let late = tmp.appendingPathComponent("late.caf"), early = tmp.appendingPathComponent("early.caf")
        _ = try AudioAudition.renderSnippet(project: p, clipId: "c", at: 12.5, to: late)
        _ = try AudioAudition.renderSnippet(project: p, clipId: "c", at: 10.5, to: early)
        XCTAssertEqual(try AudioFixture.peak(late, from: 0.05, to: 0.45), 0.7, accuracy: 0.03)
        XCTAssertEqual(try AudioFixture.peak(early, from: 0.05, to: 0.45), 0.1, accuracy: 0.02)
    }

    func testCompoundChildCanBeAuditioned() throws {
        let kid = try wav("kid.wav", amp: 0.4), other = try wav("other.wav", amp: 0.2)
        var comp = clip("comp", .compound, src: nil, start: 5, duration: 4)
        var kt = Track(name: "中"); kt.clips = [clip("kid", src: kid, start: 0, duration: 4)]
        comp.tracks = [kt]
        let p = project([[comp], [clip("other", src: other, start: 5, duration: 4)]])
        let out = tmp.appendingPathComponent("kid.caf")
        let d = try AudioAudition.renderSnippet(project: p, clipId: "kid", at: 6, to: out)
        XCTAssertNotNil(d)
        XCTAssertEqual(try AudioFixture.peak(out, from: 0.05, to: 0.45), 0.4, accuracy: 0.02)
    }

    func testNothingToPlayReturnsNil() throws {
        let a = try wav("a.wav", amp: 0.3)
        let p = project([[clip("a", src: a, start: 0, duration: 1)]])
        XCTAssertNil(try AudioAudition.renderSnippet(project: p, clipId: "a", at: 5, to: tmp.appendingPathComponent("x.caf")), "範囲の外")
        XCTAssertNil(try AudioAudition.renderSnippet(project: p, clipId: "zzz", at: 0.2, to: tmp.appendingPathComponent("y.caf")), "対象が無い")
    }
}
