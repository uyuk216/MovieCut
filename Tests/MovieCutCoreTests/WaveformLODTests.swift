import XCTest
@testable import MovieCutCore

/// 波形のピーク → 縦線の変換(粗い段つき)。総当たりと同じ結果になること、縮小表示でも速いこと。
final class WaveformLODTests: XCTestCase {
    private func brute(_ p: [Float], from: Double, to: Double, count: Int) -> [Float] {
        let rev = from > to
        let lo = min(from, to), hi = max(from, to), span = hi - lo
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let a = lo + span * Double(i) / Double(count), b = lo + span * Double(i + 1) / Double(count)
            var i0 = Int((a * 100).rounded(.down)), i1 = Int((b * 100).rounded(.up)) - 1
            i0 = max(0, i0); i1 = min(p.count - 1, max(i0, i1))
            guard i0 <= i1, i0 < p.count else { continue }
            out[i] = p[i0...i1].max() ?? 0
        }
        return rev ? out.reversed() : out
    }

    func testColumnsMatchBruteForceAtAllZoomLevels() {
        var rng = SystemRandomNumberGenerator()
        let peaks = (0..<30_000).map { _ in Float.random(in: 0...1, using: &rng) }
        let w = WaveformPeaks(peaks: peaks)
        for (from, to, n) in [(0.0, 300.0, 7), (0.0, 300.0, 1000), (12.34, 250.5, 333), (5.0, 5.5, 200), (300.0, 0.0, 64), (100.0, 400.0, 50), (0.0, 3.0, 5000)] {
            XCTAssertEqual(w.columns(from: from, to: to, count: n), brute(peaks, from: from, to: to, count: n), "\(from)-\(to) x\(n)")
        }
    }

    func testMutatingPeaksRebuildsLevels() {
        var w = WaveformPeaks(peaks: [Float](repeating: 0.1, count: 1000))
        w.peaks[500] = 0.9
        XCTAssertEqual(w.columns(from: 0, to: 10, count: 1), [0.9])
    }

    func testClipColumnsFollowTrimAndSpeed() {
        // 0〜1 秒は小さく、1〜2 秒は大きい音。クリップは素材の 1〜2 秒を 2 倍速で見せる → 長さ 0.5 秒、全部大きい
        let w = WaveformPeaks(peaks: [Float](repeating: 0.1, count: 100) + [Float](repeating: 0.9, count: 100))
        var c = Clip(); c.type = .audio; c.src = "a.wav"; c.start = 0; c.duration = 0.5; c.offset = 1; c.speed = 2; c.srcDuration = 2
        XCTAssertEqual(w.columns(for: c, count: 4), [0.9, 0.9, 0.9, 0.9])
        c.offset = 0.5   // 0.5〜1.5 秒を見せる → 前半小さく後半大きい
        XCTAssertEqual(w.columns(for: c, count: 2), [0.1, 0.9])
    }

    /// 1 時間の素材(36 万ピーク)を 2000 本に縮めたときの 1 回あたりの時間(標準出力に出す)。
    func testZoomedOutColumnsAreCheap() {
        let w = WaveformPeaks(peaks: (0..<360_000).map { Float($0 % 97) / 97 })
        _ = w.columns(from: 0, to: 3600, count: 2000)
        let t0 = CFAbsoluteTimeGetCurrent()
        let runs = 50
        for _ in 0..<runs { _ = w.columns(from: 0, to: 3600, count: 2000) }
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000 / Double(runs)
        print("BENCH waveform columns 1h x2000: \(String(format: "%.3f", ms)) ms")
        XCTAssertLessThan(ms, 20)
    }
}
