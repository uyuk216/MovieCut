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
        XCTAssertEqual(PreviewGuide.allCases.map(\.title), ["タイトルセーフ（90%）", "アクションセーフ（95%）", "中心線", "4分割線（2×2）", "三分割線", "16分割線（4×4）"])
    }

    // MARK: 分割グリッド

    func testGrid2AndGrid4DivisionLines() {
        let g2 = GuideGeometry.lines([.grid2], canvas: fhd)
        XCTAssertEqual(g2.count, 2, "2×2 は縦 1 本・横 1 本")
        XCTAssertTrue(g2.contains(GuideGeometry.Line(from: CGPoint(x: 960, y: 0), to: CGPoint(x: 960, y: 1080))))
        XCTAssertTrue(g2.contains(GuideGeometry.Line(from: CGPoint(x: 0, y: 540), to: CGPoint(x: 1920, y: 540))))
        let g4 = GuideGeometry.lines([.grid4], canvas: fhd)
        XCTAssertEqual(g4.count, 6, "4×4 は縦 3 本・横 3 本")
        XCTAssertTrue(g4.contains(GuideGeometry.Line(from: CGPoint(x: 480, y: 0), to: CGPoint(x: 480, y: 1080))))
        XCTAssertTrue(g4.contains(GuideGeometry.Line(from: CGPoint(x: 0, y: 810), to: CGPoint(x: 1920, y: 810))))
        // グリッドだけを取り出す(表示側で点線に分けるため)
        XCTAssertEqual(GuideGeometry.gridLines([.center, .grid4], canvas: fhd), g4)
        XCTAssertTrue(GuideGeometry.gridLines([.center, .titleSafe], canvas: fhd).isEmpty)
        XCTAssertEqual(GuideGeometry.divisionLines(divisions: 3, canvas: fhd), GuideGeometry.lines([.thirds], canvas: fhd), "三分割は 3 等分と一致")
        XCTAssertTrue(GuideGeometry.divisionLines(divisions: 1, canvas: fhd).isEmpty)
    }

    func testGridLineCoordinatesForSnapping() {
        XCTAssertEqual(GuideGeometry.verticalCoordinates([.grid4], canvas: fhd), [480, 960, 1440])
        XCTAssertEqual(GuideGeometry.horizontalCoordinates([.grid4], canvas: fhd), [270, 540, 810])
        XCTAssertEqual(GuideGeometry.verticalCoordinates([.grid2], canvas: fhd), [960])
        // 中心線と 2×2 の中央線は同じ座標なので重複しない
        XCTAssertEqual(GuideGeometry.verticalCoordinates([.center, .grid2], canvas: fhd), [960])
        XCTAssertEqual(GuideGeometry.horizontalCoordinates([.center, .thirds], canvas: fhd), [360, 540, 720])
        XCTAssertTrue(GuideGeometry.verticalCoordinates([.titleSafe], canvas: fhd).isEmpty)
        XCTAssertTrue(GuideGeometry.verticalCoordinates([], canvas: fhd).isEmpty)
    }

    func testGridGuidesAreExclusiveWhenToggled() {
        // グリッドを ON にすると他のグリッドは外れる
        XCTAssertEqual(PreviewGuide.toggled([.thirds], .grid4), [.grid4])
        XCTAssertEqual(PreviewGuide.toggled([.grid2, .center], .thirds), [.center, .thirds])
        XCTAssertEqual(PreviewGuide.toggled([], .grid2), [.grid2])
        // グリッドを OFF にするのはそのまま外すだけ
        XCTAssertEqual(PreviewGuide.toggled([.grid4, .center], .grid4), [.center])
        // グリッド以外(中心線・セーフ)はグリッドと独立
        XCTAssertEqual(PreviewGuide.toggled([.grid2], .center), [.grid2, .center])
        XCTAssertEqual(PreviewGuide.toggled([.grid2, .titleSafe], .titleSafe), [.grid2])
        XCTAssertEqual(PreviewGuide.toggled([.center], .center), [])
    }

    func testResolveKeepsOnlyTheLastGridWhenSeveralAreStored() {
        XCTAssertEqual(PreviewGuide.resolve(["thirds", "grid4"]), [.grid4], "後ろのグリッドが勝つ")
        XCTAssertEqual(PreviewGuide.resolve(["grid2", "thirds", "center"]), [.thirds, .center])
        XCTAssertEqual(PreviewGuide.resolve(["grid4", "grid2"]), [.grid2])
        // 保存の並び(allCases 順)にグリッドが 1 つだけ残る
        XCTAssertEqual(PreviewGuide.encode([.grid4, .titleSafe, .center]), ["titleSafe", "center", "grid4"])
        XCTAssertEqual(PreviewGuide.resolve(PreviewGuide.encode([.grid2, .actionSafe])), [.actionSafe, .grid2])
    }

    // MARK: 表示フラグ(effective)

    func testEffectiveIsEmptyWhenHiddenSoDrawingGeometryIsEmpty() {
        let all = Set(PreviewGuide.allCases.filter { !$0.isGrid }).union([.thirds])
        let off = PreviewGuide.effective(all, visible: false)
        XCTAssertTrue(off.isEmpty)
        XCTAssertTrue(GuideGeometry.lines(off, canvas: fhd).isEmpty)
        XCTAssertTrue(GuideGeometry.gridLines(off, canvas: fhd).isEmpty)
        XCTAssertTrue(GuideGeometry.safeRects(off, canvas: fhd).isEmpty)
        let on = PreviewGuide.effective(all, visible: true)
        XCTAssertEqual(on, all, "表示 ON なら従来どおり")
        XCTAssertFalse(GuideGeometry.lines(on, canvas: fhd).isEmpty)
        XCTAssertFalse(GuideGeometry.gridLines(on, canvas: fhd).isEmpty)
        XCTAssertEqual(GuideGeometry.safeRects(on, canvas: fhd).count, 2)
    }

    func testSnapTargetsDropGuideCoordinatesWhenHiddenButKeepCanvasEdgesAndCenter() {
        let guides: Set<PreviewGuide> = [.thirds]
        let off = PreviewSnap.targets(canvas: fhd, guides: PreviewGuide.effective(guides, visible: false), otherBoxes: [])
        XCTAssertFalse(off.verticals.contains(640)); XCTAssertFalse(off.verticals.contains(1280))
        for x in [0.0, 960, 1920] { XCTAssertTrue(off.verticals.contains(x), "キャンバスの端・中心は残る") }
        for y in [0.0, 540, 1080] { XCTAssertTrue(off.horizontals.contains(y)) }
        let on = PreviewSnap.targets(canvas: fhd, guides: PreviewGuide.effective(guides, visible: true), otherBoxes: [])
        XCTAssertTrue(on.verticals.contains(640)); XCTAssertTrue(on.verticals.contains(1280))
        XCTAssertTrue(on.horizontals.contains(360)); XCTAssertTrue(on.horizontals.contains(720))
    }
}
