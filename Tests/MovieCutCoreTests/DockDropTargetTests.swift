import XCTest
@testable import MovieCutCore

/// タブをドラッグしたときの置き場所(5 つの領域 + ドック全体の外側の端)の判定とハイライトの寸法。
final class DockDropTargetTests: XCTestCase {
    /// 400×326 のグループがドック(1200×800)の真ん中(x=300,y=200)にあるとして判定する。
    private func inner(_ x: Double, _ y: Double) -> DockDropTarget {
        DockDropTarget.resolve(x: x, y: y, width: 400, height: 326, groupX: 300, groupY: 200, hostWidth: 1200, hostHeight: 800)
    }

    func testFiveZonesInsideAGroup() {
        XCTAssertEqual(inner(200, 10), .tab)                 // タブバー
        XCTAssertEqual(inner(200, 26 + 150), .tab)           // 中央
        XCTAssertEqual(inner(10, 26 + 150), .edge(.left))
        XCTAssertEqual(inner(395, 26 + 150), .edge(.right))
        XCTAssertEqual(inner(200, 26 + 5), .edge(.top))
        XCTAssertEqual(inner(200, 320), .edge(.bottom))
    }

    func testOuterBandsWinOverInnerZones() {
        func t(_ hx: Double, _ hy: Double) -> DockDropTarget {   // ドック全体の座標で、左上のグループ(0,0 / 600×400)にいる
            DockDropTarget.resolve(x: hx, y: hy, width: 600, height: 400, groupX: 0, groupY: 0, hostWidth: 1200, hostHeight: 800)
        }
        XCTAssertEqual(t(5, 200), .outer(.left))
        XCTAssertEqual(t(300, 4), .outer(.top))
        XCTAssertEqual(t(300, 20), .tab)                      // 上の細い帯の外のタブバーは、タブとして合流
        XCTAssertEqual(t(100, 200), .edge(.left))             // 帯の外 = グループの左半分
        let right = DockDropTarget.resolve(x: 590, y: 200, width: 600, height: 400, groupX: 600, groupY: 0, hostWidth: 1200, hostHeight: 800)
        XCTAssertEqual(right, .outer(.right))
        let bottom = DockDropTarget.resolve(x: 300, y: 390, width: 600, height: 400, groupX: 0, groupY: 400, hostWidth: 1200, hostHeight: 800)
        XCTAssertEqual(bottom, .outer(.bottom))
    }

    func testUnknownHostSizeFallsBackToInnerZones() {
        let t = DockDropTarget.resolve(x: 2, y: 100, width: 400, height: 326, groupX: 0, groupY: 0, hostWidth: 0, hostHeight: 0)
        XCTAssertEqual(t, .edge(.left))
    }

    func testHighlightRects() {
        let w = 400.0, h = 326.0
        func r(_ t: DockDropTarget) -> [Double] { let q = t.highlightRect(width: w, height: h); return [q.x, q.y, q.width, q.height] }
        XCTAssertEqual(r(.tab), [0, 0, 400, 326])
        XCTAssertEqual(r(.edge(.left)), [0, 26, 200, 300])
        XCTAssertEqual(r(.edge(.right)), [200, 26, 200, 300])
        XCTAssertEqual(r(.edge(.top)), [0, 26, 400, 150])
        XCTAssertEqual(r(.edge(.bottom)), [0, 176, 400, 150])
        XCTAssertEqual(r(.outer(.left)), [0, 0, 100, 326])
        XCTAssertEqual(r(.outer(.right)), [300, 0, 100, 326])
        XCTAssertEqual(r(.outer(.top)), [0, 0, 400, 81.5])
        XCTAssertEqual(r(.outer(.bottom)), [0, 244.5, 400, 81.5])
    }

    // MARK: ドック全体の端へ置く(DockLayout.moveToRootEdge)

    func testMoveToRootEdgeEachSide() {
        for e in DockEdge.allCases {
            var l = DockLayout.default
            XCTAssertTrue(l.moveToRootEdge(.characters, e), "\(e)")
            XCTAssertTrue(l.isValid, "\(e)")
            XCTAssertEqual(Set(l.docked), Set(DockPanel.allCases), "\(e): パネルが減らない")
            guard case .split(let axis, let f, let a, let b)? = l.root else { return XCTFail("\(e)") }
            XCTAssertEqual(axis, (e == .left || e == .right) ? .horizontal : .vertical)
            let newFirst = (e == .left || e == .top)
            XCTAssertEqual(newFirst ? a : b, .group(DockGroup(panels: [.characters])), "\(e): 新しいグループが外側")
            XCTAssertEqual(newFirst ? f : 1 - f, DockDropTarget.outerFraction, accuracy: 1e-9)
        }
    }

    func testMoveToRootEdgeFromTabGroupAndFloatingAndOnlyPanel() {
        var l = DockLayout.preset(.singleTab)        // 全部 1 つのタブ
        XCTAssertTrue(l.moveToRootEdge(.timeline, .bottom))
        XCTAssertTrue(l.isValid)
        XCTAssertEqual(l.docked.count, 4)
        var f = DockLayout.default
        f.detach(.inspector)
        XCTAssertTrue(f.moveToRootEdge(.inspector, .right))     // 別ウインドウから戻して右端へ
        XCTAssertTrue(f.isValid); XCTAssertEqual(f.floating, [])
        var only = DockLayout(root: .group(DockGroup(panels: [.preview])), floating: [.timeline], closed: [.characters, .inspector])
        let before = only
        XCTAssertFalse(only.moveToRootEdge(.preview, .left), "唯一のパネルを自分の端へは置けない")
        XCTAssertEqual(only, before)
    }

    func testPreviewBackgroundChoicesAndStoredValues() {
        XCTAssertEqual(PreviewBackground.default, .darkGray)
        XCTAssertEqual(PreviewBackground.allCases.map(\.title), ["暗い灰色", "黒", "白", "中間グレー", "緑(クロマキー)", "青"])
        XCTAssertEqual(PreviewBackground.darkGray.hex, "#1E1E1E")
        XCTAssertEqual(Set(PreviewBackground.allCases.map(\.hex)).count, 6)
        XCTAssertEqual(PreviewBackground.resolve(nil), .darkGray)
        XCTAssertEqual(PreviewBackground.resolve("壊れた値"), .darkGray)
        for b in PreviewBackground.allCases { XCTAssertEqual(PreviewBackground.resolve(b.rawValue), b); XCTAssertNotNil(parseHexColor(b.hex)) }
    }
}
