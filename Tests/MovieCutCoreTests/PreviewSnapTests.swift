import XCTest
import CoreGraphics
@testable import MovieCutCore

/// プレビューの直接操作のスナップ: スナップ先の収集、移動(端・中心)の吸着、拡縮(角)の吸着、閾値、最寄り優先。
/// 座標はキャンバスの画素(左上原点)。キャンバスは 1280×720 で固定して数字を読む。
final class PreviewSnapTests: XCTestCase {
    let canvas = CGSize(width: 1280, height: 720)
    /// 中央(640, 360)に置いた 360×360 の枠(左 460・右 820・上 180・下 540)。
    var box: TransformBox { TransformBox(center: CGPoint(x: 640, y: 360), width: 360, height: 360, rotation: 0) }

    // MARK: スナップ先の収集

    func testTargetsAlwaysIncludeCanvasEdgesAndCenter() {
        let t = PreviewSnap.targets(canvas: canvas)
        XCTAssertEqual(t.verticals, [0, 640, 1280])
        XCTAssertEqual(t.horizontals, [0, 360, 720])
    }

    func testTargetsAddGuideLinesAndOtherBoxesSortedAndUnique() {
        let other = TransformBox(center: CGPoint(x: 320, y: 180), width: 200, height: 100, rotation: 0)
        let t = PreviewSnap.targets(canvas: canvas, guides: [.grid4], otherBoxes: [other])
        // キャンバス(0・640・1280) + グリッド4(320・640・960) + 他の枠(220・320・420)、重複は 1 つに
        XCTAssertEqual(t.verticals, [0, 220, 320, 420, 640, 960, 1280])
        XCTAssertEqual(t.horizontals, [0, 130, 180, 230, 360, 540, 720])
        XCTAssertTrue(PreviewSnap.targets(canvas: .zero).isEmpty)
    }

    // MARK: 移動の吸着

    func testMoveSnapsLeftEdgeToCanvasLeft() {
        // 左端(460)が -455 動くと 5 まで来る: 閾値 8 以内なので 0 へ吸着し、移動量は -460 になる
        let r = PreviewSnap.snapMove(box: box, delta: CGPoint(x: -455, y: 20), targets: PreviewSnap.targets(canvas: canvas), threshold: 8)
        XCTAssertEqual(r.delta.x, -460, accuracy: 1e-9)
        XCTAssertEqual(r.delta.y, 20, accuracy: 1e-9)
        XCTAssertEqual(r.verticalLine, 0)
        XCTAssertNil(r.horizontalLine)
    }

    func testMoveSnapsCenterToCanvasCenter() {
        // 中心が 635 まで来たら中心線 640 へ(端はどこにも届かない)
        let r = PreviewSnap.snapMove(box: box, delta: CGPoint(x: -5, y: 4), targets: PreviewSnap.targets(canvas: canvas), threshold: 8)
        XCTAssertEqual(r.delta.x, 0, accuracy: 1e-9)
        XCTAssertEqual(r.delta.y, 0, accuracy: 1e-9, "中心 364 も中心線 360 へ吸着")
        XCTAssertEqual(r.verticalLine, 640)
        XCTAssertEqual(r.horizontalLine, 360)
    }

    func testMoveSnapsRightAndBottomEdgesToOtherBox() {
        // 他の枠の左端 1000・上端 100 に、自分の右端・上端を合わせる
        let targets = PreviewSnap.Targets(verticals: [1000], horizontals: [100])
        let r = PreviewSnap.snapMove(box: box, delta: CGPoint(x: 175, y: -75), targets: targets, threshold: 8)
        XCTAssertEqual(r.delta.x, 180, accuracy: 1e-9, "右端 820+180 = 1000")
        XCTAssertEqual(r.delta.y, -80, accuracy: 1e-9, "上端 180-80 = 100")
        XCTAssertEqual(r.verticalLine, 1000)
        XCTAssertEqual(r.horizontalLine, 100)
    }

    func testMoveOutsideThresholdDoesNotSnap() {
        let r = PreviewSnap.snapMove(box: box, delta: CGPoint(x: -450, y: 30), targets: PreviewSnap.targets(canvas: canvas), threshold: 8)
        XCTAssertEqual(r.delta.x, -450, accuracy: 1e-9, "左端は 10 まで来るが閾値 8 の外")
        XCTAssertEqual(r.delta.y, 30, accuracy: 1e-9)
        XCTAssertFalse(r.snapped)
    }

    func testMoveAtExactlyThresholdSnaps() {
        let r = PreviewSnap.snapMove(box: box, delta: CGPoint(x: -452, y: 0), targets: PreviewSnap.targets(canvas: canvas), threshold: 8)
        XCTAssertEqual(r.verticalLine, 0, "左端 8 = 閾値ちょうどは吸着する")
        XCTAssertEqual(r.delta.x, -460, accuracy: 1e-9)
    }

    func testMovePrefersTheNearestCandidate() {
        // 右端が 995 まで来る: 候補 990(距離 5)と 1000(距離 5)なら小さいほう、1002(距離 7)より 990 が近い
        let targets = PreviewSnap.Targets(verticals: [990, 1000, 1002], horizontals: [])
        let r = PreviewSnap.snapMove(box: box, delta: CGPoint(x: 175, y: 0), targets: targets, threshold: 8)
        XCTAssertEqual(r.verticalLine, 990)
        XCTAssertEqual(r.delta.x, 170, accuracy: 1e-9)
        // 距離が違うときは本当に近いほう: 右端 997 なら 1000(距離 3)
        let r2 = PreviewSnap.snapMove(box: box, delta: CGPoint(x: 177, y: 0), targets: targets, threshold: 8)
        XCTAssertEqual(r2.verticalLine, 1000)
        XCTAssertEqual(r2.delta.x, 180, accuracy: 1e-9)
    }

    func testMoveWithNoCandidatesDoesNotSnap() {
        let r = PreviewSnap.snapMove(box: box, delta: CGPoint(x: -455, y: -175), targets: PreviewSnap.Targets(), threshold: 8)
        XCTAssertEqual(r.delta.x, -455, accuracy: 1e-9)
        XCTAssertEqual(r.delta.y, -175, accuracy: 1e-9)
        XCTAssertFalse(r.snapped)
    }

    // MARK: 点(拡縮の角)の吸着

    func testPointSnapsEachAxisIndependently() {
        // 右下の角(820, 540)を (1275, 300) へ: x は右端 1280 へ、y は届かないのでそのまま
        let r = PreviewSnap.snapPoint(CGPoint(x: 1275, y: 300), targets: PreviewSnap.targets(canvas: canvas), threshold: 8)
        XCTAssertEqual(r.point.x, 1280, accuracy: 1e-9)
        XCTAssertEqual(r.point.y, 300, accuracy: 1e-9)
        XCTAssertEqual(r.verticalLine, 1280)
        XCTAssertNil(r.horizontalLine)
    }

    func testPointOutsideThresholdAndNoCandidates() {
        let t = PreviewSnap.targets(canvas: canvas)
        let r = PreviewSnap.snapPoint(CGPoint(x: 100, y: 100), targets: t, threshold: 8)
        XCTAssertEqual(r.point, CGPoint(x: 100, y: 100))
        XCTAssertFalse(r.snapped)
        let r2 = PreviewSnap.snapPoint(CGPoint(x: 3, y: 3), targets: PreviewSnap.Targets(), threshold: 8)
        XCTAssertEqual(r2.point, CGPoint(x: 3, y: 3))
        XCTAssertFalse(r2.snapped)
    }

    func testPointPrefersNearestAndBreaksTiesBySmallerCoordinate() {
        let targets = PreviewSnap.Targets(verticals: [100, 110], horizontals: [50])
        // 106 は 110 のほうが近い(4 < 6)
        XCTAssertEqual(PreviewSnap.snapPoint(CGPoint(x: 106, y: 200), targets: targets, threshold: 8).verticalLine, 110)
        // 105 は同距離(5)なので小さいほう 100
        let tie = PreviewSnap.snapPoint(CGPoint(x: 105, y: 200), targets: targets, threshold: 8)
        XCTAssertEqual(tie.verticalLine, 100)
        XCTAssertEqual(tie.point.x, 100, accuracy: 1e-9)
    }

    func testNearestRejectsNonFiniteAndNegativeThresholdActsAsZero() {
        XCTAssertNil(PreviewSnap.nearest(value: .nan, candidates: [0], threshold: 8))
        XCTAssertNil(PreviewSnap.nearest(value: 5, candidates: [0], threshold: -1), "負の閾値は 0 扱いで、離れた値は吸着しない")
        XCTAssertEqual(PreviewSnap.nearest(value: 0, candidates: [0], threshold: -1)?.line, 0, "ぴったりなら吸着")
    }
}
