import XCTest
@testable import MovieCutCore

/// 音量包絡線の直接編集(監査 #64 / W3-23): 点の追加・移動・削除、素材化、縦位置との対応、
/// そしてミックスへの反映(既存 VolumeEnvelope 経由)。
final class VolumeEnvelopeEditingTests: XCTestCase {
    private func audioClip(volume: Double? = nil, duration: Double = 4) -> Clip {
        var c = Clip(); c.type = .audio; c.duration = duration; c.volume = volume
        return c
    }

    func testSupportsOnlyAudioCapableTypes() {
        var a = Clip(); a.type = .audio; XCTAssertTrue(VolumeEnvelopeEditing.supports(a))
        var v = Clip(); v.type = .voice; XCTAssertTrue(VolumeEnvelopeEditing.supports(v))
        var mv = Clip(); mv.type = .video; XCTAssertTrue(VolumeEnvelopeEditing.supports(mv))
        var img = Clip(); img.type = .image; XCTAssertFalse(VolumeEnvelopeEditing.supports(img))
        var txt = Clip(); txt.type = .text; XCTAssertFalse(VolumeEnvelopeEditing.supports(txt))
    }

    func testFirstAddMaterializesAnchorsWithoutChangingGain() {
        var c = audioClip(volume: 0.8)
        let idx = VolumeEnvelopeEditing.addPoint(&c, at: 2, gain: 0.2)
        XCTAssertEqual(idx, 1)
        let pts = VolumeEnvelopeEditing.points(c)
        XCTAssertEqual(pts.count, 3)
        XCTAssertEqual(pts[0].t, 0); XCTAssertEqual(pts[0].v, 0.8)
        XCTAssertEqual(pts[2].t, 4); XCTAssertEqual(pts[2].v, 0.8)
        // 端は従来どおり 0.8、点の上は 0.2、その間は直線補間(1 秒地点は中間の 0.5)
        XCTAssertEqual(VolumeEnvelopeEditing.gain(c, at: 0), 0.8, accuracy: 1e-9)
        XCTAssertEqual(VolumeEnvelopeEditing.gain(c, at: 1), 0.5, accuracy: 1e-9)
        XCTAssertEqual(VolumeEnvelopeEditing.gain(c, at: 2), 0.2, accuracy: 1e-9)
        XCTAssertEqual(VolumeEnvelopeEditing.gain(c, at: 4), 0.8, accuracy: 1e-9)
    }

    func testAddClampsTimeAndGainAndReplacesNearSameTime() {
        var c = audioClip()
        _ = VolumeEnvelopeEditing.addPoint(&c, at: 99, gain: 99)
        var pts = VolumeEnvelopeEditing.points(c)
        XCTAssertEqual(pts.last?.t, 4); XCTAssertEqual(pts.last?.v, 2)
        let n = pts.count
        _ = VolumeEnvelopeEditing.addPoint(&c, at: 4, gain: 0.5)
        pts = VolumeEnvelopeEditing.points(c)
        XCTAssertEqual(pts.count, n, "同じ時刻の点は増えず置き換わる")
        XCTAssertEqual(pts.last?.v, 0.5)
    }

    func testMovePointCannotCrossNeighbors() {
        var c = audioClip()
        _ = VolumeEnvelopeEditing.addPoint(&c, at: 1, gain: 1)
        _ = VolumeEnvelopeEditing.addPoint(&c, at: 3, gain: 1)
        let pts = VolumeEnvelopeEditing.points(c)   // 0,1,3,4 の 4 点
        XCTAssertEqual(pts.count, 4)
        XCTAssertTrue(VolumeEnvelopeEditing.movePoint(&c, index: 1, toTime: 3.5, gain: 0.4))
        let moved = VolumeEnvelopeEditing.points(c)
        XCTAssertLessThan(moved[1].t, moved[2].t, "次の点は越えられない")
        XCTAssertEqual(moved[1].v, 0.4)
        XCTAssertFalse(VolumeEnvelopeEditing.movePoint(&c, index: 99, toTime: 0, gain: 0))
    }

    func testRemoveLastPointRestoresStaticVolume() {
        var c = audioClip(volume: 1)
        c.keyframes["volume"] = [Keyframe(t: 1, v: 0.3)]
        XCTAssertTrue(VolumeEnvelopeEditing.removePoint(&c, index: 0))
        XCTAssertNil(c.keyframes["volume"])
        XCTAssertEqual(c.volume, 0.3, "最後の点を消しても聞こえ方はその点の値で保たれる")
        XCTAssertFalse(VolumeEnvelopeEditing.removePoint(&c, index: 0))
    }

    func testFractionGainMapping() {
        XCTAssertEqual(VolumeEnvelopeEditing.fraction(forGain: 0), 0)
        XCTAssertEqual(VolumeEnvelopeEditing.fraction(forGain: 1), 0.5)
        XCTAssertEqual(VolumeEnvelopeEditing.fraction(forGain: 2), 1)
        XCTAssertEqual(VolumeEnvelopeEditing.gain(forFraction: 0.25), 0.5)
        XCTAssertEqual(VolumeEnvelopeEditing.gain(forFraction: 9), 2, "範囲外は収める")
    }

    func testEditedEnvelopeReachesMixerGain() throws {
        // 編集した包絡線が、ミックスで使う VolumeEnvelope の倍率にそのまま届くこと
        var c = audioClip(volume: 1)
        _ = VolumeEnvelopeEditing.addPoint(&c, at: 1, gain: 0)
        let env = try XCTUnwrap(VolumeEnvelope(c.keyframes["volume"], sr: 100))
        XCTAssertEqual(env.gain(at: 0), 1, accuracy: 0.001)     // 頭は素材化した基準点どおり
        XCTAssertEqual(env.gain(at: 100), 0, accuracy: 0.001)   // 1 秒の点で無音
        XCTAssertEqual(env.gain(at: 400), 1, accuracy: 0.001)   // 終わりは基準点どおり
    }

    func testUnsupportedClipIsUntouched() {
        var c = Clip(); c.type = .image; c.duration = 2
        XCTAssertNil(VolumeEnvelopeEditing.addPoint(&c, at: 1, gain: 1))
        XCTAssertTrue(c.keyframes.isEmpty)
    }
}
