import XCTest
import CoreGraphics
@testable import MovieCutCore

/// 複合クリップの中を編集する(根と見え方の往復・入れ子・ロック・パンくず)と、中で編集したあとの描画が「平らにした場合」と一致すること。
final class CompoundScopeTests: XCTestCase {
    let helper = CompoundTests()
    override func setUpWithError() throws { try helper.setUpWithError() }
    override func tearDownWithError() throws { try helper.tearDownWithError() }

    func grouped() throws -> (flat: Project, grouped: Project, id: String) {
        let p = try helper.sampleProject()
        let r = try XCTUnwrap(CompoundEditing.group(p, clipIds: ["c1", "c2", "c3"]))
        return (p, r.project, r.compoundId)
    }

    func testViewShowsInnerLayersAndEmbedRoundTrips() throws {
        let g = try grouped()
        let v = try XCTUnwrap(CompoundScope.view(of: g.grouped, path: [g.id]))
        XCTAssertEqual(v.allClips.map(\.id).sorted(), ["c1", "c2", "c3"])
        XCTAssertEqual(v.width, g.grouped.width)
        XCTAssertEqual(try XCTUnwrap(CompoundScope.embed(view: v, into: g.grouped, path: [g.id])), g.grouped, "触らなければ根と同じ")
        XCTAssertEqual(CompoundScope.view(of: g.grouped, path: []), g.grouped)
        XCTAssertNil(CompoundScope.view(of: g.grouped, path: ["nope"]))
        XCTAssertNil(CompoundScope.view(of: g.grouped, path: [g.id, "c1"]), "複合クリップでないものには入れない")
    }

    func testEmbedKeepsNonTrackSettingsFromTheView() throws {
        let g = try grouped()
        var v = try XCTUnwrap(CompoundScope.view(of: g.grouped, path: [g.id]))
        v.bg = "#ff0000"
        let root = try XCTUnwrap(CompoundScope.embed(view: v, into: g.grouped, path: [g.id]))
        XCTAssertEqual(root.bg, "#ff0000")
        XCTAssertEqual(root.tracks, g.grouped.tracks)
    }

    func testNestedPathAndBreadcrumb() throws {
        let g = try grouped()
        // 外側の複合の中で、さらに c1 と c2 をまとめる
        var v = try XCTUnwrap(CompoundScope.view(of: g.grouped, path: [g.id]))
        let inner = try XCTUnwrap(CompoundEditing.group(v, clipIds: ["c1", "c2"]))
        v = inner.project
        let root = try XCTUnwrap(CompoundScope.embed(view: v, into: g.grouped, path: [g.id]))
        let deep = try XCTUnwrap(CompoundScope.view(of: root, path: [g.id, inner.compoundId]))
        XCTAssertEqual(deep.allClips.map(\.id).sorted(), ["c1", "c2"])
        var edited = deep
        edited.tracks[0].clips[0].x = 0.9
        let root2 = try XCTUnwrap(CompoundScope.embed(view: edited, into: root, path: [g.id, inner.compoundId]))
        XCTAssertNotEqual(root2, root)
        XCTAssertEqual(try XCTUnwrap(CompoundScope.view(of: root2, path: [g.id, inner.compoundId])).tracks, edited.tracks)
        XCTAssertEqual(CompoundScope.breadcrumb(root, path: [g.id, inner.compoundId]), ["プロジェクト", "複合クリップ 1", "複合クリップ 2"])
        var named = root
        let ti = try XCTUnwrap(named.tracks.firstIndex { $0.clips.contains { $0.id == g.id } })
        named.tracks[ti].clips[0].note = "オープニング"
        XCTAssertEqual(CompoundScope.breadcrumb(named, path: [g.id]), ["プロジェクト", "オープニング"])
    }

    func testAncestorLocks() throws {
        let g = try grouped()
        XCTAssertFalse(CompoundScope.ancestorLocked(g.grouped, path: [g.id]))
        var a = g.grouped
        let ti = try XCTUnwrap(a.tracks.firstIndex { $0.clips.contains { $0.id == g.id } })
        a.tracks[ti].locked = true
        XCTAssertTrue(CompoundScope.ancestorLocked(a, path: [g.id]), "複合クリップのあるレイヤーのロック")
        var b = g.grouped
        let ci = try XCTUnwrap(b.tracks[ti].clips.firstIndex { $0.id == g.id })
        b.tracks[ti].clips[ci].locked = true
        XCTAssertTrue(CompoundScope.ancestorLocked(b, path: [g.id]), "複合クリップ自身のロック")
        XCTAssertFalse(CompoundScope.ancestorLocked(b, path: []))
    }

    /// 中で編集(分割して片方を消す・動かす)してから描いた画素は、同じ編集をした平らなクリップを描いた画素と一致する。
    func testRenderAfterInnerEditsEqualsFlattened() throws {
        let g = try grouped()
        // 中の見え方で編集: c1 を 1.0 秒(複合の頭から)で分割して右を消し、c2 を動かす
        var v = try XCTUnwrap(CompoundScope.view(of: g.grouped, path: [g.id]))
        let split = try XCTUnwrap(ClipEditing.split(in: v, clipId: "c1", at: 1.0))
        v = split.project
        let right = try XCTUnwrap(v.allClips.first { $0.id != "c1" && $0.id != "c2" && $0.id != "c3" }).id
        v = try XCTUnwrap(ClipEditing.delete(in: v, clipId: right))
        let ti = try XCTUnwrap(v.tracks.firstIndex { $0.clips.contains { $0.id == "c2" } })
        v.tracks[ti].clips[0].x = 0.25
        let root = try XCTUnwrap(CompoundScope.embed(view: v, into: g.grouped, path: [g.id]))
        // 平らにして比べる(解除)
        let flat = try XCTUnwrap(CompoundEditing.ungroup(root, clipId: g.id)).project
        XCTAssertFalse(flat.allClips.contains { $0.type == .compound })
        for t in [0.3, 0.9, 1.4, 2.2, 3.0] {
            XCTAssertEqual(helper.maxDiff(try helper.render(root, t: t), try helper.render(flat, t: t)), 0, "t=\(t)")
        }
        // 実際に編集で絵が変わっている(c1 は 1.0 秒より後ろでは消える)
        XCTAssertGreaterThan(helper.maxDiff(try helper.render(root, t: 2.0), try helper.render(g.grouped, t: 2.0)), 0)
    }
}
