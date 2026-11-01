import XCTest
import AppKit
import MovieCutCore
@testable import MovieCut

/// マーカーの色(移動 ▸ マーカーの色・旗と案内線の色)。次・前のマーカーへは MenuM7Tests で確認済み。
@MainActor
final class MarkerColorAppTests: XCTestCase {
    private func makeModel() -> ProjectModel {
        var p = Project.new()
        p.markers = [Marker(time: 2, name: "イントロ"), Marker(time: 6, name: "サビ")]
        let m = ProjectModel(project: p)
        m.voiceProviderFactory = { _ in ToneVoiceProvider() }
        m.notices = OneTimeNotices()
        return m
    }

    private func state(_ configure: (inout MenuState) -> Void) -> MenuState {
        var s = MenuState()
        s.hasDocument = true
        configure(&s)
        return s
    }

    func testColorItemsListEveryColorWithNoShortcut() {
        let items = AppMenuSpec.markerColorItems(state { $0.markerAtPlayhead = true })
        XCTAssertEqual(items.map(\.title), MarkerColor.allCases.map(\.title))
        XCTAssertTrue(items.allSatisfy { $0.shortcut == nil }, "色は通常キーにもショートカットにも割り当てない")
        XCTAssertTrue(items.allSatisfy(\.enabled))
    }

    func testCheckedColorFollowsThePlayheadMarker() {
        let items = AppMenuSpec.markerColorItems(state {
            $0.markerAtPlayhead = true
            $0.playheadMarkerColor = .red
        })
        XCTAssertEqual(items.filter { $0.checked == true }.map(\.command), [.markerColor(.red)])
    }

    func testColorItemsDisabledWithoutMarkerAtPlayhead() {
        let items = AppMenuSpec.markerColorItems(state { $0.markerAtPlayhead = false })
        XCTAssertTrue(items.allSatisfy { !$0.enabled })
    }

    func testPerformSetsColorAtPlayheadAndUndoes() {
        let m = makeModel()
        m.currentTime = 2
        let um = m.effectiveUndoManager
        AppMenu.perform(.markerColor(.blue), model: m)
        XCTAssertEqual(m.project.markers.first { $0.name == "イントロ" }?.color, "blue")
        XCTAssertNil(m.project.markers.first { $0.name == "サビ" }?.color, "他のマーカーは変えない")
        XCTAssertEqual(um.undoActionName, "マーカーの色の変更")
        um.undo()
        XCTAssertNil(m.project.markers.first { $0.name == "イントロ" }?.color)
    }

    func testSameColorIsNotAnUndoStep() {
        let m = makeModel()
        m.currentTime = 2
        AppMenu.perform(.markerColor(.teal), model: m)
        XCTAssertFalse(m.effectiveUndoManager.canUndo, "既定の色のまま変えても履歴に載せない")
        XCTAssertNil(m.project.markers.first { $0.name == "イントロ" }?.color)
    }

    func testNoMarkerAtPlayheadDoesNothing() {
        let m = makeModel()
        m.currentTime = 4
        AppMenu.perform(.markerColor(.red), model: m)
        XCTAssertTrue(m.project.markers.allSatisfy { $0.color == nil })
        XCTAssertFalse(m.effectiveUndoManager.canUndo)
    }

    /// 旗と案内線は、マーカーの色で描く(無ければ既定の色)。
    func testRulerUsesThePerMarkerColor() {
        var red = Marker(time: 1, name: "a")
        red.color = "red"
        let plain = Marker(time: 1, name: "b")
        func srgb(_ c: NSColor) -> [CGFloat] {
            let s = c.usingColorSpace(.sRGB) ?? c
            return [s.redComponent, s.greenComponent, s.blueComponent]
        }
        let expectRed = srgb(NSColor(srgbRed: 0xff / 255, green: 0x5c / 255, blue: 0x5c / 255, alpha: 1))
        let expectDefault = srgb(NSColor(srgbRed: 0x3d / 255, green: 0xd6 / 255, blue: 0xc0 / 255, alpha: 1))
        for (a, b) in zip(srgb(TimelinePalette.markerColor(red)), expectRed) { XCTAssertEqual(a, b, accuracy: 0.001) }
        for (a, b) in zip(srgb(TimelinePalette.markerColor(plain)), expectDefault) { XCTAssertEqual(a, b, accuracy: 0.001) }
    }
}
