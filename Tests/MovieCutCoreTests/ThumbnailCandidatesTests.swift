import XCTest
import CoreGraphics
import ImageIO
@testable import MovieCutCore

/// サムネイル候補の自動選択: 鮮明さ・明るさ・顔の点数、上位 N 個の選び方(決定的・近すぎる時刻は飛ばす)、書き出し。
final class ThumbnailCandidatesTests: XCTestCase {
    struct FakeFaces: FaceDetecting {
        var rects: [CGRect]
        func faces(in image: CGImage) -> [CGRect] { rects }
    }

    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("thumbcand-\(UUID().uuidString)")
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    func checker(_ w: Int, _ h: Int, cell: Int) -> [UInt8] {
        (0..<(w * h)).map { i in ((i % w) / cell + (i / w) / cell) % 2 == 0 ? 20 : 235 }
    }

    func testSharpnessSeparatesDetailFromFlat() {
        let flat = [UInt8](repeating: 128, count: 40 * 40)
        XCTAssertEqual(ThumbnailScoring.sharpness(luma: flat, width: 40, height: 40), 0, accuracy: 1e-12)
        let fine = ThumbnailScoring.sharpness(luma: checker(40, 40, cell: 1), width: 40, height: 40)
        XCTAssertGreaterThan(fine, 0.9)
        // ぼけた(なだらかな)グラデーションは低い
        let ramp = (0..<(40 * 40)).map { UInt8(($0 % 40) * 6) }
        XCTAssertLessThan(ThumbnailScoring.sharpness(luma: ramp, width: 40, height: 40), 0.05)
        XCTAssertEqual(ThumbnailScoring.sharpness(luma: [1, 2], width: 2, height: 1), 0, "小さすぎる画像は 0")
    }

    func testBrightnessScorePeaksInTheMiddle() {
        XCTAssertEqual(ThumbnailScoring.brightnessScore(mean: 0.5), 1, accuracy: 1e-12)
        XCTAssertEqual(ThumbnailScoring.brightnessScore(mean: 0), 0, accuracy: 1e-12)
        XCTAssertEqual(ThumbnailScoring.brightnessScore(mean: 1), 0, accuracy: 1e-12)
        XCTAssertGreaterThan(ThumbnailScoring.brightnessScore(mean: 0.45), ThumbnailScoring.brightnessScore(mean: 0.1))
        XCTAssertEqual(ThumbnailScoring.meanBrightness(luma: [0, 255]), 0.5, accuracy: 1e-9)
    }

    func testFaceScoreRewardsPresenceAndSize() {
        XCTAssertEqual(ThumbnailScoring.faceScore(faces: []), 0)
        let small = ThumbnailScoring.faceScore(faces: [CGRect(x: 0.1, y: 0.1, width: 0.05, height: 0.05)])
        let big = ThumbnailScoring.faceScore(faces: [CGRect(x: 0.1, y: 0.1, width: 0.4, height: 0.4)])
        XCTAssertGreaterThan(small, 0.5)
        XCTAssertGreaterThan(big, small)
        XCTAssertEqual(big, 1, accuracy: 1e-12)
    }

    func testSampleTimesAreMidpointsOfEqualSlices() {
        XCTAssertEqual(ThumbnailScoring.sampleTimes(start: 10, duration: 4, samples: 4), [10.5, 11.5, 12.5, 13.5])
        XCTAssertTrue(ThumbnailScoring.sampleTimes(start: 0, duration: 0, samples: 4).isEmpty)
        XCTAssertTrue(ThumbnailScoring.sampleTimes(start: 0, duration: 3, samples: 0).isEmpty)
    }

    func cand(_ t: Double, _ s: Double) -> ThumbnailCandidate { .init(time: t, score: s, sharpness: 0, brightness: 0, faceCount: 0) }

    func testSelectTopIsDeterministicAndSkipsNeighbors() {
        let all = [cand(1, 0.5), cand(2, 0.9), cand(2.5, 0.8), cand(5, 0.7), cand(8, 0.7), cand(9, 0.1)]
        let top = ThumbnailScoring.selectTop(all, count: 3, minGap: 1)
        XCTAssertEqual(top.map(\.time), [2, 5, 8], "2.5 は 2 に近すぎて飛ばし、同点(5 と 8)は早い時刻が先")
        XCTAssertEqual(ThumbnailScoring.selectTop(all, count: 3, minGap: 1), top, "同じ入力は同じ結果")
        XCTAssertEqual(ThumbnailScoring.selectTop(all.reversed(), count: 3, minGap: 1), top, "並び順に依らない")
        XCTAssertEqual(ThumbnailScoring.selectTop(all, count: 99, minGap: 0).count, 6)
        XCTAssertTrue(ThumbnailScoring.selectTop(all, count: 0, minGap: 0).isEmpty)
        XCTAssertTrue(ThumbnailScoring.selectTop([], count: 3, minGap: 1).isEmpty)
    }

    /// 0〜3 秒は灰色、3〜6 秒は細かい模様(鮮明)の動画風プロジェクト。
    func project() -> Project {
        var p = Project()
        p.width = 160; p.height = 90; p.bg = "#808080"
        var tr = Track(name: "L1")
        var a = ClipEditing.makeShapeClip(.rect, at: 3, project: p)
        a.duration = 3; a.x = 0.5; a.y = 0.5; a.w = 1; a.h = 1; a.figure = Figure(kind: nil, fill: "#f0f0f0")
        tr.clips = [a]
        p.tracks = [tr]
        return p
    }

    func testFinderPrefersBrightMidtoneFacesAndIsDeterministic() throws {
        let p = project()
        let withFace = ThumbnailCandidateFinder.find(project: p, start: 0, duration: 6, count: 3, samples: 12, detector: FakeFaces(rects: [CGRect(x: 0.4, y: 0.3, width: 0.3, height: 0.4)]))
        XCTAssertEqual(withFace.count, 3)
        XCTAssertTrue(withFace.allSatisfy { $0.faceCount == 1 && $0.time >= 0 && $0.time <= 6 })
        // 灰色(0.5)の区間の方が、明るすぎる白の区間より明るさの点が高い
        XCTAssertTrue(withFace.allSatisfy { $0.time < 3 }, "中間の明るさのコマが選ばれる: \(withFace.map(\.time))")
        let again = ThumbnailCandidateFinder.find(project: p, start: 0, duration: 6, count: 3, samples: 12, detector: FakeFaces(rects: [CGRect(x: 0.4, y: 0.3, width: 0.3, height: 0.4)]))
        XCTAssertEqual(withFace, again)
        XCTAssertEqual(zip(withFace, withFace.dropFirst()).allSatisfy { $0.score >= $1.score }, true, "点数の高い順")
        XCTAssertTrue(ThumbnailCandidateFinder.find(project: p, start: 0, duration: 0, detector: FakeFaces(rects: [])).isEmpty)
        var empty = p; empty.width = 0
        XCTAssertTrue(ThumbnailCandidateFinder.find(project: empty, start: 0, duration: 6, detector: FakeFaces(rects: [])).isEmpty)
    }

    func testWritesNamedPNGsAt1280x720() throws {
        let p = project()
        let found = ThumbnailCandidateFinder.find(project: p, start: 0, duration: 6, count: 3, samples: 12, detector: FakeFaces(rects: []))
        let urls = try ThumbnailCandidateFinder.write(found, project: p, baseName: "demo", to: tmp)
        XCTAssertEqual(urls.count, found.count)
        XCTAssertTrue(urls[0].lastPathComponent.hasPrefix("demo_candidate_01_t"))
        XCTAssertTrue(urls.allSatisfy { $0.pathExtension == "png" && FileManager.default.fileExists(atPath: $0.path) })
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(urls[0] as CFURL, nil))
        let img = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        XCTAssertEqual(img.width, 1280); XCTAssertEqual(img.height, 720)
    }
}
