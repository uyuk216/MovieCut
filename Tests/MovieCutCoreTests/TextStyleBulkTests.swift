import XCTest
@testable import MovieCutCore

/// 文字スタイルの一括適用(TextStyleBulk): 文字クリップだけ、選択の範囲、ロックされたレイヤーは変えない、変わらなければ空。
final class TextStyleBulkTests: XCTestCase {
    private func text(_ id: String, color: String? = nil, outline: String? = nil) -> Clip {
        var c = Clip(); c.id = id; c.type = .text; c.text = id; c.start = 0; c.duration = 2; c.fontSize = 80; c.color = color; c.outline = outline
        return c
    }

    private var look: TextLook {
        var l = TextLook()
        l.color = "#ff0000"
        l.outline = "#000000"
        return l
    }

    private func project() -> Project {
        var p = Project.new()
        var v = Clip(); v.id = "v"; v.type = .voice; v.text = "声"; v.start = 0; v.duration = 1; v.charId = "c"
        p.tracks[0].clips = [text("a"), v]
        p.tracks[1].clips = [text("b", color: "#ff0000", outline: "#000000")]
        return p
    }

    func testAppliesToAllTextClipsOnly() {
        let r = TextStyleBulk.apply(look, to: project())
        XCTAssertEqual(r.changedIds, ["a"], "b は既に同じ見た目なので変わらない・ボイスは対象外")
        XCTAssertEqual(r.project.allClips.first { $0.id == "a" }?.color, "#ff0000")
        XCTAssertEqual(r.project.allClips.first { $0.id == "v" }?.color, nil)
    }

    func testScopeLimitsToSelection() {
        let r = TextStyleBulk.apply(look, to: project(), scope: ["b"])
        XCTAssertTrue(r.changedIds.isEmpty)
        let r2 = TextStyleBulk.apply(look, to: project(), scope: ["a"])
        XCTAssertEqual(r2.changedIds, ["a"])
    }

    func testLockedLayerIsSkippedAndCounted() {
        var p = project()
        p.tracks[0].locked = true
        let r = TextStyleBulk.apply(look, to: p)
        XCTAssertTrue(r.changedIds.isEmpty)
        XCTAssertEqual(r.lockedSkipped, 1)
        XCTAssertEqual(r.project, p)
    }

    func testNothingChangesWhenLookAlreadyApplied() {
        let once = TextStyleBulk.apply(look, to: project()).project
        let again = TextStyleBulk.apply(look, to: once)
        XCTAssertTrue(again.changedIds.isEmpty)
        XCTAssertEqual(again.project, once)
    }
}
