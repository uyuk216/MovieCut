import XCTest
import AVFoundation
@testable import MovieCutCore

/// BGM の自動ダッキング: 包絡線の計算、ミキサーで測った音の減り方、ファイル形式、編集の計算。
final class DuckingTests: XCTestCase {
    let sr = 48000.0
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("duck-tests-\(UUID().uuidString)")
    override func setUpWithError() throws { try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    func dB(_ v: Double) -> Double { 20 * log10(max(v, 1e-12)) }
    func rms(_ x: ArraySlice<Float>) -> Double { (x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(1, x.count))).squareRoot() }

    // MARK: 包絡線の計算

    func testNoVoicesIsUnity() {
        let g = Ducking.gains(startFrame: 0, count: 1000, sr: sr, spans: [], duck: Duck())
        XCTAssertEqual(g, [Float](repeating: 1, count: 1000))
        XCTAssertEqual(Ducking.depth(at: 5, spans: [], attack: 0.1, release: 0.4), 0)
    }

    func testDepthAttackHoldRelease() {
        let spans = [Ducking.Span(start: 2, end: 4)]
        // 声の頭の attack(0.5 秒)前から下がり始め、頭で全部下がる
        XCTAssertEqual(Ducking.depth(at: 1.4, spans: spans, attack: 0.5, release: 1), 0)
        XCTAssertEqual(Ducking.depth(at: 1.5, spans: spans, attack: 0.5, release: 1), 0, accuracy: 1e-9)
        XCTAssertEqual(Ducking.depth(at: 1.75, spans: spans, attack: 0.5, release: 1), 0.5, accuracy: 1e-9)
        XCTAssertEqual(Ducking.depth(at: 2, spans: spans, attack: 0.5, release: 1), 1, accuracy: 1e-9)
        XCTAssertEqual(Ducking.depth(at: 3, spans: spans, attack: 0.5, release: 1), 1)
        XCTAssertEqual(Ducking.depth(at: 4, spans: spans, attack: 0.5, release: 1), 1, accuracy: 1e-9)
        // 声の終わりから release かけて戻る
        XCTAssertEqual(Ducking.depth(at: 4.5, spans: spans, attack: 0.5, release: 1), 0.5, accuracy: 1e-9)
        XCTAssertEqual(Ducking.depth(at: 5, spans: spans, attack: 0.5, release: 1), 0, accuracy: 1e-9)
        XCTAssertEqual(Ducking.depth(at: 6, spans: spans, attack: 0.5, release: 1), 0)
    }

    func testGainDbIsLinearInDepth() {
        XCTAssertEqual(Ducking.gain(depth: 1, amountDb: -12), Float(pow(10, -12.0 / 20)), accuracy: 1e-6)
        XCTAssertEqual(Ducking.gain(depth: 0.5, amountDb: -12), Float(pow(10, -6.0 / 20)), accuracy: 1e-6)
        XCTAssertEqual(Ducking.gain(depth: 0, amountDb: -12), 1)
    }

    func testOverlappingVoicesMergeAndNeverDeeperThanAmount() {
        let merged = Ducking.merged([.init(start: 5, end: 7), .init(start: 1, end: 3), .init(start: 2.5, end: 4), .init(start: 4, end: 4.5)])
        XCTAssertEqual(merged, [.init(start: 1, end: 4.5), .init(start: 5, end: 7)])
        // 重なっていても下げる量は 1 回分(足し算にならない)
        let g = Ducking.gains(startFrame: 0, count: Int(8 * sr), sr: sr, spans: [.init(start: 1, end: 3), .init(start: 2, end: 4)], duck: Duck(amount: -12, attack: 0.1, release: 0.3))
        XCTAssertEqual(g.min()!, Float(pow(10, -12.0 / 20)), accuracy: 1e-6)
        // 声と声の間が release より短ければ、戻りきらずに次の声で下がる
        let gaps = Ducking.gains(startFrame: 0, count: Int(4 * sr), sr: sr, spans: [.init(start: 1, end: 1.5), .init(start: 1.7, end: 2.2)], duck: Duck(amount: -12, attack: 0.1, release: 0.5))
        let mid = gaps[Int(1.6 * sr)]
        XCTAssertLessThan(mid, 0.6)    // 谷間でも十分に下がったまま(約 −9 dB 以上)
    }

    func testGainsAreChunkIndependent() {
        let spans = [Ducking.Span(start: 3, end: 5), Ducking.Span(start: 9.5, end: 10.5)]
        let d = Duck(amount: -10, attack: 0.3, release: 0.7)
        let whole = Ducking.gains(startFrame: 0, count: Int(12 * sr), sr: sr, spans: spans, duck: d)
        var parts: [Float] = []
        let chunk = Int(sr) * 10
        var s = 0
        while s < whole.count { let n = min(chunk, whole.count - s); parts += Ducking.gains(startFrame: s, count: n, sr: sr, spans: spans, duck: d); s += n }
        XCTAssertEqual(whole, parts)
    }

    func testVoiceSpansOnlyAudibleVoices() {
        var p = Project(); p.tracks = [Track(name: "a"), Track(name: "b"), Track(name: "c")]
        func voice(_ s: Double, _ d: Double, src: String? = "/x.wav", vol: Double? = nil) -> Clip {
            var c = Clip(); c.type = .voice; c.start = s; c.duration = d; c.src = src; c.volume = vol; return c
        }
        p.tracks[0].clips = [voice(1, 2), voice(2.5, 1), voice(10, 1, src: nil), voice(12, 1, vol: 0)]
        var other = Clip(); other.type = .audio; other.src = "/b.wav"; other.start = 20; other.duration = 3
        p.tracks[1].clips = [other]
        p.tracks[2].muted = true
        p.tracks[2].clips = [voice(30, 2)]
        XCTAssertEqual(Ducking.voiceSpans(in: p), [.init(start: 1, end: 3.5)])
    }

    // MARK: ミキサー経由

    func writeTone(_ name: String, f: Double, amp: Float, seconds: Double) throws -> String {
        let url = tmp.appendingPathComponent(name)
        try AudioFixture.writeSine(url, sampleRate: 48000, channels: 2, frequency: f, segments: [(seconds, amp)])
        return url.path
    }

    func mix(_ p: Project, _ name: String) throws -> [Float] {
        let url = tmp.appendingPathComponent(name)
        try AudioMixer.mixdown(project: p, assets: RenderAssets(), to: url)
        let f = try AVAudioFile(forReading: url)
        let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
        try f.read(into: buf)
        return Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength)))
    }

    /// 12 秒の BGM(440 Hz)と、4〜7 秒の声(1 kHz)。
    func duckProject(duck: Duck?, withVoice: Bool = true) throws -> Project {
        var bgm = Clip(); bgm.type = .audio; bgm.src = try writeTone("bgm.wav", f: 440, amp: 0.2, seconds: 12)
        bgm.start = 0; bgm.duration = 12; bgm.srcDuration = 12; bgm.volume = 1; bgm.duck = duck
        var p = Project(); p.tracks = [Track(name: "BGM"), Track(name: "声")]
        p.tracks[0].clips = [bgm]
        if withVoice {
            var v = Clip(); v.type = .voice; v.src = try writeTone("voice.wav", f: 1000, amp: 0.2, seconds: 3)
            v.start = 4; v.duration = 3; v.srcDuration = 3; v.volume = 1
            p.tracks[1].clips = [v]
        }
        return p
    }

    func testMixerReducesBgmDuringVoiceByAmount() throws {
        // BGM だけの基準 → 声の区間で amount だけ下がり、声の外は元のまま。声は混ざるので、声なしの BGM と BGM+声を引き算して BGM 成分を取る
        let plain = try mix(duckProject(duck: nil, withVoice: false), "plain.caf")
        let ducked = try mix(duckProject(duck: Duck(amount: -12, attack: 0.2, release: 0.5), withVoice: false), "novoice.caf")
        XCTAssertEqual(ducked, plain, "声が無ければ、ダッキングは何も変えない(単位ゲイン)")

        let off = try mix(duckProject(duck: nil), "off.caf")
        let on = try mix(duckProject(duck: Duck(amount: -12, attack: 0.2, release: 0.5)), "on.caf")
        // BGM 成分 = ミックス − 声だけ。声は同じなので、(on − off + 無ダックの BGM) ではなく、差分 = ダックされた BGM − 元の BGM
        let seg: (Double, Double) -> Range<Int> = { Int($0 * 48000)..<Int($1 * 48000) }
        // 声の区間(4.5〜6.5 秒、完全に下がっている所)
        let bgmOff = plain[seg(4.5, 6.5)]
        let diff = zip(on[seg(4.5, 6.5)], off[seg(4.5, 6.5)]).map { $0 - $1 }       // = (duckedBGM − BGM)
        let ducked_ = zip(diff, bgmOff).map { $0 + $1 }                              // = duckedBGM
        let reduction = dB(rms(ducked_[...])) - dB(rms(bgmOff))
        XCTAssertEqual(reduction, -12, accuracy: 0.3)
        // 声の外(1〜3 秒、8 秒以降)は変わらない
        XCTAssertEqual(on[seg(1, 3)].elementsEqual(off[seg(1, 3)]), true)
        XCTAssertEqual(on[seg(8.5, 11)].elementsEqual(off[seg(8.5, 11)]), true)
        // アタック: 声の頭(4 秒)の 0.2 秒前から下がり始める → 3.9 秒は半分(−6 dB 付近)
        let at39 = zip(on[seg(3.85, 3.95)], off[seg(3.85, 3.95)]).map { $0 - $1 }
        let r39 = dB(rms(zip(at39, plain[seg(3.85, 3.95)]).map { $0 + $1 }[...])) - dB(rms(plain[seg(3.85, 3.95)]))
        XCTAssertEqual(r39, -6, accuracy: 1.5)
        // リリース: 声の終わり(7 秒)から 0.5 秒かけて戻る → 7.25 秒は約 −6 dB、7.5 秒以降は元通り
        let at725 = zip(on[seg(7.2, 7.3)], off[seg(7.2, 7.3)]).map { $0 - $1 }
        let r725 = dB(rms(zip(at725, plain[seg(7.2, 7.3)]).map { $0 + $1 }[...])) - dB(rms(plain[seg(7.2, 7.3)]))
        XCTAssertEqual(r725, -6, accuracy: 1.5)
        XCTAssertEqual(on[seg(7.6, 8.5)].elementsEqual(off[seg(7.6, 8.5)]), true)
    }

    func testDisabledDuckAndNonAudioClipsAreUntouched() throws {
        let off = try mix(duckProject(duck: nil), "a.caf")
        XCTAssertEqual(try mix(duckProject(duck: Duck(amount: -20, enabled: false)), "b.caf"), off)
        // ボイスクリップに duck があっても無視(BGM だけが対象)
        var p = try duckProject(duck: nil)
        p.tracks[1].clips[0].duck = Duck(amount: -30)
        XCTAssertEqual(try mix(p, "c.caf"), off)
    }

    func testMuteAndSoloVoiceTrackRemovesDucking() throws {
        var p = try duckProject(duck: Duck(amount: -12))
        p.tracks[1].muted = true      // 声が鳴らないなら、BGM は下げない
        let plain = try mix(duckProject(duck: nil, withVoice: false), "p.caf")
        XCTAssertEqual(try mix(p, "m.caf"), plain)
    }

    // MARK: ファイル形式

    func fixtureURL(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "ymproj", subdirectory: "Fixtures"))
    }

    func testFixtureRoundTrip() throws {
        let p1 = try Project.load(from: fixtureURL("duck"))
        let bgm = try XCTUnwrap(p1.allClips.first { $0.id == "bgm" })
        XCTAssertEqual(bgm.duck?.amountDb, -15)
        XCTAssertEqual(bgm.duck?.attackSeconds, 0.2)
        XCTAssertEqual(bgm.duck?.releaseSeconds, 0.8)
        XCTAssertEqual(bgm.duck?.extra["futureDuckKey"], .string("keep"))
        XCTAssertTrue(bgm.hasDuck)
        let off = try XCTUnwrap(p1.allClips.first { $0.id == "bgmOff" })
        XCTAssertFalse(off.hasDuck)
        XCTAssertEqual(off.duck?.amountDb, -9)       // 切っても設定値は残る
        let def = try XCTUnwrap(p1.allClips.first { $0.id == "bgmDefault" })
        XCTAssertTrue(def.hasDuck)
        XCTAssertEqual(def.duck?.amountDb, -12); XCTAssertEqual(def.duck?.attackSeconds, 0.15); XCTAssertEqual(def.duck?.releaseSeconds, 0.5)
        let bad = try XCTUnwrap(p1.allClips.first { $0.id == "bgmBad" })
        XCTAssertNil(bad.duck)
        XCTAssertEqual(bad.extra["duck"], .string("not an object"))

        let d1 = try p1.encoded()
        let p2 = try Project.decode(from: d1)
        XCTAssertEqual(p1, p2)
        XCTAssertEqual(try p2.encoded(), d1)
    }

    func testDuckIsWrittenOnlyWhenSet() throws {
        var c = Clip(); c.type = .audio; c.src = "/x.wav"; c.duration = 5
        var p = Project(); p.tracks[0].clips = [c]
        XCTAssertFalse(String(decoding: try p.encoded(), as: UTF8.self).contains("duck"))
        XCTAssertTrue(DuckEditing.setEnabled(&p.tracks[0].clips[0], true))
        XCTAssertTrue(String(decoding: try p.encoded(), as: UTF8.self).contains("\"duck\""))
        XCTAssertTrue(DuckEditing.setEnabled(&p.tracks[0].clips[0], false))     // 設定が無いので外れる
        XCTAssertNil(p.tracks[0].clips[0].duck)
        XCTAssertFalse(String(decoding: try p.encoded(), as: UTF8.self).contains("duck"))
    }

    func testExistingFixturesNeverGainDuck() throws {
        for name in ["audiofx", "speed", "rich", "timeline", "transitions", "effects", "keyframes", "subtitles"] {
            let data = try Data(contentsOf: fixtureURL(name))
            let p = try Project.decode(from: data)
            XCTAssertFalse(String(decoding: try p.encoded(), as: UTF8.self).contains("\"duck\""), name)
        }
    }

    // MARK: 編集

    func testEditing() {
        var c = Clip(); c.type = .audio; c.src = "/x.wav"; c.duration = 5
        XCTAssertTrue(DuckEditing.toggle(&c)); XCTAssertTrue(c.hasDuck)
        XCTAssertTrue(DuckEditing.setAmount(&c, -20.04)); XCTAssertEqual(c.duck?.amount, -20)
        XCTAssertFalse(DuckEditing.setAmount(&c, -20))                       // 同じ値 → 変化なし
        XCTAssertTrue(DuckEditing.setAmount(&c, -99)); XCTAssertEqual(c.duck?.amount, -40)   // 範囲に収める
        XCTAssertTrue(DuckEditing.setAttack(&c, 0.234)); XCTAssertEqual(c.duck?.attack, 0.23)
        XCTAssertTrue(DuckEditing.setRelease(&c, 100)); XCTAssertEqual(c.duck?.release, 5)
        XCTAssertTrue(DuckEditing.toggle(&c)); XCTAssertFalse(c.hasDuck); XCTAssertNotNil(c.duck)   // 切っても設定は残る
        XCTAssertFalse(DuckEditing.setEnabled(&c, false))                    // もう切れている
        XCTAssertTrue(DuckEditing.toggle(&c)); XCTAssertEqual(c.duck?.amount, -40)
        // 音声クリップだけ(ボイス・動画・フリーズ・画像は対象外)
        for t in [ClipType.voice, .video, .image, .text] {
            var o = Clip(); o.type = t; o.src = "/x"
            XCTAssertFalse(DuckEditing.supports(o)); XCTAssertFalse(DuckEditing.toggle(&o)); XCTAssertNil(o.duck)
        }
    }

    func testCacheTokenChangesWithSettings() {
        XCTAssertNotEqual(Duck(amount: -12).cacheToken, Duck(amount: -18).cacheToken)
        XCTAssertNotEqual(Duck(attack: 0.1).cacheToken, Duck(attack: 0.3).cacheToken)
        XCTAssertEqual(Duck().cacheToken, Duck(amount: -12, attack: 0.15, release: 0.5).cacheToken)
    }
}
