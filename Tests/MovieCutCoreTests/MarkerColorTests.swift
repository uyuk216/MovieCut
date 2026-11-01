import XCTest
@testable import MovieCutCore

/// マーカーの色(任意項目)。既定の色は書かず、未知の値は消さない。
final class MarkerColorTests: XCTestCase {
    private func json(_ p: Project) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: p.encoded()) as! [String: Any]
    }

    private func markerJSON(_ p: Project) throws -> [[String: Any]] {
        (try json(p)["markers"] as? [[String: Any]]) ?? []
    }

    func testDefaultColorIsNotWritten() throws {
        var p = Project()
        p.markers = [Marker(time: 1, name: "a")]
        XCTAssertNil(try markerJSON(p)[0]["color"], "既定の色は書かない")
        p.markers[0].color = MarkerColor.default.rawValue
        XCTAssertNil(try markerJSON(p)[0]["color"], "既定の色を明示しても書かない")
    }

    func testColorRoundTrip() throws {
        var p = Project()
        var m = Marker(time: 2, name: "サビ")
        m.color = MarkerColor.red.rawValue
        p.markers = [m]
        XCTAssertEqual(try markerJSON(p)[0]["color"] as? String, "red")
        let q = try Project.decode(from: p.encoded())
        XCTAssertEqual(q.markers.first?.color, "red")
        XCTAssertEqual(MarkerColor.resolved(q.markers.first?.color), .red)
        XCTAssertEqual(q, p)
    }

    func testOldFileWithoutColorDecodesAsDefault() throws {
        let text = #"{"markers":[{"id":"m1","time":3,"name":"旧"}]}"#
        let p = try Project.decode(from: Data(text.utf8))
        XCTAssertNil(p.markers.first?.color)
        XCTAssertEqual(MarkerColor.resolved(p.markers.first?.color), .teal)
    }

    /// 未知の色は表示では既定になるが、保存し直しても値が残る(新しい版の色を古い版が消さない)。
    func testUnknownColorIsKeptOnResave() throws {
        let text = #"{"markers":[{"id":"m1","time":3,"name":"新","color":"pink"}]}"#
        let p = try Project.decode(from: Data(text.utf8))
        XCTAssertEqual(p.markers.first?.color, "pink")
        XCTAssertEqual(MarkerColor.resolved(p.markers.first?.color), .teal)
        let q = try Project.decode(from: p.encoded())
        XCTAssertEqual(q.markers.first?.color, "pink")
    }

    func testSetColorChangesOnlyThatMarker() {
        var p = Project()
        let a = Marker(time: 1, name: "a"), b = Marker(time: 2, name: "b")
        p.markers = [a, b]
        guard let q = MarkerEditing.setColor(in: p, id: b.id, to: .blue) else { return XCTFail("変わるはず") }
        XCTAssertEqual(q.markers.first { $0.id == b.id }?.color, "blue")
        XCTAssertNil(q.markers.first { $0.id == a.id }?.color)
    }

    func testSetColorNoOpCases() {
        var p = Project()
        var m = Marker(time: 1, name: "a")
        m.color = MarkerColor.green.rawValue
        p.markers = [m]
        XCTAssertNil(MarkerEditing.setColor(in: p, id: m.id, to: .green), "同じ色は変えない")
        XCTAssertNil(MarkerEditing.setColor(in: p, id: "なし", to: .red), "無い ID は変えない")
        // 既定(teal)へ戻すと nil になって書かれない
        guard let back = MarkerEditing.setColor(in: p, id: m.id, to: .default) else { return XCTFail() }
        XCTAssertNil(back.markers[0].color)
    }

    func testColorPaletteIsDistinct() {
        let hexes = MarkerColor.allCases.map(\.hex)
        XCTAssertEqual(Set(hexes).count, MarkerColor.allCases.count)
        XCTAssertEqual(Set(MarkerColor.allCases.map(\.title)).count, MarkerColor.allCases.count)
    }

    /// 未知の色の目印を「既定の色」に直せる(表示は既定でも、保存の値が残ると色の選び直しが効かない)。
    func testPickingDefaultColorClearsUnknownStoredColor() {
        var p = Project()
        var m = Marker(time: 1, name: "a")
        m.color = "magenta"
        p.markers = [m]
        guard let q = MarkerEditing.setColor(in: p, id: m.id, to: .default) else { return XCTFail("未知の色から既定へ直せるはず") }
        XCTAssertNil(q.markers[0].color)
    }
}
