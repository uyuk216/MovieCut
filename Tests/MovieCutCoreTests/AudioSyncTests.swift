import XCTest
@testable import MovieCutCore

/// 音による同期(相互相関)の純粋な計算。
final class AudioSyncTests: XCTestCase {
    /// 決まった擬似乱数の音(同じ並びを毎回作る)。
    private func noise(_ n: Int, seed: UInt64 = 7) -> [Float] {
        var s = seed
        return (0..<n).map { _ in
            s = s &* 6364136223846793005 &+ 1442695040888963407
            return Float(Double(s >> 11) / Double(1 << 53)) * 2 - 1
        }
    }

    func testFindsDelayedCopy() throws {
        let ref = noise(600)
        // target[n] = ref[n - 37]: target は 37 サンプル後ろにずれている
        let target = (0..<600).map { $0 >= 37 ? ref[$0 - 37] : 0 }
        let r = try XCTUnwrap(AudioSync.lag(reference: ref, target: target, maxLag: 80))
        XCTAssertEqual(r.lag, 37)
        XCTAssertGreaterThan(r.score, 0.9)
    }

    func testFindsEarlierTargetAsNegativeLag() throws {
        let ref = noise(600, seed: 3)
        // target[n] = ref[n + 12]: target は 12 サンプル前に出ている
        let target = (0..<600).map { $0 + 12 < 600 ? ref[$0 + 12] : 0 }
        let r = try XCTUnwrap(AudioSync.lag(reference: ref, target: target, maxLag: 80))
        XCTAssertEqual(r.lag, -12)
    }

    func testIdenticalInputsGiveZeroLag() throws {
        let ref = noise(300, seed: 11)
        let r = try XCTUnwrap(AudioSync.lag(reference: ref, target: ref, maxLag: 20))
        XCTAssertEqual(r.lag, 0)
        XCTAssertEqual(r.score, 1, accuracy: 1e-6)
    }

    func testSearchRangeIsLimited() throws {
        let ref = noise(600, seed: 5)
        let target = (0..<600).map { $0 >= 100 ? ref[$0 - 100] : 0 }
        // 100 サンプルのずれは、探す範囲 20 の外なので、範囲内の一番よい値になる(100 にはならない)
        let r = try XCTUnwrap(AudioSync.lag(reference: ref, target: target, maxLag: 20))
        XCTAssertLessThanOrEqual(abs(r.lag), 20)
    }

    func testNilForTooShortOrSilent() {
        XCTAssertNil(AudioSync.lag(reference: [1], target: [1, 2], maxLag: 3))
        XCTAssertNil(AudioSync.lag(reference: [Float](repeating: 0, count: 50), target: noise(50), maxLag: 5), "無音は測れない")
        XCTAssertNil(AudioSync.lag(reference: [], target: [], maxLag: 5))
    }

    func testEnvelopeIsWindowRMSAndDropsPartialTail() {
        let x: [Float] = [1, -1, 1, -1, 0.5, 0.5, 0.5, 0.5, 9]
        let e = AudioSync.envelope(x, window: 4)
        XCTAssertEqual(e.count, 2, "末尾の半端は捨てる")
        XCTAssertEqual(e[0], 1, accuracy: 1e-6)
        XCTAssertEqual(e[1], 0.5, accuracy: 1e-6)
        XCTAssertEqual(AudioSync.envelope([], window: 4), [])
        XCTAssertEqual(AudioSync.envelope(x, window: 0).count, x.count, "窓は 1 以上に直す")
    }

    func testSecondsFromLag() {
        XCTAssertEqual(AudioSync.seconds(lag: 48000, sampleRate: 48000), 1, accuracy: 1e-9)
        XCTAssertEqual(AudioSync.seconds(lag: 5, sampleRate: 0), 0)
    }
}

/// 自動同期の編集(包絡 → ずれ → 開始位置)。
final class AudioSyncEditingTests: XCTestCase {
    private func clip(_ id: String, _ type: ClipType, start: Double, dur: Double = 10) -> Clip {
        var c = Clip(); c.id = id; c.type = type; c.src = "/tmp/x.wav"; c.start = start; c.duration = dur
        return c
    }
    private func project(_ clips: [[Clip]]) -> Project {
        var p = Project.new()
        p.tracks = clips.map { var t = Track(); t.clips = $0; return t }
        return p
    }

    func testPairNeedsExactlyOneVideoAndOneAudio() {
        let p = project([[clip("v", .video, start: 0)], [clip("a", .audio, start: 1)], [clip("a2", .audio, start: 2)]])
        XCTAssertNotNil(AudioSyncEditing.pair(in: p, ids: ["v", "a"]))
        XCTAssertNil(AudioSyncEditing.pair(in: p, ids: ["v"]))
        XCTAssertNil(AudioSyncEditing.pair(in: p, ids: ["a", "a2"]))
        XCTAssertNil(AudioSyncEditing.pair(in: p, ids: ["v", "a", "a2"]))
        XCTAssertNil(AudioSyncEditing.disabledReason(in: p, ids: ["v", "a"]))
        XCTAssertEqual(AudioSyncEditing.disabledReason(in: p, ids: ["v"]), AudioSyncEditing.selectionHint)
    }

    func testLagSecondsFromEnvelopes() throws {
        // 10 ms ごとの包絡。音声は映像より 37 窓(0.37 秒)後ろ
        var s: UInt64 = 5
        let v: [Float] = (0..<800).map { _ in s = s &* 6364136223846793005 &+ 1442695040888963407; return Float(s >> 40) / Float(1 << 24) }
        let a: [Float] = (0..<800).map { $0 >= 37 ? v[$0 - 37] : 0 }
        XCTAssertEqual(try XCTUnwrap(AudioSyncEditing.lagSeconds(video: v, audio: a)), 0.37, accuracy: 1e-9)
        XCTAssertNil(AudioSyncEditing.lagSeconds(video: v, audio: [Float](repeating: 0, count: 800)), "無音は合わせられない")
    }

    func testApplyMovesAudioStartAndNothingElse() throws {
        let p = project([[clip("v", .video, start: 5)], [clip("a", .audio, start: 3), clip("b", .audio, start: 20)]])
        guard case .moved(let q, let s) = AudioSyncEditing.apply(to: p, videoId: "v", audioId: "a", lag: 0.37) else { return XCTFail() }
        XCTAssertEqual(s, 4.63, accuracy: 1e-9)
        XCTAssertEqual(q.allClips.first { $0.id == "a" }!.start, 4.63, accuracy: 1e-9)
        XCTAssertEqual(q.allClips.first { $0.id == "b" }!.start, 20)
        XCTAssertEqual(q.allClips.first { $0.id == "v" }!.start, 5)
    }

    func testApplyEdgeCases() {
        let p = project([[clip("v", .video, start: 5)], [clip("a", .audio, start: 4.63)]])
        XCTAssertEqual(AudioSyncEditing.apply(to: p, videoId: "v", audioId: "a", lag: 0.37), .alreadySynced)
        if case .beforeZero = AudioSyncEditing.apply(to: p, videoId: "v", audioId: "a", lag: 6) {} else { XCTFail() }
        var locked = p; locked.tracks[1].clips[0].locked = true
        XCTAssertEqual(AudioSyncEditing.apply(to: locked, videoId: "v", audioId: "a", lag: 1), .locked)
        XCTAssertEqual(AudioSyncEditing.apply(to: p, videoId: "v", audioId: "zz", lag: 1), .invalid)
    }
}
