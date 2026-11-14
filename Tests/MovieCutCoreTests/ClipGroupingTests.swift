import XCTest
@testable import MovieCutCore

/// クリップのグループ化(土台): 往復・メンバ・選択拡張・付け外し・一括移動。
final class ClipGroupingTests: XCTestCase {
    private func project() -> Project {
        var p = Project(); p.characters = []
        func clip(_ id: String, _ start: Double, group: String? = nil) -> Clip {
            var c = Clip(); c.id = id; c.type = .image; c.start = start; c.duration = 2; c.group = group
            return c
        }
        var t1 = Track(name: "上"); t1.clips = [clip("a", 0, group: "g1"), clip("b", 3)]
        var t2 = Track(name: "下"); t2.clips = [clip("c", 1, group: "g1"), clip("d", 5, group: "g2")]
        p.tracks = [t1, t2]
        return p
    }

    func testRoundTrip() throws {
        var c = Clip(); c.group = "g1"
        let data = try JSONEncoder().encode(c)
        XCTAssertTrue(String(data: data, encoding: .utf8)?.contains("\"group\":\"g1\"") ?? false)
        XCTAssertEqual(try JSONDecoder().decode(Clip.self, from: data).group, "g1")
        let plain = try JSONEncoder().encode(Clip())
        XCTAssertFalse(String(data: plain, encoding: .utf8)?.contains("\"group\"") ?? true)
    }

    func testMembersAndExpand() {
        let p = project()
        XCTAssertEqual(ClipGrouping.groupIds(in: p), ["g1", "g2"])
        XCTAssertEqual(ClipGrouping.members(of: "g1", in: p).map { $0.id }, ["a", "c"])
        XCTAssertEqual(ClipGrouping.expand(["a"], in: p), ["a", "c"])       // 片方を選ぶとグループ全員
        XCTAssertEqual(ClipGrouping.expand(["b"], in: p), ["b"])             // グループ無しはそのまま
        XCTAssertEqual(ClipGrouping.expand(["a", "d"], in: p), ["a", "c", "d"])
    }

    func testAssignAndShift() {
        var p = project()
        ClipGrouping.assign("g2", to: ["b"], in: &p)
        XCTAssertEqual(ClipGrouping.members(of: "g2", in: p).map { $0.id }, ["b", "d"])
        ClipGrouping.assign(nil, to: ["d"], in: &p)
        XCTAssertEqual(ClipGrouping.members(of: "g2", in: p).map { $0.id }, ["b"])

        // 一括移動: 頭が 0 未満にならないよう丸める
        let moved = ClipGrouping.shift(group: "g1", by: -2, in: &p)
        XCTAssertEqual(moved, 0)   // a が 0 にいるので負方向は動けない
        XCTAssertEqual(ClipGrouping.shift(group: "g1", by: 1.5, in: &p), 1.5)
        let starts = Dictionary(uniqueKeysWithValues: p.allClips.map { ($0.id, $0.start) })
        XCTAssertEqual(starts["a"], 1.5); XCTAssertEqual(starts["c"], 2.5); XCTAssertEqual(starts["b"], 3)
    }

    func testNextId() {
        var p = project()
        XCTAssertEqual(ClipGrouping.nextId(in: p), "group1")   // g1, g2 は形式が違うので空き
        ClipGrouping.assign("group1", to: ["b"], in: &p)
        XCTAssertEqual(ClipGrouping.nextId(in: p), "group2")
        ClipGrouping.assign("group3", to: ["c"], in: &p)
        XCTAssertEqual(ClipGrouping.nextId(in: p), "group2", "空いている一番小さい番号")
    }
}
