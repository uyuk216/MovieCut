import XCTest
import AVFoundation
@testable import MovieCutCore

/// speed が保存されたボイスクリップを、ミックス(書き出し)で伸縮して尺に収める回帰テスト。
/// 素材は全長 2.6 秒 = [0〜2.2 秒 無音, 2.2〜2.6 秒 トーン(0.5)] の「末尾に印のある」形。
final class VoiceSpeedMixTests: XCTestCase {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("voice-speed-\(UUID().uuidString)")
    override func setUpWithError() throws { try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    func markedSource() throws -> String {
        let u = tmp.appendingPathComponent("voice.wav")
        try AudioFixture.writeSine(u, segments: [(2.2, 0), (0.4, 0.5)])
        return u.path
    }

    func voice(_ src: String, duration: Double, speed: Double?) -> Clip {
        var c = Clip(); c.type = .voice; c.src = src; c.start = 0; c.duration = duration; c.speed = speed
        return c
    }

    func mix(_ c: Clip) throws -> URL {
        var p = Project()
        var t = Track(name: "V"); t.clips = [c]; p.tracks = [t]
        let out = tmp.appendingPathComponent("mix-\(UUID().uuidString).caf")
        _ = try AudioMixer.mixdownDetailed(project: p, to: out)
        return out
    }

    func testSpeed13FitsTailMarkInside() throws {
        let out = try mix(voice(try markedSource(), duration: 2.6 / 1.3, speed: 1.3))
        XCTAssertGreaterThan(try AudioFixture.peak(out, from: 1.8, to: 1.98), 0.3)   // 印(原音 2.2 秒以降)が終わり際に入る
        XCTAssertLessThan(try AudioFixture.peak(out, from: 0.1, to: 1.5), 0.01)       // 前半は無音のまま
    }

    func testSpeedHalfFitsTailMarkInside() throws {
        let out = try mix(voice(try markedSource(), duration: 5.2, speed: 0.5))
        XCTAssertGreaterThan(try AudioFixture.peak(out, from: 4.8, to: 5.15), 0.3)
        XCTAssertLessThan(try AudioFixture.peak(out, from: 0.1, to: 4.2), 0.01)
    }

    func testNoSpeedKeepsLegacyBehavior() throws {
        let src = try markedSource()
        let cut = try mix(voice(src, duration: 2.0, speed: nil))   // 従来どおり末尾は切れる(印は入らない)
        XCTAssertLessThan(try AudioFixture.peak(cut, from: 0.1, to: 1.95), 0.01)
        let full = try mix(voice(src, duration: 2.6, speed: nil))  // 印は原音の位置
        XCTAssertGreaterThan(try AudioFixture.peak(full, from: 2.25, to: 2.55), 0.3)
        XCTAssertLessThan(try AudioFixture.peak(full, from: 0.1, to: 2.1), 0.01)
        // speed = 1 も未設定と同じ(伸縮なし)
        let one = try mix(voice(src, duration: 2.0, speed: 1))
        XCTAssertLessThan(try AudioFixture.peak(one, from: 0.1, to: 1.95), 0.01)
    }

    func testSpeed13FitsTailMarkInsideSurround() throws {
        var p = Project()
        var t = Track(name: "V"); t.clips = [voice(try markedSource(), duration: 2.6 / 1.3, speed: 1.3)]; p.tracks = [t]
        let out = tmp.appendingPathComponent("mix51-\(UUID().uuidString).caf")
        _ = try AudioMixer.mixdownSurround51(project: p, to: out)
        XCTAssertGreaterThan(try AudioFixture.peak(out, from: 1.8, to: 1.98), 0.3)   // 印は L/R に入る(peak は全チャンネルの最大)
        XCTAssertLessThan(try AudioFixture.peak(out, from: 0.1, to: 1.5), 0.01)       // 前半は無音のまま
    }

    func testVoiceStretchSpeedPredicate() {
        var c = Clip(); c.type = .voice
        XCTAssertNil(c.voiceStretchSpeed); XCTAssertFalse(c.hasVoiceStretch)
        c.speed = 1; XCTAssertNil(c.voiceStretchSpeed)
        c.speed = 1.3; XCTAssertEqual(c.voiceStretchSpeed, 1.3)
        c.speed = 100; XCTAssertEqual(c.voiceStretchSpeed, 4)   // 範囲に整える
        c.speed = Double.nan; XCTAssertNil(c.voiceStretchSpeed)
        // 他の種類・既存の定義は変えない
        c.speed = 1.3
        XCTAssertEqual(c.effectiveSpeed, 1); XCTAssertFalse(c.hasAudioRemap)
        c.type = .audio; XCTAssertNil(c.voiceStretchSpeed)
    }
}
