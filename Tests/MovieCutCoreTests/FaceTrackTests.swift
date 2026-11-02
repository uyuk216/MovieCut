import XCTest
import CoreGraphics
@testable import MovieCutCore

/// 顔の追従(時間方向の平滑化・補間)の純粋な計算。検出は偽物の値を入れる。
final class FaceTrackTests: XCTestCase {
    let a = CGRect(x: 100, y: 100, width: 200, height: 200)
    let b = CGRect(x: 300, y: 100, width: 200, height: 200)

    func testSampleTimesCoverBothEnds() {
        XCTAssertEqual(FaceTrack.sampleTimes(duration: 2, interval: 0.5), [0, 0.5, 1, 1.5, 2])
        XCTAssertEqual(FaceTrack.sampleTimes(duration: 1.2, interval: 0.5).last, 1.2)
        XCTAssertEqual(FaceTrack.sampleTimes(duration: 0), [0])
        XCTAssertEqual(FaceTrack.sampleTimes(duration: .nan), [0])
    }

    func testChoosePrefersOverlapWithPreviousThenLargest() {
        // 前回の枠と重なる顔を選ぶ(大きくても重ならない顔は選ばない)
        let big = CGRect(x: 800, y: 0, width: 400, height: 400)
        XCTAssertEqual(FaceTrack.choose([big, a], previous: a), a)
        // 前回が無い・重なりが無いときは一番大きい顔
        XCTAssertEqual(FaceTrack.choose([a, big], previous: nil), big)
        XCTAssertNil(FaceTrack.choose([], previous: a))
        // 幅・高さが 0 の枠は捨てる
        XCTAssertNil(FaceTrack.choose([CGRect(x: 0, y: 0, width: 0, height: 5)], previous: nil))
    }

    func testRectInterpolatesBetweenDetections() throws {
        let s = [FaceTrackSample(time: 0, rect: a), FaceTrackSample(time: 1, rect: b)]
        let mid = try XCTUnwrap(FaceTrack.rect(at: 0.5, in: s))
        XCTAssertEqual(mid.minX, 200, accuracy: 1e-9)
        XCTAssertEqual(mid.minY, 100, accuracy: 1e-9)
        XCTAssertEqual(mid.width, 200, accuracy: 1e-9)
    }

    func testRectHoldsNearestOnlyWithinMaxGap() throws {
        let s = [FaceTrackSample(time: 0, rect: a), FaceTrackSample(time: 0.5, rect: nil)]
        XCTAssertEqual(FaceTrack.rect(at: 0.25, in: s), a)            // 検出の後 0.25 秒は保つ
        XCTAssertNil(FaceTrack.rect(at: 5, in: s))                    // 大きく離れたら何もしない
        XCTAssertNil(FaceTrack.rect(at: 0, in: []))
        XCTAssertNil(FaceTrack.rect(at: 0, in: [FaceTrackSample(time: 0, rect: nil)]))
    }

    func testRectDoesNotInterpolateAcrossLongGap() throws {
        // 検出が 2 × maxGap より長く途切れたら、前後の顔を線で結ばない(別の人へ飛ばない)
        let s = [FaceTrackSample(time: 0, rect: a), FaceTrackSample(time: 4, rect: b)]
        XCTAssertEqual(FaceTrack.rect(at: 0.5, in: s), a)
        XCTAssertNil(FaceTrack.rect(at: 2, in: s))
        XCTAssertEqual(FaceTrack.rect(at: 3.5, in: s), b)
    }

    func testBuildSmoothsJitterAndKeepsGaps() throws {
        let jitter = CGRect(x: 160, y: 100, width: 200, height: 200)
        let out = FaceTrack.build(detections: [(0, [a]), (0.5, [jitter]), (1, [a]), (1.5, [])])
        XCTAssertEqual(out.count, 4)
        // 中央は前後との 1:2:1 の平均(揺れが小さくなる)
        let mid = try XCTUnwrap(out[1].rect)
        XCTAssertEqual(mid.minX, (100 + 2 * 160 + 100) / 4.0, accuracy: 1e-9)
        XCTAssertNil(out[3].rect)
    }

    func testIoU() {
        XCTAssertEqual(FaceTrack.iou(a, a), 1, accuracy: 1e-9)
        XCTAssertEqual(FaceTrack.iou(a, b), 0)
    }
}
