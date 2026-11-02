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
