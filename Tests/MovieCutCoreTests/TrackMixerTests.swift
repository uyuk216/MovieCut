import XCTest
import AVFoundation
@testable import MovieCutCore

/// トラックミキサー(レイヤー単位の音量・パン・ミュート・ソロ)のテスト。
/// ミックス実音の確認には AudioMixerTests.swift の `AudioFixture` を使う。
final class TrackMixerTests: XCTestCase {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("trackmixer-tests-\(UUID().uuidString)")
    override func setUpWithError() throws { try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    // MARK: ヘルパー

    func clip(src: String, duration: Double = 1, volume: Double? = nil) -> Clip {
        var c = Clip(); c.type = .audio; c.src = src; c.start = 0; c.duration = duration; c.volume = volume
        return c
    }

    func project(_ tracks: [[Clip]]) -> Project {
        var p = Project()
        p.tracks = tracks.enumerated().map { i, cs in
            var t = Track(name: "L\(i)"); t.clips = cs; return t
        }
        return p
    }

    func sine(_ name: String = "a.wav", amp: Float = 0.2) throws -> String {
        let u = tmp.appendingPathComponent(name)
        try AudioFixture.writeSine(u, segments: [(1, amp)])
        return u.path
    }

    func mix(_ p: Project) throws -> URL {
        let out = tmp.appendingPathComponent("mix-\(UUID().uuidString).caf")
        _ = try AudioMixer.mixdown(project: p, assets: RenderAssets(), to: out)
        return out
    }

    /// 左右別のピーク([0.1, 0.9] 秒)
    func channelPeaks(_ url: URL) throws -> (l: Float, r: Float) {
        let s = try samples(url)
        let a = Int(0.1 * 48000), b = Int(0.9 * 48000)
        return (s[0][a..<b].map { abs($0) }.max() ?? 0, s[1][a..<b].map { abs($0) }.max() ?? 0)
    }

    /// 全サンプル(チャンネルごと)
    func samples(_ url: URL) throws -> [[Float]] {
        let f = try AVAudioFile(forReading: url)
        let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
        try f.read(into: buf)
        return (0..<Int(f.processingFormat.channelCount)).map { c in
            Array(UnsafeBufferPointer(start: buf.floatChannelData![c], count: Int(buf.frameLength)))
        }
    }

    func peak(_ url: URL) throws -> Float { try AudioFixture.peak(url, from: 0.1, to: 0.9) }

    // MARK: ゲイン計算

    func testTrackMixOfDefaultIsIdentity() {
        let m = TrackMix.of(Track(name: "x"))
        XCTAssertEqual(m, TrackMix.identity)
        XCTAssertTrue(m.isIdentity)
        XCTAssertFalse(Track(name: "x").hasTrackMix)
    }

    func testTrackMixGainValuesAndClamp() {
        func gain(_ v: Double?) -> Double { var t = Track(name: "x"); t.volume = v; return TrackMix.of(t).gain }
        XCTAssertEqual(gain(2), 2)
        XCTAssertEqual(gain(0), 0)
        XCTAssertEqual(gain(0.5), 0.5)
        XCTAssertEqual(gain(5), 2)
        XCTAssertEqual(gain(-1), 0)
        XCTAssertEqual(gain(.nan), 1)
        XCTAssertEqual(gain(.infinity), 1)
        var t = Track(name: "x"); t.volume = 0
        XCTAssertTrue(t.hasTrackMix)
        XCTAssertEqual(TrackMix.of(t).stereoGains.l, 0)
        XCTAssertEqual(TrackMix.of(t).stereoGains.r, 0)
    }

    func testTrackMixPanClamp() {
        func pan(_ v: Double?) -> Double { var t = Track(name: "x"); t.pan = v; return TrackMix.of(t).pan }
        XCTAssertEqual(pan(-3), -1)
        XCTAssertEqual(pan(3), 1)
        XCTAssertEqual(pan(0.25), 0.25)
        XCTAssertEqual(pan(.nan), 0)
    }

    func testDbConversion() {
        XCTAssertEqual(TrackMix.db(forGain: 1), 0, accuracy: 1e-9)
        XCTAssertEqual(TrackMix.db(forGain: 2), 6.0206, accuracy: 1e-3)
        XCTAssertEqual(TrackMix.db(forGain: 0), TrackMix.minDb)
        XCTAssertEqual(TrackMix.gain(forDb: 0), 1, accuracy: 1e-9)
        XCTAssertEqual(TrackMix.gain(forDb: -6.0206), 0.5, accuracy: 1e-3)
        XCTAssertEqual(TrackMix.gain(forDb: TrackMix.minDb), 0)
        XCTAssertEqual(TrackMix(gain: 0.5).db, TrackMix.db(forGain: 0.5))
    }

    // MARK: パン計算

    func testPanGains() {
        let c = TrackMix(gain: 0.5, pan: 0).stereoGains
        XCTAssertEqual(c.l, 0.5, accuracy: 1e-6)
        XCTAssertEqual(c.r, 0.5, accuracy: 1e-6)

        let left = TrackMix(gain: 1, pan: -1).stereoGains
        XCTAssertEqual(left.l, AudioPan.gains(-1).l)
        XCTAssertEqual(left.r, AudioPan.gains(-1).r)
        XCTAssertGreaterThan(left.l, 1)
        XCTAssertEqual(left.r, 0, accuracy: 1e-6)

        let right = TrackMix(gain: 1, pan: 1).stereoGains
        XCTAssertEqual(right.l, AudioPan.gains(1).l)
        XCTAssertEqual(right.r, AudioPan.gains(1).r)
        XCTAssertEqual(right.l, 0, accuracy: 1e-6)
        XCTAssertGreaterThan(right.r, 1)
    }

    func testStereoGainsEqualsGainTimesAudioPan() {
        for (g, p) in [(0.0, 0.0), (1.0, 0.3), (2.0, -0.7), (0.5, 1.0), (1.5, -1.0)] {
            let s = TrackMix(gain: g, pan: p).stereoGains
            let a = AudioPan.gains(p)
            XCTAssertEqual(s.l, Float(g) * a.l, accuracy: 1e-6, "g=\(g) p=\(p)")
            XCTAssertEqual(s.r, Float(g) * a.r, accuracy: 1e-6, "g=\(g) p=\(p)")
        }
    }

    // MARK: 入れ子合成

    func testNestedGainsMultiply() {
        let outer = TrackMixGains.identity.multiplied(by: TrackMix(gain: 0.5))
        XCTAssertEqual(outer.l, 0.5, accuracy: 1e-6)
        let both = outer.multiplied(by: TrackMix(gain: 0.5))
        XCTAssertEqual(both.l, 0.25, accuracy: 1e-6)
        XCTAssertEqual(both.r, 0.25, accuracy: 1e-6)
        XCTAssertFalse(both.isIdentity)
        XCTAssertTrue(TrackMixGains.identity.isIdentity)
        XCTAssertTrue(TrackMixGains.identity.multiplied(by: .identity).isIdentity)
    }

    func testNestedPansCompose() {
        let a = AudioPan.gains(-0.5), b = AudioPan.gains(0.25)
        let g = TrackMixGains.identity.multiplied(by: TrackMix(pan: -0.5)).multiplied(by: TrackMix(pan: 0.25))
        XCTAssertEqual(g.l, a.l * b.l, accuracy: 1e-6)
        XCTAssertEqual(g.r, a.r * b.r, accuracy: 1e-6)
        // 左いっぱい × 右いっぱい は互いに打ち消して無音
        let z = TrackMixGains.identity.multiplied(by: TrackMix(pan: -1)).multiplied(by: TrackMix(pan: 1))
        XCTAssertEqual(z.l, 0, accuracy: 1e-6)
        XCTAssertEqual(z.r, 0, accuracy: 1e-6)
    }

    func testAudibleClipsWithTrackMixTopLevel() throws {
        // トップレベルのレイヤー設定が各クリップに添えられる
        var p = project([[clip(src: "/a.wav")], [clip(src: "/b.wav")]])
        p.tracks[0].volume = 0.5
        p.tracks[1].pan = -1
        let r = CompoundEditing.audibleClipsWithTrackMix(in: p)
        XCTAssertEqual(r.count, 2)
        XCTAssertEqual(r[0].mix.l, 0.5, accuracy: 1e-6)
        XCTAssertEqual(r[0].mix.r, 0.5, accuracy: 1e-6)
        XCTAssertEqual(r[1].mix.l, AudioPan.gains(-1).l, accuracy: 1e-6)
        XCTAssertEqual(r[1].mix.r, 0, accuracy: 1e-6)
        // 既存の audibleClips とクリップ列が一致する
        XCTAssertEqual(r.map { $0.clip.src }, CompoundEditing.audibleClips(in: p).map { $0.src })
    }

    func testAudibleClipsWithTrackMixNestedCompoundMultiplies() throws {
        // 外 0.5 × 複合の中 0.5 = 0.25。中のミュートレイヤーは除かれる。
        var inner = Track(name: "in"); inner.volume = 0.5; inner.clips = [clip(src: "/in.wav")]
        var mutedInner = Track(name: "mu"); mutedInner.muted = true; mutedInner.clips = [clip(src: "/mu.wav")]
        var comp = Clip(); comp.id = "comp"; comp.type = .compound; comp.start = 0; comp.duration = 1
        comp.tracks = [inner, mutedInner]
        var p = project([[comp]])
        p.tracks[0].volume = 0.5
        let r = CompoundEditing.audibleClipsWithTrackMix(in: p)
        XCTAssertEqual(r.map { $0.clip.src }, ["/in.wav"])
        XCTAssertEqual(r[0].mix.l, 0.25, accuracy: 1e-6)
        XCTAssertEqual(r[0].mix.r, 0.25, accuracy: 1e-6)
    }

    func testAudibleClipsWithTrackMixDefaultIsIdentity() {
        let p = project([[clip(src: "/a.wav")], [clip(src: "/b.wav")]])
        for r in CompoundEditing.audibleClipsWithTrackMix(in: p) { XCTAssertTrue(r.mix.isIdentity) }
    }

    // MARK: ミュート/ソロ解決

    func testAudibleTracksMuteSoloResolution() {
        var p = project([[], [], []])
        XCTAssertEqual(TrackMixer.audibleTracks(in: p), [true, true, true])
        p.tracks[1].muted = true
        XCTAssertEqual(TrackMixer.audibleTracks(in: p), [true, false, true])
        p.tracks[2].solo = true  // ソロがあるときはソロだけ(1 はミュートのまま)
        XCTAssertEqual(TrackMixer.audibleTracks(in: p), [false, false, true])
        p.tracks[1].solo = true  // ミュート+ソロの競合はミュート優先
        XCTAssertEqual(TrackMixer.audibleTracks(in: p), [false, false, true])
        p.tracks[2].muted = true
        XCTAssertEqual(TrackMixer.audibleTracks(in: p), [false, false, false])
        XCTAssertEqual(TrackMixer.audibleTracks(in: p), p.tracks.map { p.isAudible($0) })
    }

    // MARK: 保存/復元

    func testTrackVolumePanJSONRoundTrip() throws {
        var t = Track(name: "x"); t.volume = 0.75; t.pan = -0.4
        let data = try JSONEncoder().encode(t)
        let back = try JSONDecoder().decode(Track.self, from: data)
        XCTAssertEqual(back.volume, 0.75)
        XCTAssertEqual(back.pan, -0.4)
        XCTAssertEqual(back, t)
        XCTAssertNil(back.extra["volume"])
        XCTAssertNil(back.extra["pan"])
    }

    func testUnsetTrackDoesNotWriteVolumePanKeys() throws {
        let data = try JSONEncoder().encode(Track(name: "x"))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(obj["volume"])
        XCTAssertNil(obj["pan"])
        let s = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(s.contains("\"volume\""))
        XCTAssertFalse(s.contains("\"pan\""))
    }

    func testDefaultValuesViaLayerEditingAreNotWritten() throws {
        var p = project([[]])
        p = try XCTUnwrap(LayerEditing.setTrackVolume(in: p, index: 0, 0.5))
        p = try XCTUnwrap(LayerEditing.setTrackPan(in: p, index: 0, 0.5))
        XCTAssertEqual(p.tracks[0].volume, 0.5)
        p = try XCTUnwrap(LayerEditing.setTrackVolume(in: p, index: 0, 1))
        p = try XCTUnwrap(LayerEditing.setTrackPan(in: p, index: 0, 0))
        XCTAssertNil(p.tracks[0].volume)
        XCTAssertNil(p.tracks[0].pan)
        let s = String(decoding: try p.encoded(), as: UTF8.self)
        XCTAssertFalse(s.contains("\"volume\""))
        XCTAssertFalse(s.contains("\"pan\""))
    }

    func testProjectRoundTripKeepsTrackMix() throws {
        var p = project([[], []])
        p.tracks[0].volume = 1.5
        p.tracks[1].pan = 0.3
        p.tracks[1].muted = true
        let p2 = try Project.decode(from: p.encoded())
        XCTAssertEqual(p, p2)
        XCTAssertEqual(p2.tracks[0].volume, 1.5)
        XCTAssertNil(p2.tracks[0].pan)
        XCTAssertEqual(p2.tracks[1].pan, 0.3)
        XCTAssertNil(p2.tracks[1].volume)
        XCTAssertEqual(p2.tracks[1].muted, true)
    }

    func testWrongTypedVolumeIsKeptInExtra() throws {
        let json = #"{"name":"x","volume":"loud","pan":"left","clips":[]}"#
        let t = try JSONDecoder().decode(Track.self, from: Data(json.utf8))
        XCTAssertNil(t.volume)
        XCTAssertNil(t.pan)
        XCTAssertEqual(t.extra["volume"], .string("loud"))
        XCTAssertEqual(t.extra["pan"], .string("left"))
        XCTAssertEqual(t.trackVolumeOrDefault, 1)
        XCTAssertEqual(t.trackPanOrDefault, 0)
    }

    // MARK: 編集

    func testSetTrackVolume() throws {
        let p = project([[]])
        XCTAssertNil(LayerEditing.setTrackVolume(in: p, index: 0, 1))  // 無変化
        XCTAssertNil(LayerEditing.setTrackVolume(in: p, index: 5, 0.5))  // 範囲外
        XCTAssertNil(LayerEditing.setTrackVolume(in: p, index: 0, .nan))
        let a = try XCTUnwrap(LayerEditing.setTrackVolume(in: p, index: 0, 0.5))
        XCTAssertEqual(a.tracks[0].volume, 0.5)
        XCTAssertNil(LayerEditing.setTrackVolume(in: a, index: 0, 0.5))  // 同じ値
        XCTAssertEqual(try XCTUnwrap(LayerEditing.setTrackVolume(in: p, index: 0, 9)).tracks[0].volume, 2)  // クランプ
        XCTAssertEqual(try XCTUnwrap(LayerEditing.setTrackVolume(in: p, index: 0, -3)).tracks[0].volume, 0)
        XCTAssertNil(try XCTUnwrap(LayerEditing.setTrackVolume(in: a, index: 0, 1)).tracks[0].volume)  // 標準は nil
        // extra に残った同名キーは掃除する
        var q = p; q.tracks[0].extra["volume"] = .string("x")
        let cleaned = try XCTUnwrap(LayerEditing.setTrackVolume(in: q, index: 0, 1))
        XCTAssertNil(cleaned.tracks[0].extra["volume"])
    }

    func testSetTrackPan() throws {
        let p = project([[]])
        XCTAssertNil(LayerEditing.setTrackPan(in: p, index: 0, 0))
        XCTAssertNil(LayerEditing.setTrackPan(in: p, index: -1, 0.5))
        XCTAssertNil(LayerEditing.setTrackPan(in: p, index: 0, .infinity))
        let a = try XCTUnwrap(LayerEditing.setTrackPan(in: p, index: 0, -0.5))
        XCTAssertEqual(a.tracks[0].pan, -0.5)
        XCTAssertNil(LayerEditing.setTrackPan(in: a, index: 0, -0.5))
        XCTAssertEqual(try XCTUnwrap(LayerEditing.setTrackPan(in: p, index: 0, 7)).tracks[0].pan, 1)
        XCTAssertEqual(try XCTUnwrap(LayerEditing.setTrackPan(in: p, index: 0, -7)).tracks[0].pan, -1)
        XCTAssertNil(try XCTUnwrap(LayerEditing.setTrackPan(in: a, index: 0, 0)).tracks[0].pan)
        var q = p; q.tracks[0].extra["pan"] = .string("x")
        XCTAssertNil(try XCTUnwrap(LayerEditing.setTrackPan(in: q, index: 0, 0)).tracks[0].extra["pan"])
    }

    func testSetMuted() throws {
        let p = project([[]])
        XCTAssertNil(LayerEditing.setMuted(in: p, index: 0, false))  // 無変化
        XCTAssertNil(LayerEditing.setMuted(in: p, index: 3, true))
        let a = try XCTUnwrap(LayerEditing.setMuted(in: p, index: 0, true))
        XCTAssertEqual(a.tracks[0].muted, true)
        XCTAssertNil(LayerEditing.setMuted(in: a, index: 0, true))
        let b = try XCTUnwrap(LayerEditing.setMuted(in: a, index: 0, false))
        XCTAssertNil(b.tracks[0].muted)  // true のときだけ保存
        XCTAssertFalse(String(decoding: try b.encoded(), as: UTF8.self).contains("\"muted\""))
    }

    func testResetTrackMix() throws {
        let p = project([[], []])
        XCTAssertNil(LayerEditing.resetTrackMix(in: p, index: 0))  // 無変化
        XCTAssertNil(LayerEditing.resetTrackMix(in: p, index: 9))
        var q = p
        q.tracks[0].volume = 0.3; q.tracks[0].pan = 0.8; q.tracks[0].muted = true; q.tracks[0].solo = true
        q.tracks[1].volume = 0.7
        let r = try XCTUnwrap(LayerEditing.resetTrackMix(in: q, index: 0))
        XCTAssertNil(r.tracks[0].volume); XCTAssertNil(r.tracks[0].pan)
        XCTAssertNil(r.tracks[0].muted); XCTAssertNil(r.tracks[0].solo)
        XCTAssertEqual(r.tracks[1].volume, 0.7)  // 他レイヤーは触らない
        XCTAssertNil(LayerEditing.resetTrackMix(in: r, index: 0))
    }

    // MARK: ミックス実音

    func testTrackVolumeScalesPeak() throws {
        let a = try sine()
        let base = try peak(mix(project([[clip(src: a)]])))
        XCTAssertEqual(base, 0.2, accuracy: 0.01)
        func peakWith(_ v: Double) throws -> Float {
            var p = project([[clip(src: a)]]); p.tracks[0].volume = v
            return try peak(mix(p))
        }
        XCTAssertEqual(try peakWith(0.5) / base, 0.5, accuracy: 0.02)
        XCTAssertEqual(try peakWith(0), 0)
        XCTAssertEqual(try peakWith(2) / base, 2, accuracy: 0.05)
    }

    func testTrackPanSilencesOneChannel() throws {
        let a = try sine()
        var p = project([[clip(src: a)]])
        p.tracks[0].pan = -1
        let l = try channelPeaks(mix(p))
        XCTAssertEqual(l.r, 0, accuracy: 1e-4)
        XCTAssertEqual(l.l, 0.2 * AudioPan.gains(-1).l, accuracy: 0.01)
        XCTAssertGreaterThan(l.l, 0.2)

        p.tracks[0].pan = 1
        let r = try channelPeaks(mix(p))
        XCTAssertEqual(r.l, 0, accuracy: 1e-4)
        XCTAssertEqual(r.r, 0.2 * AudioPan.gains(1).r, accuracy: 0.01)
        XCTAssertGreaterThan(r.r, 0.2)

        p.tracks[0].pan = 0.5  // 中間は左右とも鳴り、右が大きい
        let m = try channelPeaks(mix(p))
        XCTAssertGreaterThan(m.l, 0)
        XCTAssertGreaterThan(m.r, m.l)
    }

    func testDefaultTrackMixIsBitIdentical() throws {
        let a = try sine()
        let base = project([[clip(src: a)]])
        let ref = try samples(mix(base))

        // Track の volume/pan が nil のまま(別インスタンスでもう一度ミックス)
        XCTAssertEqual(try samples(mix(base)), ref)

        // LayerEditing で設定→既定に戻す
        var p = base
        p = try XCTUnwrap(LayerEditing.setTrackVolume(in: p, index: 0, 0.3))
        p = try XCTUnwrap(LayerEditing.setTrackPan(in: p, index: 0, -0.6))
        p = try XCTUnwrap(LayerEditing.setTrackVolume(in: p, index: 0, 1))
        p = try XCTUnwrap(LayerEditing.setTrackPan(in: p, index: 0, 0))
        XCTAssertEqual(p, base)
        XCTAssertEqual(try samples(mix(p)), ref)

        // 明示的に 1.0 / 0 を直接入れても同じ(identity の乗算は 1.0 ちょうど)
        var q = base
        q.tracks[0].volume = 1; q.tracks[0].pan = 0
        XCTAssertEqual(try samples(mix(q)), ref)

        // クリップ音量・フェードがある経路でも既定時は変わらない
        var c = clip(src: a, volume: 0.7); c.fadeIn = 0.2
        let withFx = project([[c]])
        let refFx = try samples(mix(withFx))
        var withFx2 = withFx; withFx2.tracks[0].volume = 1; withFx2.tracks[0].pan = 0
        XCTAssertEqual(try samples(mix(withFx2)), refFx)
        // 設定ありなら実際に変わる(上の一致が自明でないことの確認)
        var changed = base; changed.tracks[0].volume = 0.5
        XCTAssertNotEqual(try samples(mix(changed)), ref)
    }

    func testClipVolumeAndTrackVolumeCombine() throws {
        let a = try sine()
        let base = try peak(mix(project([[clip(src: a)]])))
        var p = project([[clip(src: a, volume: 0.5)]])
        p.tracks[0].volume = 0.5
        XCTAssertEqual(try peak(mix(p)) / base, 0.25, accuracy: 0.02)
    }

    func testSoloAndMuteAffectMix() throws {
        let a = try sine("a.wav"), b = try sine("b.wav", amp: 0.1)
        var p = project([[clip(src: a)], [clip(src: b)]])
        XCTAssertEqual(try peak(mix(p)), 0.3, accuracy: 0.02)  // 両方鳴る

        p.tracks[0].solo = true  // 片方ソロ → 他方は無音(ソロだけが鳴る)
        XCTAssertEqual(try peak(mix(p)), 0.2, accuracy: 0.01)
        p.tracks[0].solo = nil
        p.tracks[1].solo = true
        XCTAssertEqual(try peak(mix(p)), 0.1, accuracy: 0.01)

        p.tracks[1].solo = nil
        p.tracks[0].muted = true  // ミュートした側は除かれる
        XCTAssertEqual(try peak(mix(p)), 0.1, accuracy: 0.01)

        p.tracks[1].muted = true
        XCTAssertEqual(try peak(mix(p)), 0)
    }

    func testTrackMixAppliesPerTrackIndependently() throws {
        let a = try sine("a.wav"), b = try sine("b.wav")
        var p = project([[clip(src: a)], [clip(src: b)]])
        p.tracks[0].volume = 0  // 片方だけ無音にすると、もう片方だけ残る
        XCTAssertEqual(try peak(mix(p)), 0.2, accuracy: 0.01)
    }
}
