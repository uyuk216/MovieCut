import XCTest
@testable import MovieCutCore

/// パネルの切り離し(引き剥がし)の状態機械、戻し先の記録(homes)、再ドックの純粋ロジック。
final class DockTearOffTests: XCTestCase {

    // MARK: 状態機械

    func testDraggingDockedTabOutOfWindowTearsOffThenFollows() {
        var m = DockTearOff()
        m.press(.timeline, docked: true)
        XCTAssertEqual(m.drag(overMainWindow: true), .none, "書類の中で動かしている間は何もしない")
        XCTAssertEqual(m.drag(overMainWindow: false), .tearOff(.timeline), "外へ出たら切り離す")
        XCTAssertEqual(m.phase, .floating(.timeline))
        XCTAssertEqual(m.drag(overMainWindow: false), .follow(.timeline), "切り離したウインドウはカーソルに付いてくる")
        XCTAssertEqual(m.drag(overMainWindow: true), .follow(.timeline))
    }

    func testReleaseOutsideLeavesPanelDetached() {
        var m = DockTearOff()
        m.press(.preview, docked: true)
        _ = m.drag(overMainWindow: false)
        XCTAssertEqual(m.release(overMainWindow: false, outer: nil), .none, "外で離したら切り離したまま")
        XCTAssertEqual(m.phase, .idle)
    }

    func testReleaseOverMainWindowRedocks() {
        var m = DockTearOff()
        m.press(.preview, docked: true)
        _ = m.drag(overMainWindow: false)
        XCTAssertEqual(m.release(overMainWindow: true, outer: nil), .redock(.preview, outer: nil))
        XCTAssertEqual(m.phase, .idle)
    }

    func testReleaseOverOuterBandRedocksToThatEdge() {
        var m = DockTearOff()
        m.press(.inspector, docked: true)
        _ = m.drag(overMainWindow: false)
        XCTAssertEqual(m.release(overMainWindow: true, outer: .left), .redock(.inspector, outer: .left))
    }

    func testPressingFloatingPanelNeverTearsOffAgain() {
        var m = DockTearOff()
        m.press(.characters, docked: false)
        XCTAssertEqual(m.drag(overMainWindow: false), .none, "もう切り離れているものは、切り離しを頼まない")
        XCTAssertEqual(m.release(overMainWindow: false, outer: nil), .none)
    }

    func testWindowClosedRedocksAndClearsFloating() {
        var m = DockTearOff()
        m.press(.timeline, docked: true)
        _ = m.drag(overMainWindow: false)
        XCTAssertEqual(m.windowClosed(.timeline), .redock(.timeline, outer: nil), "閉じたらドッキングへ戻す")
        XCTAssertEqual(m.phase, .idle)
    }

    func testRestoreButtonRedocks() {
        var m = DockTearOff()
        XCTAssertEqual(m.restore(.preview), .redock(.preview, outer: nil))
    }

    func testIdleDragDoesNothing() {
        var m = DockTearOff()
        XCTAssertEqual(m.drag(overMainWindow: false), .none)
        XCTAssertEqual(m.release(overMainWindow: true, outer: nil), .none)
    }

    // MARK: 戻し先の記録(homes)と再ドック

    func testDetachThenAttachRestoresTheSameDefaultLayout() {
        // 初期配置のタイムラインを切り離して戻すと、木(分割の割合まで)が元どおり
        var l = DockLayout.default
        XCTAssertTrue(l.detach(.timeline))
        XCTAssertEqual(l.homes?["timeline"]?.anchor, .preview)
        XCTAssertEqual(l.homes?["timeline"]?.edge, .bottom)
        XCTAssertEqual(l.homes?["timeline"]?.fraction ?? -1, 0.4, accuracy: 1e-9)
        XCTAssertTrue(l.attach(.timeline))
        XCTAssertEqual(l.root, DockLayout.default.root, "割合を含めて元に戻る")
        XCTAssertNil(l.homes, "戻したら記録は消える(キーごと書かない)")
    }

    func testDetachInspectorReturnsAsTabOfItsGroup() {
        var l = DockLayout.default
        XCTAssertTrue(l.detach(.inspector))
        XCTAssertNil(l.homes?["inspector"]?.edge, "同じグループのタブとして戻す")
        XCTAssertEqual(l.homes?["inspector"]?.anchor, .characters)
        XCTAssertTrue(l.attach(.inspector))
        XCTAssertEqual(Set(l.group(containing: .inspector)?.panels ?? []), [.inspector, .characters])
        XCTAssertTrue(l.isValid)
    }

    func testRedockToOuterEdgeWhenDroppedOnBand() {
        var l = DockLayout.default
        XCTAssertTrue(l.detach(.characters))
        XCTAssertTrue(l.redock(.characters, outer: .right))
        XCTAssertEqual(l.location(of: .characters), .docked)
        XCTAssertEqual(l.docked.last, .characters, "ドック全体の右端に入る")
        XCTAssertNil(l.homes?["characters"], "端に入れたら、昔の戻し先の記録は消す")
        XCTAssertTrue(l.isValid)
    }

    func testRedockWithoutEdgeGoesHome() {
        var l = DockLayout.default
        XCTAssertTrue(l.detach(.preview))
        XCTAssertTrue(l.redock(.preview, outer: nil))
        XCTAssertEqual(l.root, DockLayout.default.root)
    }

    func testHomeFallsBackToDefaultWhenAnchorIsGone() {
        var l = DockLayout.default
        XCTAssertTrue(l.detach(.timeline))
        // 戻し先の隣(preview)が切り離されたら、記録は使えないので初期配置の隣へ
        XCTAssertTrue(l.detach(.preview))
        XCTAssertTrue(l.attach(.timeline))
        XCTAssertTrue(l.isValid)
        XCTAssertEqual(l.location(of: .timeline), .docked)
    }

    func testHomesSurviveEncodingAndSanitizing() throws {
        var l = DockLayout.default
        _ = l.detach(.timeline)
        let data = try XCTUnwrap(l.encoded())
        let back = DockLayout.decoded(from: data)
        XCTAssertEqual(back.homes, l.homes, "保存して読み直しても戻し先が残る")
        XCTAssertEqual(back.sanitized().homes, l.homes)
        XCTAssertEqual(DockLayout.forLaunch(from: data).location(of: .timeline), .docked, "起動時は戻す")
    }

    func testLayoutWithoutHomesEncodesWithoutTheKey() throws {
        // 戻し先の記録が無いときは、保存する JSON に homes のキーを出さない(古い保存と同じ形)
        let data = try XCTUnwrap(DockLayout.default.encoded())
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("homes"))
        XCTAssertEqual(DockLayout.decoded(from: data), DockLayout.default)
    }

    func testOldLayoutJSONDecodesWithoutHomes() {
        let old = #"{"floating":["timeline","inspector","characters"],"closed":[],"root":{"kind":"group","panels":["preview"],"active":"preview"}}"#
        let l = DockLayout.decoded(from: Data(old.utf8))
        XCTAssertNil(l.homes)
        XCTAssertEqual(l.location(of: .timeline), .floating)
    }
}
