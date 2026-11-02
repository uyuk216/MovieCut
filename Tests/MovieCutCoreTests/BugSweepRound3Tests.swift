import XCTest
@testable import MovieCutCore

/// 機能追加後の掃除(2026-11-02 3 回目): ロックを、クリップ単位・レイヤー単位の両方で、一括操作・複合・文字の編集・追加でも守る。
/// 先に失敗するテストとして書いた。
final class BugSweepRound3Tests: XCTestCase {
    private func text(_ id: String, _ body: String, locked: Bool = false) -> Clip {
        var c = Clip(); c.id = id; c.type = .text; c.text = body; c.start = 0; c.duration = 2; c.fontSize = 80
        if locked { c.locked = true }
        return c
    }

    private func image(_ id: String, start: Double, dur: Double, locked: Bool = false) -> Clip {
        var c = Clip(); c.id = id; c.type = .image; c.src = "/nonexistent/x.png"; c.start = start; c.duration = dur
        if locked { c.locked = true }
        return c
    }

    private var look: TextLook {
        var l = TextLook()
        l.color = "#ff0000"
        return l
    }

    /// 単体の複製: 元がロックされたレイヤーのクリップなら、そのレイヤーへ複製を足さない(拒否する)。
    func testDuplicateOfClipOnLockedLayerIsRefused() {
        var t0 = Track(name: "映像")
        t0.locked = true
        t0.clips = [image("a", start: 0, dur: 4)]
        var p = Project()
        p.tracks = [t0]
        XCTAssertNil(ClipEditing.duplicate(in: p, clipId: "a"), "ロックされたレイヤーに複製が足された")
    }

    /// 文字スタイルの一括適用: クリップ単位でロックされた文字は変えない(数は lockedSkipped)。
    func testTextStyleBulkSkipsClipLockedText() {
        var p = Project.new()
        p.tracks[0].clips = [text("a", "a"), text("b", "b", locked: true)]
        let r = TextStyleBulk.apply(look, to: p)
        XCTAssertEqual(r.changedIds, ["a"])
        XCTAssertEqual(r.lockedSkipped, 1, "クリップのロックを数えていない")
        XCTAssertNil(r.project.allClips.first { $0.id == "b" }?.color, "ロックされた文字が変わった")
    }

    /// 検索と置換: クリップ単位でロックされた文字は置き換えない。
    func testTextReplaceSkipsClipLockedText() {
        var p = Project.new()
        p.tracks[0].clips = [text("a", "foo"), text("b", "foo", locked: true)]
        let r = TextSearch.replaceAll("foo", with: "bar", in: p)
        XCTAssertEqual(r.count, 1, "ロックされた文字も置き換えられた")
        XCTAssertEqual(r.lockedMatches, 1)
        XCTAssertEqual(r.project.allClips.first { $0.id == "b" }?.text, "foo")
    }

    /// 複合クリップにまとめるとき、クリップ単位でロックされた子があれば拒否する(まとめると元のレイヤーから外れてしまう)。
    func testCompoundGroupRefusesClipLockedMember() {
        var p = Project.new()
        p.tracks[0].clips = [image("a", start: 0, dur: 2), image("b", start: 2, dur: 2, locked: true)]
        XCTAssertNil(CompoundEditing.group(p, clipIds: ["a", "b"]), "ロックされたクリップが複合に取り込まれた")
    }

    /// 複合クリップの解除: 複合自体がロックされていれば解除しない。
    func testUngroupRefusesLockedCompound() throws {
        var p = Project.new()
        p.tracks[0].clips = [image("a", start: 0, dur: 2), image("b", start: 2, dur: 2)]
        let g = try XCTUnwrap(CompoundEditing.group(p, clipIds: ["a", "b"]))
        var q = g.project
        for ti in q.tracks.indices {
            for ci in q.tracks[ti].clips.indices where q.tracks[ti].clips[ci].id == g.compoundId {
                q.tracks[ti].clips[ci].locked = true
            }
        }
        XCTAssertNil(CompoundEditing.ungroup(q, clipId: g.compoundId), "ロックされた複合が解除された")
    }

    /// 字幕の直し: ロックされた文字クリップの本文は変えない。
    func testSubtitleTextUpdateRefusesLockedClip() {
        var p = Project.new()
        p.tracks[0].clips = [text("a", "旧", locked: true)]
        XCTAssertNil(SubtitleQuickAdd.updateText(clipId: "a", text: "新", in: p), "ロックされた字幕が直された")
    }

    /// テキスト・ぼかし・調整などの追加: 一番上のレイヤーがロックされていれば、そこへは足さない。
    func testTopLayerAddNeverLandsOnLockedLayer() {
        var p = Project.new()
        let top = p.tracks.count - 1
        p.tracks[top].locked = true
        let lockedBefore = p.tracks[top].clips.count
        var c = text("n", "新しい文字")
        c.start = 1
        ClipEditing.appendToTopLayer(c, in: &p)
        XCTAssertEqual(p.tracks[top].clips.count, lockedBefore, "ロックされたレイヤーに文字が足された")
        XCTAssertTrue(p.allClips.contains { $0.id == "n" }, "文字が足されていない")
        XCTAssertTrue(p.tracks.last.map { !$0.isLocked && $0.clips.contains { $0.id == "n" } } ?? false)
    }

    /// 古い書類(mediaPool が無い): 未使用の素材は空で、クリップが使う素材は出ない。保存しても mediaPool のキーは増えない。
    func testLegacyProjectWithoutMediaPoolShowsNoUnusedMedia() throws {
        let json = """
        {"width":1920,"height":1080,"fps":30,"tracks":[{"name":"映像","clips":[{"id":"a","type":"image","src":"/x/a.png","start":0,"duration":2}]}]}
        """
        let p = try Project.decode(from: Data(json.utf8))
        XCTAssertTrue(p.mediaPool.isEmpty)
        XCTAssertEqual(UnusedMedia.find(in: p).count, 0)
        let saved = try p.encoded()
        XCTAssertFalse(String(decoding: saved, as: UTF8.self).contains("\"mediaPool\""), "古い書類を保存すると mediaPool が増えた")
    }
}
