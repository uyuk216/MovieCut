import XCTest
@testable import MovieCutCore

/// M7: マーカー(Project.markers)の保存形式と編集。
final class MarkerTests: XCTestCase {
    private func json(_ p: Project) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: p.encoded()) as! [String: Any]
    }

    // MARK: 保存形式

    func testEmptyMarkersAreNotSaved() throws {
        let j = try json(Project())
        XCTAssertNil(j["markers"], "マーカーが無いときはキーごと書かない")
    }

    func testMarkersRoundTrip() throws {
        var p = Project()
        p.markers = [Marker(time: 1.5, name: "イントロ"), Marker(time: 9, name: "サビ")]
        let j = try json(p)
        XCTAssertEqual((j["markers"] as? [[String: Any]])?.count, 2)
        let q = try Project.decode(from: p.encoded())
        XCTAssertEqual(q.markers, p.markers)
        XCTAssertEqual(q, p)
    }

    func testOlderFilesWithoutMarkersDecode() throws {
        let data = Data(#"{"width":1280,"height":720,"fps":30,"tracks":[{"id":"t","name":"x","clips":[]}]}"#.utf8)
        let p = try Project.decode(from: data)
        XCTAssertEqual(p.markers, [])
        XCTAssertEqual(p.width, 1280)
        // 既存のフィクスチャ(旧 Electron 版・リッチ)も読める
        for name in ["electron-made", "rich"] {
            let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "ymproj", subdirectory: "Fixtures"))
            XCTAssertEqual(try Project.load(from: url).markers, [], name)
        }
    }

    func testMarkerDecodingIsLenientAndKeepsUnknownKeys() throws {
        let data = Data(##"{"markers":[{"id":"m1","time":"oops","name":3,"color":"#fff","nested":{"a":[1,2]}},{"time":2.5}],"futureKey":{"x":1}}"##.utf8)
        let p = try Project.decode(from: data)
        XCTAssertEqual(p.markers.count, 2)
        XCTAssertEqual(p.markers[0].id, "m1")
        XCTAssertEqual(p.markers[0].time, 0, "型が違う値は既定に")
        XCTAssertEqual(p.markers[0].name, "")
        XCTAssertEqual(p.markers[0].color, "#fff", "色は任意項目として読み、未知の値は残す")
        XCTAssertEqual(p.markers[1].time, 2.5)
        XCTAssertFalse(p.markers[1].id.isEmpty)
        XCTAssertNotNil(p.extra["futureKey"], "プロジェクトの知らないキーも残る")
        let j = try json(try Project.decode(from: p.encoded()))
        let m0 = (j["markers"] as! [[String: Any]])[0]
        XCTAssertEqual(m0["color"] as? String, "#fff", "マーカーの知らないキーも書き戻す")
        XCTAssertNotNil(m0["nested"])
        XCTAssertNotNil(j["futureKey"])
    }

    func testMarkersAreNotPartOfExtraAndNegativeTimeIsClamped() throws {
        let p = try Project.decode(from: Data(#"{"markers":[{"id":"a","time":-4,"name":"n"}]}"#.utf8))
        XCTAssertNil(p.extra["markers"])
        XCTAssertEqual(p.markers[0].time, 0)
    }

    func testMarkersDoNotChangeTheExportedLength() {
        var p = Project()
        var c = Clip(); c.type = .text; c.duration = 3
        p.tracks[0].clips = [c]
        let end = p.endTime
        p.markers = [Marker(time: 100, name: "遠い")]
        XCTAssertEqual(p.endTime, end, "書き出しの長さにはマーカーを含めない")
    }

    // MARK: 編集

    func testAddNamesMarkersInSequenceAndKeepsThemSorted() {
        var p = Project()
        let a = MarkerEditing.add(in: p, at: 5); p = a.project
        let b = MarkerEditing.add(in: p, at: 2); p = b.project
        XCTAssertEqual(p.markers.map(\.name), ["マーカー2", "マーカー1"], "名前は追加順の番号、並びは時刻順")
        XCTAssertEqual(p.markers.map(\.time), [2, 5])
        XCTAssertEqual(p.markers[1].id, a.id)
        // 消してから足しても、既存の最大の次の番号
        p = MarkerEditing.remove(in: p, id: b.id)!
        let c = MarkerEditing.add(in: p, at: 7); p = c.project
        XCTAssertEqual(p.markers.last?.name, "マーカー2")
        XCTAssertEqual(MarkerEditing.add(in: Project(), at: -3).project.markers[0].time, 0, "負の時刻は 0")
        XCTAssertEqual(MarkerEditing.add(in: p, at: 1, name: "好きな名前").project.markers.first?.name, "好きな名前")
    }

    func testNearestWithinTolerance() {
        var p = Project()
        p.markers = [Marker(time: 1, name: "a"), Marker(time: 1.02, name: "b"), Marker(time: 5, name: "c")]
        XCTAssertEqual(MarkerEditing.nearest(in: p, to: 1.019, tolerance: 1.0 / 60)?.name, "b")
        XCTAssertEqual(MarkerEditing.nearest(in: p, to: 1.0, tolerance: 1.0 / 60)?.name, "a")
        XCTAssertNil(MarkerEditing.nearest(in: p, to: 3, tolerance: 1.0 / 60))
        XCTAssertNil(MarkerEditing.nearest(in: p, to: 1.1, tolerance: 1.0 / 60))
        XCTAssertEqual(MarkerEditing.nearest(in: p, to: 5 + 1.0 / 60, tolerance: 1.0 / 60)?.name, "c", "ちょうど 1 コマはぎりぎり内")
    }

    func testRenameRemoveMoveAndClear() {
        var p = Project()
        p.markers = [Marker(time: 1, name: "a"), Marker(time: 3, name: "b")]
        let a = p.markers[0].id, b = p.markers[1].id
        XCTAssertEqual(MarkerEditing.rename(in: p, id: a, to: " 新 ")?.markers[0].name, "新")
        XCTAssertEqual(MarkerEditing.rename(in: p, id: a, to: "  ")?.markers[0].name, "a", "空の名前にはしない")
        XCTAssertNil(MarkerEditing.rename(in: p, id: "ghost", to: "x"))
        let moved = MarkerEditing.move(in: p, id: a, to: 8)!
        XCTAssertEqual(moved.markers.map(\.id), [b, a], "動かしたら時刻順に")
        XCTAssertEqual(MarkerEditing.move(in: p, id: a, to: -2)?.markers[0].time, 0)
        XCTAssertEqual(MarkerEditing.remove(in: p, id: a)?.markers.map(\.id), [b])
        XCTAssertNil(MarkerEditing.remove(in: p, id: "ghost"))
    }

    func testPreviousAndNextMarker() {
        var p = Project()
        p.markers = [Marker(time: 1, name: "a"), Marker(time: 3, name: "b"), Marker(time: 6, name: "c")]
        XCTAssertEqual(MarkerEditing.next(in: p, after: 3)?.name, "c", "同じ時刻のマーカーは飛ばす")
        XCTAssertEqual(MarkerEditing.previous(in: p, before: 3)?.name, "a")
        XCTAssertEqual(MarkerEditing.next(in: p, after: 0)?.name, "a")
        XCTAssertNil(MarkerEditing.next(in: p, after: 6))
        XCTAssertNil(MarkerEditing.previous(in: p, before: 1))
        XCTAssertEqual(MarkerEditing.previous(in: p, before: 100)?.name, "c")
    }
}
