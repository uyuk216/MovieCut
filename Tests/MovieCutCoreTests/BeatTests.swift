import XCTest
@testable import MovieCutCore

/// ビート検出: 合成のクリック列(一定のテンポ)で、テンポとビートの位置が正しいこと。決定的であること。
final class BeatTests: XCTestCase {
    static let sr = 48000.0

    /// 1 拍ごとに 20 ms の 1 kHz の減衰音を置いた、無音の入る合成音(左チャンネル)。`first` は最初の拍の時刻(秒)。
    func clickTrack(bpm: Double, seconds: Double, first: Double = 0.1) -> [Float] {
        var x = [Float](repeating: 0, count: Int(seconds * Self.sr))
        let period = 60 / bpm
        var t = first
        while t < seconds {
            let s0 = Int((t * Self.sr).rounded())
            for j in 0..<960 where s0 + j < x.count {
                x[s0 + j] += Float(0.8 * sin(2 * Double.pi * 1000 * Double(j) / Self.sr) * exp(-Double(j) / 200))
            }
            t += period
        }
        return x
    }

    func grid(_ x: [Float]) -> BeatGrid? {
        let prof = SilenceDetector.profile(left: x, sampleRate: Self.sr)
        return BeatDetector.analyze(profile: prof)
    }

    func testClickTrackAt120BPMFindsTempoAndBeatsWithin30ms() throws {
        let g = try XCTUnwrap(grid(clickTrack(bpm: 120, seconds: 10)))
        XCTAssertEqual(g.bpm, 120, accuracy: 1.0, "テンポ")
        XCTAssertGreaterThan(g.confidence, 0.3)
        // 正解の拍(0.1 + 0.5k)の each に、一番近い検出の拍が 30 ms 以内
        let truth = (0..<20).map { 0.1 + 0.5 * Double($0) }
        for t in truth {
            let nearest = g.beats.map { abs($0 - t) }.min() ?? .infinity
            XCTAssertLessThanOrEqual(nearest, 0.03, "拍 \(t) s の近くに検出が無い(差 \(nearest))")
        }
        // 検出の拍は、正解から大きく外れない(余計な拍が無い)
        for b in g.beats {
            let nearest = truth.map { abs($0 - b) }.min() ?? .infinity
            XCTAssertLessThanOrEqual(nearest, 0.03, "拍 \(b) s は正解から外れている")
        }
    }

    func testOtherTemposAndPhasesAreFound() throws {
        for (bpm, first) in [(90.0, 0.25), (140.0, 0.05)] {
            let g = try XCTUnwrap(grid(clickTrack(bpm: bpm, seconds: 12, first: first)), "\(bpm) BPM")
            XCTAssertEqual(g.bpm, bpm, accuracy: 1.5, "\(bpm) BPM のテンポ")
            let nearest = g.beats.map { abs($0 - first) }.min() ?? .infinity
            XCTAssertLessThanOrEqual(nearest, 0.03, "\(bpm) BPM の最初の拍")
        }
    }

    func testDoesNotReportDoubleTempoForAClickTrack() throws {
        // 120 BPM の 0.5 秒と 1.0 秒の周期は同じくらい強い。短い方(120)を取る
        let g = try XCTUnwrap(grid(clickTrack(bpm: 120, seconds: 10)))
        XCTAssertGreaterThan(g.bpm, 110)
    }

    func testSilenceHasNoBeats() {
        XCTAssertNil(grid([Float](repeating: 0, count: Int(5 * Self.sr))))
        XCTAssertNil(BeatDetector.analyze(levels: [], duration: 0))
    }

    func testSameInputGivesTheSameGrid() throws {
        let x = clickTrack(bpm: 100, seconds: 8, first: 0.07)
        XCTAssertEqual(grid(x), grid(x), "決定的であること")
    }

    func testProjectTimesAreShiftedByClipStartAndCut() {
        let g = BeatGrid(bpm: 120, beats: [0, 0.5, 1.0, 1.5, 2.0], confidence: 1)
        var c = Clip(); c.start = 10; c.duration = 1.2
        XCTAssertEqual(BeatDetector.projectTimes(g, clip: c), [10, 10.5, 11.0])
    }

    func testMarkersFromBeatsSkipNearOnesAndUndoIsOneStep() {
        var p = Project()
        p.markers = [Marker(time: 1.0, name: "既存")]
        let r = MarkerEditing.addBeats(in: p, times: [0.5, 1.0, 1.001, 1.5], tolerance: 0.02)
        XCTAssertEqual(r.added, 2, "1.0 と 1.001 は既存に近いので足さない")
        XCTAssertEqual(r.project.markers.map(\.time), [0.5, 1.0, 1.5])
        XCTAssertEqual(r.project.markers.last?.name, "ビート")
        let none = MarkerEditing.addBeats(in: p, times: [1.0], tolerance: 0.02)
        XCTAssertEqual(none.added, 0)
        XCTAssertEqual(none.project, p, "足すものが無いときは同じ内容")
    }
}
