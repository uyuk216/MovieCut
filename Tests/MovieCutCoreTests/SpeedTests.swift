import XCTest
import AVFoundation
import CoreGraphics
import VideoToolbox
@testable import MovieCutCore

/// 速度・逆再生・フリーズフレーム: 時間の対応(純粋な関数)、ファイル、編集(トリム・分割)、描画と書き出し(コマの確認)、音声(長さ・音程・逆順)。
final class SpeedTests: XCTestCase {
    // MARK: 道具

    func video(_ id: String = "v", start: Double = 0, dur: Double, offset: Double = 0, speed: Double? = nil, reverse: Bool = false, src: Double = 100) -> Clip {
        var c = Clip(); c.id = id; c.type = .video; c.src = "/tmp/none.mp4"; c.start = start; c.duration = dur; c.offset = offset
        c.srcDuration = src; c.speed = speed; c.reverse = reverse ? true : nil
        return c
    }

    func project(_ clips: [Clip], fps: Double = 30) -> Project {
        var p = Project(); p.fps = fps; p.tracks = [Track(name: "t")]; p.tracks[0].clips = clips
        return p
    }

    func fixtureURL(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "ymproj", subdirectory: "Fixtures"))
    }

    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("speed-tests-\(UUID().uuidString)")
    override func setUpWithError() throws { try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    // MARK: 時間の対応

    func testForwardMapping() {
        let c = video(dur: 4, offset: 1, speed: 2)       // 素材の 1〜9 秒を 4 秒で
        XCTAssertEqual(ClipTiming.sourceSpan(c), 8)
        XCTAssertEqual(ClipTiming.sourceTime(of: c, atClipTime: 0), 1)
        XCTAssertEqual(ClipTiming.sourceTime(of: c, atClipTime: 1.5), 4)
        XCTAssertEqual(ClipTiming.sourceTime(of: c, atClipTime: 4), 9)
        let slow = video(dur: 4, offset: 1, speed: 0.5)   // 素材の 1〜3 秒を 4 秒で
        XCTAssertEqual(ClipTiming.sourceTime(of: slow, atClipTime: 4), 3)
        XCTAssertEqual(ClipTiming.sourceTime(of: slow, atClipTime: 1), 1.5)
    }

    func testReverseMapping() {
        let c = video(dur: 4, offset: 1, speed: 2, reverse: true)   // 素材の 1〜9 秒を逆向きに 4 秒で
        XCTAssertEqual(ClipTiming.sourceTime(of: c, atClipTime: 0), 9)
        XCTAssertEqual(ClipTiming.sourceTime(of: c, atClipTime: 1), 7)
        XCTAssertEqual(ClipTiming.sourceTime(of: c, atClipTime: 4), 1)
        let r1 = video(dur: 3, offset: 2, reverse: true)
        XCTAssertEqual(ClipTiming.sourceTime(of: r1, atClipTime: 0), 5)
        XCTAssertEqual(ClipTiming.sourceTime(of: r1, atClipTime: 3), 2)
    }

    func testFreezeMappingIsConstant() {
        var c = video(dur: 2, offset: 3.25, speed: 4, reverse: true); c.freeze = true
        XCTAssertTrue(c.isFreeze)
        for t in [0.0, 0.7, 2.0] { XCTAssertEqual(ClipTiming.sourceTime(of: c, atClipTime: t), 3.25) }
        XCTAssertNil(ClipTiming.clipTime(of: c, forSourceTime: 3.25))
        XCTAssertEqual(ClipTiming.sourceSpan(c), 0)
        XCTAssertEqual(c.effectiveSpeed, 1); XCTAssertFalse(c.effectiveReverse)
        XCTAssertFalse(c.hasAudioRemap)
    }

    func testInverseRoundTripBothDirections() {
        for (sp, rev) in [(1.0, false), (2.0, false), (0.5, false), (0.25, false), (4.0, false), (1.0, true), (2.0, true), (0.5, true), (3.3, true)] {
            let c = video(dur: 5, offset: 1.25, speed: sp, reverse: rev)
            for t in stride(from: 0.0, through: 5.0, by: 0.37) {
                let s = ClipTiming.sourceTime(of: c, atClipTime: t)
                XCTAssertEqual(ClipTiming.clipTime(of: c, forSourceTime: s) ?? -99, t, accuracy: 1e-9, "speed \(sp) reverse \(rev) t \(t)")
            }
        }
    }

    func testSpeed1ForwardIsBitIdenticalToLegacyFormula() {
        let c = video(start: 3.3, dur: 4, offset: 0.7)
        for t in stride(from: 3.3, to: 7.3, by: 1.0 / 60) {
            XCTAssertEqual(ClipTiming.sourceTime(of: c, atClipTime: t - c.start), t - c.start + c.offset)
        }
        XCTAssertFalse(c.hasTimeRemap)
    }

    func testFrameSourceTimeForReverseIsLeadingEdgeOfOutputFrame() {
        // 30fps で 30 コマ(0〜1 秒)を逆再生: 29, 28, …, 0 の順(コマ番号 = 素材の時刻 × 30)
        let c = video(dur: 1, offset: 0, reverse: true)
        let idx = (0..<30).map { Int(((ClipTiming.frameSourceTime(of: c, atClipTime: Double($0) / 30, fps: 30) + 0.001) * 30).rounded(.down)) }
        XCTAssertEqual(idx, Array((0..<30).reversed()))
        // 順再生は sourceTime そのまま
        let f = video(dur: 1, offset: 0.5, speed: 2)
        XCTAssertEqual(ClipTiming.frameSourceTime(of: f, atClipTime: 0.25, fps: 30), ClipTiming.sourceTime(of: f, atClipTime: 0.25))
    }

    func testSpeedClampAndLenientValues() {
        XCTAssertEqual(ClipTiming.clampSpeed(0.1), 0.25); XCTAssertEqual(ClipTiming.clampSpeed(9), 4)
        XCTAssertEqual(ClipTiming.clampSpeed(.nan), 1); XCTAssertEqual(ClipTiming.clampSpeed(-2), 1); XCTAssertEqual(ClipTiming.clampSpeed(0), 1)
        var c = video(dur: 1); c.speed = 100
        XCTAssertEqual(c.speedOrDefault, 4, "範囲外の値は読むときは保ち、使うときに収める")
        XCTAssertEqual(c.speed, 100)
        var img = Clip(); img.type = .image; img.speed = 3; img.reverse = true
        XCTAssertEqual(img.effectiveSpeed, 1, "対応しない種類では無視"); XCTAssertFalse(img.effectiveReverse)
        var voice = Clip(); voice.type = .voice; voice.speed = 3
        XCTAssertEqual(voice.effectiveSpeed, 1)
    }

    func testBadgeText() {
        XCTAssertNil(ClipTiming.badge(for: video(dur: 1)))
        XCTAssertEqual(ClipTiming.badge(for: video(dur: 1, speed: 2)), "×2")
        XCTAssertEqual(ClipTiming.badge(for: video(dur: 1, speed: 0.5)), "×0.5")
        XCTAssertEqual(ClipTiming.badge(for: video(dur: 1, speed: 1.25)), "×1.25")
        XCTAssertEqual(ClipTiming.badge(for: video(dur: 1, reverse: true)), "◀")
        XCTAssertEqual(ClipTiming.badge(for: video(dur: 1, speed: 4, reverse: true)), "◀×4")
        var f = video(dur: 1); f.freeze = true
        XCTAssertEqual(ClipTiming.badge(for: f), "静止")
        var img = Clip(); img.type = .image
        XCTAssertNil(ClipTiming.badge(for: img))
    }

    // MARK: ファイル

    func testUntouchedClipWritesNoSpeedKeys() throws {
        var c = video(dur: 1)
        XCTAssertTrue(SpeedEditing.setSpeed(&c, 2)); XCTAssertTrue(SpeedEditing.setSpeed(&c, 1))
        XCTAssertTrue(SpeedEditing.setReverse(&c, true)); XCTAssertTrue(SpeedEditing.setReverse(&c, false))
        XCTAssertTrue(SpeedEditing.setKeepPitch(&c, false)); XCTAssertTrue(SpeedEditing.setKeepPitch(&c, true))
        let s = String(decoding: try JSONEncoder().encode(c), as: UTF8.self)
        for k in ["speed", "reverse", "keepPitch", "freeze"] { XCTAssertFalse(s.contains("\"\(k)\""), k) }
    }

    func testSpeedFixtureRoundTripsAndKeepsUnknowns() throws {
        let p1 = try Project.load(from: fixtureURL("speed"))
        let fast = p1.allClips.first { $0.id == "sfast" }!
        XCTAssertEqual(fast.speed, 2); XCTAssertNil(fast.reverse); XCTAssertEqual(fast.effectiveSpeed, 2)
        XCTAssertEqual(fast.extra["futureClipKey"], .object(["keep": .array([.number(1), .number(2), .number(3)])]))
        let rev = p1.allClips.first { $0.id == "srev" }!
        XCTAssertEqual(rev.speed, 0.5); XCTAssertEqual(rev.reverse, true); XCTAssertEqual(rev.keepPitch, false)
        XCTAssertTrue(rev.hasAudioRemap); XCTAssertFalse(rev.keepPitchOrDefault)
        let fr = p1.allClips.first { $0.id == "sfreeze" }!
        XCTAssertTrue(fr.isFreeze); XCTAssertEqual(fr.offset, 3.25)
        XCTAssertEqual(p1.allClips.first { $0.id == "saud" }!.effectiveSpeed, 0.5)
        // 型が違う値は捨てずに書き戻す
        let bad = p1.allClips.first { $0.id == "sbad" }!
        XCTAssertNil(bad.speed); XCTAssertNil(bad.reverse); XCTAssertNil(bad.keepPitch); XCTAssertNil(bad.freeze)
        XCTAssertEqual(bad.extra["speed"], .string("fast")); XCTAssertEqual(bad.extra["reverse"], .number(1))
        XCTAssertEqual(bad.extra["keepPitch"], .string("no")); XCTAssertEqual(bad.extra["freeze"], .array([]))
        XCTAssertFalse(bad.hasTimeRemap)
        let data = try p1.encoded()
        let p2 = try Project.decode(from: data)
        XCTAssertEqual(p1, p2)
        XCTAssertEqual(try p2.encoded(), data)
        let s = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(s.components(separatedBy: "\"keepPitch\"").count - 1, 2, "false のときだけ書く(+ 壊れた値の書き戻し 1)")
        // 型違いの項目を後から正しく設定しても、キーが二重にならない
        var b = bad
        XCTAssertTrue(SpeedEditing.setSpeed(&b, 2))
        XCTAssertNil(b.extra["speed"])
        let one = String(decoding: try JSONEncoder().encode(b), as: UTF8.self)
        XCTAssertEqual(one.components(separatedBy: "\"speed\"").count - 1, 1)
    }

    func testOldFixturesDoNotGainSpeedKeys() throws {
        for n in ["rich", "electron-made", "keyframes", "transitions", "effects"] {
            let p = try Project.load(from: fixtureURL(n))
            XCTAssertTrue(p.allClips.allSatisfy { !$0.hasTimeRemap && $0.speed == nil && $0.reverse == nil && $0.keepPitch == nil && $0.freeze == nil }, n)
            // キャラクターにも speed があるので、クリップごとに書き出して調べる
            for c in p.allClips {
                let s = String(decoding: try JSONEncoder().encode(c), as: UTF8.self)
                for k in ["\"speed\"", "\"reverse\"", "\"keepPitch\"", "\"freeze\""] { XCTAssertFalse(s.contains(k), "\(n) \(c.id) \(k)") }
            }
        }
    }

    // MARK: 速度の編集

    func testSetSpeedKeepsLeftEdgeAndInPointAndRescalesDuration() {
        var c = video(start: 5, dur: 4, offset: 2)
        XCTAssertTrue(SpeedEditing.setSpeed(&c, 2))
        XCTAssertEqual(c.start, 5); XCTAssertEqual(c.offset, 2); XCTAssertEqual(c.duration, 2, accuracy: 1e-9)
        XCTAssertEqual(c.speed, 2)
        XCTAssertTrue(SpeedEditing.setSpeed(&c, 0.5))
        XCTAssertEqual(c.duration, 8, accuracy: 1e-9)
        XCTAssertTrue(SpeedEditing.setSpeed(&c, 1))
        XCTAssertNil(c.speed, "1 は未設定に戻す"); XCTAssertEqual(c.duration, 4, accuracy: 1e-9)
        XCTAssertFalse(SpeedEditing.setSpeed(&c, 1), "変わらない編集は false")
        XCTAssertTrue(SpeedEditing.setSpeed(&c, 99)); XCTAssertEqual(c.speed, 4)
        var img = Clip(); img.type = .image; img.duration = 3
        XCTAssertFalse(SpeedEditing.setSpeed(&img, 2))
        var f = video(dur: 2); f.freeze = true
        XCTAssertFalse(SpeedEditing.setSpeed(&f, 2)); XCTAssertFalse(SpeedEditing.setReverse(&f, true))
    }

    func testSetSpeedKeepsSourceRangeForReverse() {
        var c = video(dur: 4, offset: 2, reverse: true)
        XCTAssertTrue(SpeedEditing.setSpeed(&c, 2))
        XCTAssertEqual(c.offset, 2); XCTAssertEqual(c.duration, 2, accuracy: 1e-9)
        // 使う素材の範囲 [2, 6] は同じ。頭に出るコマは素材の 6 秒
        XCTAssertEqual(ClipTiming.sourceTime(of: c, atClipTime: 0), 6, accuracy: 1e-9)
        XCTAssertEqual(ClipTiming.sourceTime(of: c, atClipTime: 2), 2, accuracy: 1e-9)
    }

    func testSlowDownClampsToNextClipOnSameLayer() throws {
        let a = video("a", start: 0, dur: 4, offset: 0)
        let b = video("b", start: 6, dur: 2)
        let p = project([a, b])
        // 0.5 倍 → 8 秒になるが、次のクリップ(6 秒)で止める
        let q = try XCTUnwrap(SpeedEditing.settingSpeed(in: p, clipId: "a", 0.5))
        let ca = q.allClips.first { $0.id == "a" }!
        XCTAssertEqual(ca.duration, 6, accuracy: 1e-9)
        XCTAssertEqual(ca.speed, 0.5)
        XCTAssertEqual(ClipTiming.sourceSpan(ca), 3, accuracy: 1e-9, "素材は 3 秒ぶんだけ使う(終わりを切る)")
        XCTAssertEqual(q.allClips.first { $0.id == "b" }!.start, 6, "後ろは動かさない")
        // 逆再生は頭に出るコマを変えない
        var ar = a; ar.offset = 1; ar.reverse = true
        let qr = try XCTUnwrap(SpeedEditing.settingSpeed(in: project([ar, b]), clipId: "a", 0.5))
        let cr = qr.allClips.first { $0.id == "a" }!
        XCTAssertEqual(ClipTiming.sourceTime(of: cr, atClipTime: 0), 1 + 4, accuracy: 1e-9, "左端のコマは素材の 5 秒のまま")
        XCTAssertEqual(cr.duration, 6, accuracy: 1e-9)
        // 他のレイヤーのクリップは気にしない
        var p2 = project([a]); p2.tracks.append(Track(name: "u")); p2.tracks[1].clips = [video("c", start: 5, dur: 2)]
        XCTAssertEqual(SpeedEditing.settingSpeed(in: p2, clipId: "a", 0.5)?.allClips.first { $0.id == "a" }?.duration ?? 0, 8, accuracy: 1e-9)
        // すでに重なっているときは、いまの終わりまで
        let over = project([video("a", start: 0, dur: 5), video("b", start: 3, dur: 2)])
        XCTAssertEqual(SpeedEditing.settingSpeed(in: over, clipId: "a", 0.5)?.allClips.first { $0.id == "a" }?.duration ?? 0, 5, accuracy: 1e-9)
        // 速くする(短くなる)ときは何も止めない
        XCTAssertEqual(SpeedEditing.settingSpeed(in: p, clipId: "a", 2)?.allClips.first { $0.id == "a" }?.duration ?? 0, 2, accuracy: 1e-9)
        XCTAssertNil(SpeedEditing.settingSpeed(in: p, clipId: "a", 1), "変化なしは nil")
        XCTAssertNil(SpeedEditing.settingSpeed(in: p, clipId: "nope", 2))
    }

    func testKeyframesAndTransitionsStayInTimelineTime() {
        var c = video(dur: 4, offset: 0)
        c.keyframes = ["x": [Keyframe(t: 0, v: 0.2), Keyframe(t: 3, v: 0.8)]]
        c.transitionIn = Transition(kind: "fade", duration: 0.5)
        XCTAssertTrue(SpeedEditing.setSpeed(&c, 2))
        XCTAssertEqual(c.keyframes["x"]?.map(\.t), [0, 3], "キーの時刻は動かさない")
        XCTAssertEqual(c.transitionIn?.duration, 0.5)
    }

    func testReverseTogglePreservesRangeAndDuration() {
        var c = video(dur: 4, offset: 2, speed: 2)
        XCTAssertTrue(SpeedEditing.setReverse(&c, true))
        XCTAssertEqual(c.offset, 2); XCTAssertEqual(c.duration, 4); XCTAssertEqual(c.reverse, true)
        XCTAssertFalse(SpeedEditing.setReverse(&c, true))
        XCTAssertTrue(SpeedEditing.setReverse(&c, false)); XCTAssertNil(c.reverse)
        XCTAssertFalse(SpeedEditing.setKeepPitch(&c, true), "既定のまま")
        XCTAssertTrue(SpeedEditing.setKeepPitch(&c, false)); XCTAssertEqual(c.keepPitch, false)
    }

    // MARK: トリム・分割(素材が途切れない)

    /// 分割・トリムの前後で、同じタイムライン時刻に出る素材のコマが変わらないことを確かめる道具。
    func sourceAt(_ p: Project, _ t: Double) -> Double? {
        for c in p.allClips where t >= c.start - 1e-9 && t < c.start + c.duration - 1e-9 {
            return ClipTiming.sourceTime(of: c, atClipTime: t - c.start)
        }
        return nil
    }

    func testSplitKeepsSourceContinuity() throws {
        for (sp, rev) in [(2.0, false), (0.5, false), (1.0, true), (2.0, true), (0.5, true), (1.0, false)] {
            let c = video(start: 3, dur: 6, offset: 1.5, speed: sp == 1 ? nil : sp, reverse: rev)
            let p = project([c])
            let r = try XCTUnwrap(ClipEditing.split(in: p, clipId: "v", at: 5.2))
            XCTAssertEqual(r.project.allClips.count, 2)
            for t in stride(from: 3.0, to: 9.0, by: 0.173) {
                XCTAssertEqual(sourceAt(r.project, t) ?? -1, sourceAt(p, t) ?? -2, accuracy: 1e-9, "speed \(sp) reverse \(rev) t \(t)")
            }
            let l = r.project.allClips[0], rr = r.project.allClips[1]
            XCTAssertEqual(l.speed, c.speed); XCTAssertEqual(rr.reverse, c.reverse)
            XCTAssertEqual(l.duration + rr.duration, 6, accuracy: 1e-9)
        }
    }

    func testSplitOffsetsMatchExpectedNumbers() throws {
        // 2 倍: 右の offset = 1.5 + 2.2 × 2
        let f = try XCTUnwrap(ClipEditing.split(video(start: 3, dur: 6, offset: 1.5, speed: 2), at: 5.2))
        XCTAssertEqual(f.left.offset, 1.5); XCTAssertEqual(f.right.offset, 1.5 + 2.2 * 2, accuracy: 1e-9)
        // 逆再生: 左の offset = 1.5 + (6 − 2.2) × 1、右は元のまま
        let r = try XCTUnwrap(ClipEditing.split(video(start: 3, dur: 6, offset: 1.5, reverse: true), at: 5.2))
        XCTAssertEqual(r.left.offset, 1.5 + 3.8, accuracy: 1e-9); XCTAssertEqual(r.right.offset, 1.5)
    }

    func testTrimLeftAndRightKeepSourceContinuity() {
        for (sp, rev) in [(2.0, false), (0.5, false), (1.0, true), (2.0, true), (0.5, true)] {
            let c = video(start: 3, dur: 6, offset: 4, speed: sp == 1 ? nil : sp, reverse: rev)
            let p = project([c])
            let tl = ClipEditing.trimLeft(in: p, clipId: "v", deltaT: 1.3, playhead: 0, pps: 100, snapEnabled: false).project
            let tr = ClipEditing.trimRight(in: p, clipId: "v", deltaT: -1.1, playhead: 0, pps: 100, snapEnabled: false).project
            let cl = tl.allClips[0], cr = tr.allClips[0]
            XCTAssertEqual(cl.start, 4.3, accuracy: 1e-9); XCTAssertEqual(cl.duration, 4.7, accuracy: 1e-9)
            XCTAssertEqual(cr.start, 3); XCTAssertEqual(cr.duration, 4.9, accuracy: 1e-9)
            for t in stride(from: 4.4, to: 8.0, by: 0.31) {
                XCTAssertEqual(sourceAt(tl, t) ?? -1, sourceAt(p, t) ?? -2, accuracy: 1e-9, "trimLeft speed \(sp) reverse \(rev) t \(t)")
            }
            for t in stride(from: 3.0, to: 7.8, by: 0.31) {
                XCTAssertEqual(sourceAt(tr, t) ?? -1, sourceAt(p, t) ?? -2, accuracy: 1e-9, "trimRight speed \(sp) reverse \(rev) t \(t)")
            }
        }
    }

    func testTrimOffsetsMatchExpectedNumbers() {
        let fw = project([video(start: 3, dur: 6, offset: 4, speed: 2)])
        var q = ClipEditing.trimLeft(in: fw, clipId: "v", deltaT: 1, playhead: 0, pps: 100, snapEnabled: false).project.allClips[0]
        XCTAssertEqual(q.offset, 6, accuracy: 1e-9)            // 4 + 1 × 2
        q = ClipEditing.trimRight(in: fw, clipId: "v", deltaT: -1, playhead: 0, pps: 100, snapEnabled: false).project.allClips[0]
        XCTAssertEqual(q.offset, 4); XCTAssertEqual(q.duration, 5, accuracy: 1e-9)
        let rv = project([video(start: 3, dur: 6, offset: 4, speed: 0.5, reverse: true)])
        q = ClipEditing.trimLeft(in: rv, clipId: "v", deltaT: 1, playhead: 0, pps: 100, snapEnabled: false).project.allClips[0]
        XCTAssertEqual(q.offset, 4, "逆再生の左端は素材の終わり側: offset は動かない")
        q = ClipEditing.trimRight(in: rv, clipId: "v", deltaT: -1, playhead: 0, pps: 100, snapEnabled: false).project.allClips[0]
        XCTAssertEqual(q.offset, 4.5, accuracy: 1e-9)          // 4 + 1 × 0.5
    }

    func testTrimLimits() {
        // 順再生: 右端は (srcDuration − offset) ÷ speed まで
        var p = project([video(start: 0, dur: 2, offset: 6, speed: 2, src: 10)])
        var c = ClipEditing.trimRight(in: p, clipId: "v", deltaT: 50, playhead: 0, pps: 100, snapEnabled: false).project.allClips[0]
        XCTAssertEqual(c.duration, 2, accuracy: 1e-9, "(10 − 6) ÷ 2 = 2")
        // 順再生: 左端は offset ÷ speed まで(素材の頭を越えない)
        p = project([video(start: 10, dur: 4, offset: 3, speed: 2, src: 100)])
        c = ClipEditing.trimLeft(in: p, clipId: "v", deltaT: -50, playhead: 0, pps: 100, snapEnabled: false).project.allClips[0]
        XCTAssertEqual(c.offset, 0, accuracy: 1e-9); XCTAssertEqual(c.start, 8.5, accuracy: 1e-9)
        // 逆再生: 右端は素材の頭(offset = 0)で止まる
        p = project([video(start: 0, dur: 2, offset: 1, speed: 2, reverse: true, src: 10)])
        c = ClipEditing.trimRight(in: p, clipId: "v", deltaT: 50, playhead: 0, pps: 100, snapEnabled: false).project.allClips[0]
        XCTAssertEqual(c.offset, 0, accuracy: 1e-9); XCTAssertEqual(c.duration, 2.5, accuracy: 1e-9)
        // 逆再生: 左端は素材の終わりで止まる((10 − 1 − 4) ÷ 2 = 2.5 まで延ばせる)
        p = project([video(start: 10, dur: 2, offset: 1, speed: 2, reverse: true, src: 10)])
        c = ClipEditing.trimLeft(in: p, clipId: "v", deltaT: -50, playhead: 0, pps: 100, snapEnabled: false).project.allClips[0]
        XCTAssertEqual(c.start, 7.5, accuracy: 1e-9); XCTAssertEqual(c.offset, 1)
        // 最短 0.05
        c = ClipEditing.trimRight(in: p, clipId: "v", deltaT: -50, playhead: 0, pps: 100, snapEnabled: false).project.allClips[0]
        XCTAssertEqual(c.duration, ClipEditing.minDuration, accuracy: 1e-9)
    }

    func testTrimBeforeAfterKeepSourceContinuity() throws {
        for (sp, rev) in [(2.0, false), (0.5, false), (1.0, true), (2.0, true), (0.5, true)] {
            let c = video(start: 3, dur: 6, offset: 4, speed: sp == 1 ? nil : sp, reverse: rev)
            let p = project([c])
            let b = try XCTUnwrap(ClipEditing.trimBefore(in: p, clipId: "v", at: 5))
            let a = try XCTUnwrap(ClipEditing.trimAfter(in: p, clipId: "v", at: 7))
            for t in stride(from: 5.05, to: 9.0, by: 0.29) { XCTAssertEqual(sourceAt(b, t) ?? -1, sourceAt(p, t) ?? -2, accuracy: 1e-9, "before \(sp) \(rev) \(t)") }
            for t in stride(from: 3.0, to: 6.9, by: 0.29) { XCTAssertEqual(sourceAt(a, t) ?? -1, sourceAt(p, t) ?? -2, accuracy: 1e-9, "after \(sp) \(rev) \(t)") }
        }
    }

    func testDuplicateCopiesSpeedFlags() throws {
        var c = video(start: 0, dur: 2, offset: 1, speed: 2, reverse: true); c.keepPitch = false
        let r = try XCTUnwrap(ClipEditing.duplicate(in: project([c]), clipId: "v"))
        let d = r.project.allClips.first { $0.id == r.newId }!
        XCTAssertEqual(d.speed, 2); XCTAssertEqual(d.reverse, true); XCTAssertEqual(d.keepPitch, false); XCTAssertEqual(d.offset, 1)
    }

    func testAudioClipsFollowTheSameRules() throws {
        var a = Clip(); a.id = "a"; a.type = .audio; a.src = "/tmp/none.wav"; a.start = 0; a.duration = 4; a.offset = 1; a.srcDuration = 20; a.speed = 2
        let r = try XCTUnwrap(ClipEditing.split(a, at: 1))
        XCTAssertEqual(r.right.offset, 1 + 1 * 2, accuracy: 1e-9)
        var voice = Clip(); voice.type = .voice; voice.duration = 4; voice.speed = 3; voice.offset = 1
        let v = try XCTUnwrap(ClipEditing.split(voice, at: 1))
        XCTAssertEqual(v.right.offset, 2, "ボイスは速度の対象外")
    }

    // MARK: フリーズフレーム

    func testFreezeFrameSplitsAndInsertsAndRipples() throws {
        let a = video("a", start: 2, dur: 6, offset: 1, speed: 2)       // 2〜8 秒。素材 1〜13
        let after = video("z", start: 8, dur: 1)
        var p = project([a, after])
        p.tracks.append(Track(name: "u")); p.tracks[1].clips = [video("other", start: 9, dur: 1)]
        let r = try XCTUnwrap(SpeedEditing.freezeFrame(in: p, clipId: "a", at: 4))
        let clips = r.project.tracks[0].clips
        XCTAssertEqual(clips.count, 4)
        XCTAssertEqual(clips.map(\.id).filter { $0 != "a" && $0 != "z" && $0 != r.freezeId }.count, 1, "右の断片")
        XCTAssertEqual(clips[0].id, "a"); XCTAssertEqual(clips[0].duration, 2, accuracy: 1e-9)
        let f = clips[1]
        XCTAssertEqual(f.id, r.freezeId); XCTAssertTrue(f.isFreeze); XCTAssertEqual(f.start, 4); XCTAssertEqual(f.duration, 2)
        XCTAssertEqual(f.offset, 1 + 2 * 2, accuracy: 1e-9, "再生位置 4 秒に出ていた素材の 5 秒")
        XCTAssertNil(f.speed); XCTAssertNil(f.reverse)
        let right = clips[2]
        XCTAssertEqual(right.start, 6, accuracy: 1e-9); XCTAssertEqual(right.duration, 4, accuracy: 1e-9)
        XCTAssertEqual(right.offset, 5, accuracy: 1e-9)
        XCTAssertEqual(right.speed, 2)
        // 右の断片は、ずらした分だけ後ろで同じ素材のコマ
        XCTAssertEqual(ClipTiming.sourceTime(of: right, atClipTime: 0), ClipTiming.sourceTime(of: f, atClipTime: 1), accuracy: 1e-9)
        XCTAssertEqual(clips[3].id, "z"); XCTAssertEqual(clips[3].start, 10, "後ろのクリップは 2 秒ずれる")
        XCTAssertEqual(r.project.tracks[1].clips[0].start, 9, "他のレイヤーは動かさない")
        XCTAssertEqual(r.project.endTime, 11, accuracy: 1e-9, "同じレイヤーの最後(z)が 2 秒ずれて 11 秒。他のレイヤーは動かない")
    }

    func testFreezeFrameOnReverseShowsTheSameFrameAsPlayback() throws {
        let a = video("a", start: 0, dur: 3, offset: 1, reverse: true, src: 20)   // 素材 1〜4 を逆向き
        let p = project([a], fps: 30)
        let r = try XCTUnwrap(SpeedEditing.freezeFrame(in: p, clipId: "a", at: 1))
        let f = r.project.allClips.first { $0.id == r.freezeId }!
        let playback = ClipTiming.frameSourceTime(of: a, atClipTime: 1, fps: 30)
        XCTAssertEqual(f.offset, playback, accuracy: 1e-9)
        XCTAssertEqual(ClipTiming.frameSourceTime(of: f, atClipTime: 0.5, fps: 30), playback, accuracy: 1e-9)
    }

    func testFreezeFrameAtClipStartAndRefusals() throws {
        var a = video("a", start: 2, dur: 4, offset: 1); a.transitionIn = Transition(kind: "fade", duration: 0.5)
        let p = project([a])
        let r = try XCTUnwrap(SpeedEditing.freezeFrame(in: p, clipId: "a", at: 2))
        XCTAssertEqual(r.project.tracks[0].clips.count, 2)
        let f = r.project.tracks[0].clips[0], rest = r.project.tracks[0].clips[1]
        XCTAssertTrue(f.isFreeze); XCTAssertEqual(f.start, 2); XCTAssertEqual(f.offset, 1); XCTAssertNotNil(f.transitionIn, "頭のトランジションは静止画へ")
        XCTAssertEqual(rest.start, 4); XCTAssertEqual(rest.duration, 4); XCTAssertNil(rest.transitionIn)
        XCTAssertNil(SpeedEditing.freezeFrame(in: p, clipId: "a", at: 6), "終わりは含まない")
        XCTAssertNil(SpeedEditing.freezeFrame(in: p, clipId: "a", at: 1), "クリップの外")
        var img = Clip(); img.id = "i"; img.type = .image; img.duration = 3
        XCTAssertNil(SpeedEditing.freezeFrame(in: project([img]), clipId: "i", at: 1))
        let again = try XCTUnwrap(SpeedEditing.freezeFrame(in: p, clipId: "a", at: 3))
        XCTAssertNil(SpeedEditing.freezeFrame(in: again.project, clipId: again.freezeId, at: 3.5), "静止画をさらに静止画にはしない")
    }

    func testFreezeBakesKeyframedValues() throws {
        var a = video("a", start: 0, dur: 4); a.x = 0.5
        a.keyframes = ["x": [Keyframe(t: 0, v: 0.2), Keyframe(t: 4, v: 0.6)]]
        let r = try XCTUnwrap(SpeedEditing.freezeFrame(in: project([a]), clipId: "a", at: 2))
        let f = r.project.allClips.first { $0.id == r.freezeId }!
        XCTAssertTrue(f.keyframes.isEmpty)
        XCTAssertEqual(f.x ?? -1, 0.4, accuracy: 1e-9)
    }

    func testFreezeTrimAndSplitDoNotMoveOffset() throws {
        var f = video("f", start: 0, dur: 4, offset: 3.25); f.freeze = true
        let p = project([f])
        let q = ClipEditing.trimLeft(in: p, clipId: "f", deltaT: 1, playhead: 0, pps: 100, snapEnabled: false).project.allClips[0]
        XCTAssertEqual(q.offset, 3.25); XCTAssertEqual(q.duration, 3, accuracy: 1e-9)
        let q2 = ClipEditing.trimRight(in: p, clipId: "f", deltaT: 100, playhead: 0, pps: 100, snapEnabled: false).project.allClips[0]
        XCTAssertGreaterThan(q2.duration, 4, "静止画はいくらでも延ばせる")
        let s = try XCTUnwrap(ClipEditing.split(f, at: 1))
        XCTAssertEqual(s.left.offset, 3.25); XCTAssertEqual(s.right.offset, 3.25)
    }

    // MARK: 描画(コマ)と書き出し

    /// コマ番号を 8 つの白黒の四角(2 進数)で表した動画。H.264 や色空間の変換を通っても、四角の真ん中が白か黒かは変わらない。
    static let bitCount = 8

    func makeIndexVideo(frames: Int, fps: Int = 30, size: (Int, Int) = (320, 180)) throws -> URL {
        let url = tmp.appendingPathComponent("index-\(frames)-\(fps).mp4")
        try? FileManager.default.removeItem(at: url)
        let w = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: size.0, AVVideoHeightKey: size.1,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 4_000_000, AVVideoMaxKeyFrameIntervalKey: 15],
        ])
        let ad = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: size.0, kCVPixelBufferHeightKey as String: size.1])
        w.add(input)
        XCTAssertTrue(w.startWriting())
        w.startSession(atSourceTime: .zero)
        for i in 0..<frames {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, ad.pixelBufferPool!, &pb)
            let buf = try XCTUnwrap(pb)
            CVPixelBufferLockBaseAddress(buf, [])
            let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
            let bpr = CVPixelBufferGetBytesPerRow(buf)
            let cell = size.0 / Self.bitCount
            for y in 0..<size.1 { for x in 0..<size.0 {
                let bit = min(Self.bitCount - 1, x / cell)
                let on = (i >> (Self.bitCount - 1 - bit)) & 1 == 1
                let v: UInt8 = on ? 255 : 0
                let o = y * bpr + x * 4
                base[o] = v; base[o + 1] = v; base[o + 2] = v; base[o + 3] = 255
            } }
            CVPixelBufferUnlockBaseAddress(buf, [])
            XCTAssertTrue(ad.append(buf, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps))))
        }
        input.markAsFinished()
        let done = expectation(description: "write")
        w.finishWriting { done.fulfill() }
        wait(for: [done], timeout: 30)
        XCTAssertEqual(w.status, .completed)
        return url
    }

    /// 画像の四角の真ん中の明るさからコマ番号を読む。
    func index(of img: CGImage) -> Int {
        let w = 320, h = 180
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let c = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        var n = 0
        for k in 0..<Self.bitCount {
            let o = (h / 2 * w + (k * w / Self.bitCount + w / Self.bitCount / 2)) * 4
            n = (n << 1) | ((Int(px[o]) + Int(px[o + 1]) + Int(px[o + 2])) / 3 > 127 ? 1 : 0)
        }
        return n
    }

    /// 素材 `url`(30fps・N コマ)を使うプロジェクト(320×180・30fps)。
    func clipProject(_ url: URL, dur: Double, offset: Double = 0, speed: Double? = nil, reverse: Bool = false) -> Project {
        var c = video("v", start: 0, dur: dur, offset: offset, speed: speed, reverse: reverse, src: 10)
        c.src = url.path
        var p = project([c], fps: 30); p.width = 320; p.height = 180; p.bg = "#000000"
        return p
    }

    /// プレビューの道(AVAssetImageGenerator)で、各コマの時刻に出る素材のコマ番号。
    func previewIndices(_ p: Project, frames: Int) throws -> [Int] {
        let r = Renderer(project: p, assets: RenderAssets())
        return try (0..<frames).map { i in index(of: try XCTUnwrap(r.renderImage(t: Double(i) / 30), "frame \(i)")) }
    }

    /// 書き出しの道(Exporter → mp4 → 読み戻し)で、各コマに出た素材のコマ番号。
    func exportedIndices(_ p: Project, name: String) async throws -> [Int] {
        let out = tmp.appendingPathComponent("\(name).mp4")
        try await Exporter(project: p, assets: RenderAssets()).export(to: out)
        return try rawIndices(of: out)
    }

    /// mp4 を AVAssetReader で順に読んだ、各コマの番号。
    func rawIndices(of url: URL) throws -> [Int] {
        let asset = AVURLAsset(url: url)
        let track = try XCTUnwrap(asset.tracks(withMediaType: .video).first)
        let rd = try AVAssetReader(asset: asset)
        let o = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        rd.add(o); XCTAssertTrue(rd.startReading())
        var out: [Int] = []
        while let sb = o.copyNextSampleBuffer() {
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
            var img: CGImage?
            VTCreateCGImageFromCVPixelBuffer(pb, options: nil, imageOut: &img)
            out.append(index(of: try XCTUnwrap(img)))
        }
        return out
    }

    /// `legacyPreview`: 速度 1・順再生の部分を含む。その道(従来から許容幅 1/120 秒の AVAssetImageGenerator)は、
    /// 隣のコマを返すことがあるので、プレビューは ±1 コマまで許す(速度・逆再生・フリーズの部分は厳密に確かめる)。書き出しは常に厳密。
    func expectIndices(_ p: Project, frames: Int, expected: [Int], name: String, legacyPreview: [ClosedRange<Int>]? = nil, file: StaticString = #filePath, line: UInt = #line) async throws {
        let prev = try previewIndices(p, frames: expected.count)
        if let loose = legacyPreview {
            for i in 0..<expected.count {
                if loose.contains(where: { $0.contains(i) }) { XCTAssertLessThanOrEqual(abs(prev[i] - expected[i]), 1, "プレビュー(\(name)) \(i)", file: file, line: line) }
                else { XCTAssertEqual(prev[i], expected[i], "プレビュー(\(name)) \(i)", file: file, line: line) }
            }
        } else {
            XCTAssertEqual(prev, expected, "プレビュー(\(name))", file: file, line: line)
        }
        let ex = try await exportedIndices(p, name: name)
        XCTAssertEqual(ex, expected, "書き出し(\(name))", file: file, line: line)
    }

    func testIndexVideoIsReadableAndForwardPlaybackUnchanged() async throws {
        let url = try makeIndexVideo(frames: 48)
        XCTAssertEqual(try rawIndices(of: url), Array(0..<48), "素材そのもの")
        // 速度 1 の順再生は、素材のコマがそのまま 1 コマずつ(従来の道)
        try await expectIndices(clipProject(url, dur: 1.6), frames: 48, expected: Array(0..<48), name: "plain", legacyPreview: [0...47])
    }

    func testSpeed2PreviewAndExport() async throws {
        let url = try makeIndexVideo(frames: 48)
        let p = clipProject(url, dur: 0.8, speed: 2)      // 素材 48 コマを 0.8 秒(24 コマ)で
        try await expectIndices(p, frames: 24, expected: (0..<24).map { 2 * $0 }, name: "x2")
    }

    func testSpeedHalfPreviewAndExportRepeatFrames() async throws {
        let url = try makeIndexVideo(frames: 48)
        let p = clipProject(url, dur: 3.2, speed: 0.5)    // 素材 48 コマを 3.2 秒(96 コマ)で
        try await expectIndices(p, frames: 96, expected: (0..<96).map { $0 / 2 }, name: "x05")
    }

    func testReversePreviewAndExport() async throws {
        let url = try makeIndexVideo(frames: 48)
        try await expectIndices(clipProject(url, dur: 1.6, reverse: true), frames: 48, expected: Array((0..<48).reversed()), name: "rev")
    }

    func testReverseWithSpeedAndOffsetExport() async throws {
        let url = try makeIndexVideo(frames: 48)
        // 素材の 0.5〜1.3 秒(コマ 15〜38)を 2 倍の逆再生で 0.4 秒(12 コマ): 37, 35, …
        let p = clipProject(url, dur: 0.4, offset: 0.5, speed: 2, reverse: true)
        try await expectIndices(p, frames: 12, expected: (0..<12).map { 37 - 2 * $0 }, name: "revx2")
    }

    func testReverseSlowMotion() async throws {
        let url = try makeIndexVideo(frames: 48)
        // 素材 0〜1.6 秒を 0.5 倍の逆再生で 3.2 秒(96 コマ): 47 を 2 コマ、46 を 2 コマ…
        let p = clipProject(url, dur: 3.2, speed: 0.5, reverse: true)
        try await expectIndices(p, frames: 96, expected: (0..<96).map { 47 - $0 / 2 }, name: "revx05")
    }

    func testFreezeFramePreviewAndExport() async throws {
        let url = try makeIndexVideo(frames: 48)
        var p = clipProject(url, dur: 1.6)
        let r = try XCTUnwrap(SpeedEditing.freezeFrame(in: p, clipId: "v", at: 0.5, length: 0.5))
        p = r.project
        // 0〜0.5: 0..14、0.5〜1.0: 凍結(15)、1.0〜: 15..47
        let expected = Array(0..<15) + Array(repeating: 15, count: 15) + Array(15..<48)
        try await expectIndices(p, frames: expected.count, expected: expected, name: "freeze", legacyPreview: [0...14, 30...61])
    }

    func testSplitSpeedClipsPlayContinuouslyInExport() async throws {
        let url = try makeIndexVideo(frames: 48)
        var p = clipProject(url, dur: 0.8, speed: 2)
        p = try XCTUnwrap(ClipEditing.split(in: p, clipId: "v", at: 0.4)).project
        try await expectIndices(p, frames: 24, expected: (0..<24).map { 2 * $0 }, name: "split-x2")
        // 逆再生の分割
        var q = clipProject(url, dur: 1.6, reverse: true)
        q = try XCTUnwrap(ClipEditing.split(in: q, clipId: "v", at: 0.8)).project
        try await expectIndices(q, frames: 48, expected: Array((0..<48).reversed()), name: "split-rev")
    }

    func testReverseUsesBoundedChunks() throws {
        let url = try makeIndexVideo(frames: 120)
        let budget = 8 * 320 * 180 * 4                        // 8 コマぶんのメモリ
        let rev = ReverseVideoFrames(url: url, byteBudget: budget) { _ in nil }
        XCTAssertEqual(rev.capacityFrames, 8)
        XCTAssertLessThanOrEqual(ReverseVideoFrames(url: url) { _ in nil }.capacityFrames, ReverseVideoFrames.maxFramesLimit)
        var got: [Int] = []
        for i in stride(from: 119, through: 0, by: -1) {
            let img = try XCTUnwrap(rev.frame(at: Double(i) / 30))
            got.append(index(of: img))
            XCTAssertLessThanOrEqual(rev.loadedFrames, rev.capacityFrames + 17, "メモリの束は上限のまま")
        }
        XCTAssertEqual(got, Array((0..<120).reversed()))
        XCTAssertLessThanOrEqual(rev.chunkLoads, 120 / 8 + 3, "束ごとに読む(コマごとに読み直さない)")
        XCTAssertGreaterThanOrEqual(rev.chunkLoads, 10)
        XCTAssertGreaterThan(rev.prefetchHits, 5, "先読みが間に合っている")
    }

    // MARK: 音声

    func writeWav(_ name: String, seconds: Double, _ gen: (Int) -> Float) throws -> URL {
        let url = tmp.appendingPathComponent(name)
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
        let f = try AVAudioFile(forWriting: url, settings: fmt.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let n = Int(seconds * 48000)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n))!
        buf.frameLength = AVAudioFrameCount(n)
        for i in 0..<n { let v = gen(i); buf.floatChannelData![0][i] = v; buf.floatChannelData![1][i] = v }
        try f.write(from: buf)
        return url
    }

    func mix(_ p: Project) throws -> (samples: [Float], duration: Double) {
        let out = tmp.appendingPathComponent("mix-\(UUID().uuidString).caf")
        let res = try AudioMixer.mixdownDetailed(project: p, to: out)
        let f = try AVAudioFile(forReading: out)
        let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
        try f.read(into: buf)
        return (Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength))), res.duration)
    }

    /// 零交差から周波数(Hz)を推定する。
    func frequency(_ s: ArraySlice<Float>) -> Double {
        var crossings = 0
        var prev = s.first ?? 0
        for v in s.dropFirst() { if (prev < 0) != (v < 0) { crossings += 1 }; prev = v }
        return Double(crossings) / 2 / (Double(s.count) / 48000)
    }

    func audioProject(_ url: URL, dur: Double, offset: Double = 0, speed: Double? = nil, reverse: Bool = false, keepPitch: Bool? = nil) -> Project {
        var a = Clip(); a.id = "a"; a.type = .audio; a.src = url.path; a.start = 0; a.duration = dur; a.offset = offset; a.srcDuration = 10
        a.speed = speed; a.reverse = reverse ? true : nil; a.keepPitch = keepPitch
        return project([a])
    }

    func testToneAtDoubleSpeedKeepsPitchAndHalvesDuration() throws {
        let tone = try writeWav("tone440.wav", seconds: 4) { Float(0.5 * sin(2 * Double.pi * 440 * Double($0) / 48000)) }
        let plain = try mix(audioProject(tone, dur: 2))
        XCTAssertEqual(frequency(plain.samples[9600..<86400]), 440, accuracy: 6)
        let fast = try mix(audioProject(tone, dur: 2, speed: 2))        // 素材 4 秒を 2 秒で
        XCTAssertEqual(fast.duration, 2, accuracy: 1e-6)
        XCTAssertEqual(fast.samples.count, 96000)
        let f = frequency(fast.samples[9600..<86400])
        XCTAssertEqual(f, 440, accuracy: 440 * 0.03, "音程を保つ: \(f) Hz")
        let rms = sqrt(fast.samples[9600..<86400].reduce(0) { $0 + Double($1 * $1) } / 76800)
        XCTAssertEqual(rms, 0.5 / 2.0.squareRoot(), accuracy: 0.05, "音量が保たれる")
        // 音が途切れていない(頭も終わりも鳴っている)
        XCTAssertGreaterThan(fast.samples[2000..<6000].map { abs($0) }.max() ?? 0, 0.3)
        XCTAssertGreaterThan(fast.samples[90000..<94000].map { abs($0) }.max() ?? 0, 0.3)
    }

    func testToneSlowAndNoKeepPitch() throws {
        let tone = try writeWav("tone440b.wav", seconds: 4) { Float(0.5 * sin(2 * Double.pi * 440 * Double($0) / 48000)) }
        let slow = try mix(audioProject(tone, dur: 4, speed: 0.5))      // 素材 2 秒を 4 秒で
        XCTAssertEqual(slow.samples.count, 192000)
        XCTAssertEqual(frequency(slow.samples[19200..<172800]), 440, accuracy: 440 * 0.03)
        let high = try mix(audioProject(tone, dur: 2, speed: 2, keepPitch: false))
        XCTAssertEqual(high.samples.count, 96000)
        XCTAssertEqual(frequency(high.samples[9600..<86400]), 880, accuracy: 880 * 0.03, "音程を保たない: 速度ぶん高くなる")
        let low = try mix(audioProject(tone, dur: 4, speed: 0.5, keepPitch: false))
        XCTAssertEqual(frequency(low.samples[19200..<172800]), 220, accuracy: 220 * 0.03)
    }

    func testReverseIsExactSampleReversal() throws {
        var seed: UInt64 = 7
        let noise = try writeWav("noise.wav", seconds: 1) { _ in seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Float(Int8(truncatingIfNeeded: seed >> 40)) / 200 }
        let fwd = try mix(audioProject(noise, dur: 1))
        let rev = try mix(audioProject(noise, dur: 1, reverse: true))
        XCTAssertEqual(rev.samples.count, fwd.samples.count)
        let n = fwd.samples.count
        var worst: Float = 0
        for i in 0..<n { worst = max(worst, abs(rev.samples[i] - fwd.samples[n - 1 - i])) }
        XCTAssertLessThan(worst, 1e-6)
        // 範囲(offset)つき: 素材の 0.25〜0.75 秒を逆向きに
        let part = try mix(audioProject(noise, dur: 0.5, offset: 0.25, reverse: true))
        for i in stride(from: 0, to: part.samples.count, by: 97) {
            XCTAssertEqual(part.samples[i], fwd.samples[36000 - 1 - i], accuracy: 1e-6)
        }
    }

    func testReverseOfRisingToneFalls() throws {
        let rising = try writeWav("rising.wav", seconds: 2) { Float(sin(2 * Double.pi * 440 * Double($0) / 48000)) * Float($0) / 96000 }
        let rev = try mix(audioProject(rising, dur: 2, reverse: true)).samples
        func rms(_ r: Range<Int>) -> Double { sqrt(rev[r].reduce(0) { $0 + Double($1 * $1) } / Double(r.count)) }
        XCTAssertGreaterThan(rms(0..<24000), rms(72000..<96000) * 3)
    }

    func testFreezeClipIsSilentAndDoesNotCountAsSource() throws {
        let tone = try writeWav("toneF.wav", seconds: 1) { Float(0.5 * sin(2 * Double.pi * 440 * Double($0) / 48000)) }
        var v = video("f", dur: 1); v.src = tone.path; v.freeze = true
        let res = try AudioMixer.mixdownDetailed(project: project([v]), to: tmp.appendingPathComponent("silent.caf"))
        XCTAssertEqual(res.sourceCount, 0)
    }

    func testUnprocessableAudioFallsBackToSilenceNotCrash() throws {
        // 動画クリップで音声トラックが無い素材: 速度がかかっていても無音になるだけ
        let url = try makeIndexVideo(frames: 30)
        var v = video("v", dur: 1, speed: 2); v.src = url.path
        let res = try AudioMixer.mixdownDetailed(project: project([v]), to: tmp.appendingPathComponent("noaudio.caf"))
        XCTAssertEqual(res.sourceCount, 0)
    }
}
