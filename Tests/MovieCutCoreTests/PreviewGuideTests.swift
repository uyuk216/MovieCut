import XCTest
import CoreGraphics
@testable import MovieCutCore

/// プレビューのガイド線(表示 ▸ ガイド線): 幾何の数字、保存の読み書き。書き出しには関係しない(表示だけ)。
final class PreviewGuideTests: XCTestCase {
    let fhd = CGSize(width: 1920, height: 1080)

    func testTitleSafeIsTheInner90PercentAndActionSafeIs95() {
        let rs = GuideGeometry.safeRects([.titleSafe, .actionSafe], canvas: fhd)
        XCTAssertEqual(rs.count, 2)
        XCTAssertEqual(rs[0], CGRect(x: 96, y: 54, width: 1728, height: 972), "タイトルセーフ 90%")
        XCTAssertEqual(rs[1], CGRect(x: 48, y: 27, width: 1824, height: 1026), "アクションセーフ 95%")
        XCTAssertTrue(GuideGeometry.safeRects([.center, .thirds], canvas: fhd).isEmpty)
    }

    func testCenterCrossAndThirdsLines() {
        let center = GuideGeometry.lines([.center], canvas: fhd)
        XCTAssertEqual(center.count, 2)
        XCTAssertTrue(center.contains(GuideGeometry.Line(from: CGPoint(x: 960, y: 0), to: CGPoint(x: 960, y: 1080))))
        XCTAssertTrue(center.contains(GuideGeometry.Line(from: CGPoint(x: 0, y: 540), to: CGPoint(x: 1920, y: 540))))
        let thirds = GuideGeometry.lines([.thirds], canvas: fhd)
        XCTAssertEqual(thirds.count, 4, "縦 2 本・横 2 本")
        XCTAssertTrue(thirds.contains(GuideGeometry.Line(from: CGPoint(x: 640, y: 0), to: CGPoint(x: 640, y: 1080))))
        XCTAssertTrue(thirds.contains(GuideGeometry.Line(from: CGPoint(x: 0, y: 720), to: CGPoint(x: 1920, y: 720))))
        XCTAssertEqual(GuideGeometry.lines([.center, .thirds], canvas: fhd).count, 6)
        XCTAssertTrue(GuideGeometry.lines([.titleSafe], canvas: fhd).isEmpty)
    }

    func testStoredValuesRoundTripAndUnknownOnesAreDropped() {
        XCTAssertEqual(PreviewGuide.resolve(nil), [])
        XCTAssertEqual(PreviewGuide.resolve(["center", "bogus", "thirds"]), [.center, .thirds])
        // 保存の並びは固定(allCases の順)
        XCTAssertEqual(PreviewGuide.encode([.thirds, .titleSafe]), ["titleSafe", "thirds"])
        XCTAssertEqual(PreviewGuide.resolve(PreviewGuide.encode([.actionSafe, .center])), [.actionSafe, .center])
        XCTAssertEqual(PreviewGuide.encode([]), [], "何も出さないときは空の配列")
    }

    func testEveryGuideHasATitleForTheMenu() {
        XCTAssertEqual(PreviewGuide.allCases.map(\.title), ["タイトルセーフ（90%）", "アクションセーフ（95%）", "中心線", "三分割線"])
    }
}
