import XCTest
@testable import MovieCutCore

/// 台本(文字起こし)とタイムラインの双方向編集(`TranscriptScripting`)。
final class TranscriptScriptingTests: XCTestCase {

    private let sentences: [TranscriptSentence] = [
        TranscriptSentence(text: "一文目。", start: 0, end: 0.5),
        TranscriptSentence(text: "二文目。", start: 0.6, end: 1.0),
        TranscriptSentence(text: "三文目。", start: 1.2, end: 1.9),
    ]

    /// 2 秒の音声クリップ(素材の 0.5 秒目から。start 1 秒)1 本。
    private func project(extra: [Clip] = []) -> Project {
        var c = Clip(); c.id = "src"; c.type = .audio; c.start = 1; c.duration = 2; c.offset = 0.5; c.src = "/tmp/a.wav"
        var t = Track(name: "音"); t.clips = [c] + extra
        var p = Project.new(); p.tracks = [t]
        return p
    }

    private func linked(extra: [Clip] = []) -> (Project, TranscriptScript) {
        let r = TranscriptScripting.link(in: project(extra: extra), clipId: "src", sentences: sentences)!
        return (r.project, TranscriptScripting.script(withId: r.scriptId, in: r.project)!)
    }

    private func clips(_ p: Project) -> [Clip] { p.tracks[0].clips.sorted { $0.start < $1.start } }

    // MARK: 対応付け

    func testLinkTilesTheClipBySentenceStarts() {
        let (p, sc) = linked()
        let cs = clips(p)
        XCTAssertEqual(cs.count, 3)
        // 切れ目は文の開始(0 / 0.6 / 1.2)、長さの合計と先頭位置は元のまま
        for (d, e) in zip(cs.map(\.duration), [0.6, 0.6, 0.8]) { XCTAssertEqual(d, e, accuracy: 1e-9) }
        XCTAssertEqual(cs[0].start, 1, accuracy: 1e-9)
        XCTAssertEqual(cs[2].start + cs[2].duration, 3, accuracy: 1e-9)
        XCTAssertEqual(cs[0].offset, 0.5, accuracy: 1e-9)
        XCTAssertEqual(cs[1].offset, 1.1, accuracy: 1e-9)
        XCTAssertEqual(cs[0].id, "src", "最初の断片は元の id を引き継ぐ")
        XCTAssertEqual(Set(cs.map(\.id)).count, 3)
        // 文は素材時刻で、クリップと同じ範囲を受け持つ
        XCTAssertEqual(sc.sentences.map(\.text), ["一文目。", "二文目。", "三文目。"])
        XCTAssertEqual(sc.sentences[1].start, 1.1, accuracy: 1e-9)
        XCTAssertEqual(sc.sentences[1].end, 1.7, accuracy: 1e-9)
        for (c, s) in zip(cs, sc.sentences) { XCTAssertEqual(c.scriptSentenceId, s.id) }
        let rows = TranscriptScripting.rows(of: sc, in: p)
        XCTAssertEqual(rows.map(\.coverage), [.linked, .linked, .linked])
        XCTAssertEqual(rows.map(\.sentence.text), ["一文目。", "二文目。", "三文目。"])
    }

    func testLinkRefusesUnsupportedAndDuplicates() {
        var p = project()
        p.tracks[0].clips[0].speed = 2
        XCTAssertNil(TranscriptScripting.link(in: p, clipId: "src", sentences: sentences), "速度変更は対象外")
        p.tracks[0].clips[0].speed = nil
        p.tracks[0].clips[0].reverse = true
        XCTAssertNil(TranscriptScripting.link(in: p, clipId: "src", sentences: sentences), "逆再生は対象外")
        p.tracks[0].clips[0].reverse = nil
        p.tracks[0].locked = true
        XCTAssertNil(TranscriptScripting.link(in: p, clipId: "src", sentences: sentences), "ロック中は断る")
        p.tracks[0].locked = nil
        XCTAssertNil(TranscriptScripting.link(in: p, clipId: "src", sentences: []))
        let dup = [TranscriptSentence(text: "a", start: 0, end: 0.4), TranscriptSentence(text: "b", start: 0.5, end: 0.9), TranscriptSentence(text: "c", start: 0.5, end: 1.0)]
        XCTAssertNil(TranscriptScripting.link(in: p, clipId: "src", sentences: dup), "開始が同じ文は黙って潰さず断る")
        let (done, _) = linked()
        XCTAssertNil(TranscriptScripting.link(in: done, clipId: "src", sentences: sentences), "同じ素材の台本は 1 つ")
    }

    func testPersistenceRoundTripAndBackwardCompat() throws {
        let (p, sc) = linked()
        let data = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(Project.self, from: data)
        XCTAssertEqual(back.transcriptScripts, [sc])
        XCTAssertEqual(clips(back).map(\.scriptSentenceId), clips(p).map(\.scriptSentenceId))
        XCTAssertEqual(TranscriptScripting.rows(of: back.transcriptScripts[0], in: back).map(\.coverage), [.linked, .linked, .linked])
        // 台本を使っていないプロジェクトにはキーを書かない(従来と完全一致)
        let plain = String(data: try JSONEncoder().encode(project()), encoding: .utf8)!
        XCTAssertFalse(plain.contains("transcriptScripts"))
        XCTAssertFalse(plain.contains("scriptSentenceId"))
    }

    // MARK: 台本 → タイムライン

    func testDeleteSentenceRemovesRangeAndKeepsItAsUnlinked() {
        let (p, sc) = linked()
        let target = sc.sentences[1].id
        let out = TranscriptScripting.deleteSentence(in: p, scriptId: sc.id, sentenceId: target, ripple: true)!
        let cs = clips(out)
        XCTAssertEqual(cs.count, 2)
        XCTAssertEqual(cs[1].start, 1.6, accuracy: 1e-9, "後ろを詰める")
        let rows = TranscriptScripting.rows(of: out.transcriptScripts[0], in: out)
        XCTAssertEqual(rows.map(\.coverage), [.linked, .unlinked, .linked], "対応なしとして台本に残る")
        XCTAssertEqual(rows[1].sentence.text, "二文目。")
        XCTAssertEqual(out.transcriptScripts[0].sentences.count, 3, "黙って消さない")
        // 詰めないとき
        let gap = TranscriptScripting.deleteSentence(in: p, scriptId: sc.id, sentenceId: target, ripple: false)!
        XCTAssertEqual(clips(gap)[1].start, 2.2, accuracy: 1e-9)
        // 二度目は対応クリップが無いので nil
        XCTAssertNil(TranscriptScripting.deleteSentence(in: out, scriptId: sc.id, sentenceId: target, ripple: true))
    }

    func testDeleteMatchesRemovingTheRangeWithExistingRippleDelete() {
        // 既存の経路(ClipEditing.rippleDelete)で同じ断片を消した結果と一致する
        let (p, sc) = linked()
        let id = clips(p)[1].id
        let viaExisting = ClipEditing.rippleDelete(in: p, clipId: id)!
        let viaScript = TranscriptScripting.deleteSentence(in: p, scriptId: sc.id, sentenceId: sc.sentences[1].id, ripple: true)!
        XCTAssertEqual(clips(viaExisting).map(\.start), clips(viaScript).map(\.start))
        XCTAssertEqual(clips(viaExisting).map(\.offset), clips(viaScript).map(\.offset))
        XCTAssertEqual(clips(viaExisting).map(\.duration), clips(viaScript).map(\.duration))
    }

    func testReorderRearrangesClipsAndMatchesPaperEditOrder() {
        let (p, sc) = linked()
        // 三文目を先頭へ(Paper Edit の並び [2, 0, 1] と同じ結果)
        let out = TranscriptScripting.reorder(in: p, scriptId: sc.id, fromOffsets: IndexSet(integer: 2), toOffset: 0)!
        let cs = clips(out)
        XCTAssertEqual(cs.map(\.scriptSentenceId), [sc.sentences[2].id, sc.sentences[0].id, sc.sentences[1].id])
        XCTAssertEqual(cs[0].start, 1, accuracy: 1e-9)
        XCTAssertEqual(cs[1].start, 1.8, accuracy: 1e-9)
        XCTAssertEqual(cs[2].start, 2.4, accuracy: 1e-9)
        XCTAssertEqual(cs[0].duration, 0.8, accuracy: 1e-9)
        // 素材範囲は変わらない(元クリップの offset のまま)
        XCTAssertEqual(cs[0].offset, 1.7, accuracy: 1e-9)
        // 総尺は変わらない
        XCTAssertEqual(cs.last!.start + cs.last!.duration, 3, accuracy: 1e-9)
        // Paper Edit の組み立て結果(同じ並びの subclip)と素材範囲・長さが一致する
        let src = project().tracks[0].clips[0]
        let assembled = PaperEdit.clips(source: src, ordered: PaperEdit.orderedSentences(from: sentences, order: [2, 0, 1]), startAt: 1)!
        XCTAssertEqual(assembled.count, 3)
        XCTAssertEqual(assembled[0].offset, cs[0].offset, accuracy: 1e-9)
        XCTAssertEqual(assembled[0].duration, 0.7, accuracy: 1e-9, "Paper Edit は文の区間ちょうど(無音を含めない)")
        // 台本の表示順もタイムラインに追随する
        let rows = TranscriptScripting.rows(of: out.transcriptScripts[0], in: out)
        XCTAssertEqual(rows.map(\.sentence.text), ["三文目。", "一文目。", "二文目。"])
        // 不正な指定
        XCTAssertNil(TranscriptScripting.reorder(in: p, scriptId: sc.id, fromOffsets: IndexSet(integer: 9), toOffset: 0))
        XCTAssertNil(TranscriptScripting.reorder(in: p, scriptId: sc.id, fromOffsets: IndexSet(integer: 1), toOffset: 1), "動かさないなら nil")
    }

    func testReorderRefusesToOverlapUnlinkedClip() {
        var other = Clip(); other.id = "other"; other.type = .audio; other.start = 3.0; other.duration = 1; other.src = "/tmp/b.wav"
        // 台本のクリップの間に台本と無関係なクリップを置いて、敷き直しでぶつかるようにする
        var (p, sc) = linked(extra: [other])
        p.tracks[0].clips[p.tracks[0].clips.firstIndex { $0.id == "other" }!].start = 2.0
        p.tracks[0].clips[p.tracks[0].clips.firstIndex { $0.scriptSentenceId == sc.sentences[1].id }!].start = 2.8  // 間を空ける
        _ = sc
        XCTAssertNil(TranscriptScripting.reorder(in: p, scriptId: sc.id, fromOffsets: IndexSet(integer: 2), toOffset: 0))
    }

    func testRestoreBringsBackADeletedSentenceInScriptOrder() {
        let (p, sc) = linked()
        let id = sc.sentences[0].id
        let del = TranscriptScripting.deleteSentence(in: p, scriptId: sc.id, sentenceId: id, ripple: true)!
        let back = TranscriptScripting.restoreSentence(in: del, scriptId: sc.id, sentenceId: id)!
        let rows = TranscriptScripting.rows(of: back.transcriptScripts[0], in: back)
        // 復元した文は台本の並び(先頭)の位置ではなく、表示はタイムライン順(復元後は敷き直しで台本順)
        XCTAssertEqual(rows.map(\.coverage), [.linked, .linked, .linked])
        XCTAssertEqual(clips(back).first?.scriptSentenceId, id)
        XCTAssertEqual(clips(back).first!.start, 1, accuracy: 1e-9)
        XCTAssertNil(TranscriptScripting.restoreSentence(in: back, scriptId: sc.id, sentenceId: id), "対応済みの文は復元できない")
    }

    // MARK: タイムライン → 台本

    func testTimelineDeleteAndSplitAreReflectedInRows() {
        let (p, sc) = linked()
        let cs = clips(p)
        // 分割: どちらの断片も同じ文を指すので、状態は対応済みのまま
        let sp = ClipEditing.split(in: p, clipId: cs[1].id, at: cs[1].start + 0.3)!
        let split = sp.project
        var rows = TranscriptScripting.rows(of: sc, in: split)
        XCTAssertEqual(rows.map(\.coverage), [.linked, .linked, .linked])
        XCTAssertEqual(rows[1].clipIds.count, 2)
        // 分割した片方を削除: 一部
        let rightId = sp.rightId
        let partial = ClipEditing.delete(in: split, clipId: rightId)!
        rows = TranscriptScripting.rows(of: sc, in: partial)
        XCTAssertEqual(rows.map(\.coverage), [.linked, .partial, .linked])
        // 残りも削除: 対応なし
        let gone = ClipEditing.delete(in: partial, clipId: cs[1].id)!
        rows = TranscriptScripting.rows(of: sc, in: gone)
        XCTAssertEqual(rows.map(\.coverage), [.linked, .unlinked, .linked])
        XCTAssertEqual(rows.count, 3, "対応が切れても行は残る")
        XCTAssertEqual(rows[1].clipIds, [])
    }

    func testTimelineMoveReordersRows() {
        var (p, sc) = linked()
        // タイムライン側で一文目のクリップを一番後ろへ動かす(直接 start を書き換える)
        let first = p.tracks[0].clips.firstIndex { $0.scriptSentenceId == sc.sentences[0].id }!
        p.tracks[0].clips[first].start = 5
        let rows = TranscriptScripting.rows(of: sc, in: p)
        XCTAssertEqual(rows.map(\.sentence.text), ["二文目。", "三文目。", "一文目。"])
        XCTAssertEqual(rows.map(\.coverage), [.linked, .linked, .linked])
        _ = sc
    }

    func testTrimMakesSentencePartial() {
        var (p, sc) = linked()
        let i = p.tracks[0].clips.firstIndex { $0.scriptSentenceId == sc.sentences[2].id }!
        p.tracks[0].clips[i].duration = 0.4   // 右端を詰めた
        XCTAssertEqual(TranscriptScripting.rows(of: sc, in: p).map(\.coverage), [.linked, .linked, .partial])
        _ = sc
    }

    // MARK: 打ち直し・解除

    func testRetextChangesOnlyScriptText() {
        let (p, sc) = linked()
        let out = TranscriptScripting.retext(in: p, scriptId: sc.id, sentenceId: sc.sentences[1].id, text: "  二番目の文。 ")!
        XCTAssertEqual(out.transcriptScripts[0].sentences[1].text, "二番目の文。")
        XCTAssertEqual(out.transcriptScripts[0].sentences[1].edited, true)
        XCTAssertEqual(out.tracks, p.tracks, "タイムラインは変わらない")
        XCTAssertNil(TranscriptScripting.retext(in: p, scriptId: sc.id, sentenceId: sc.sentences[1].id, text: "   "))
        XCTAssertNil(TranscriptScripting.retext(in: p, scriptId: sc.id, sentenceId: sc.sentences[1].id, text: "二文目。"))
    }

    func testUnlinkClearsMarksButKeepsClips() {
        let (p, sc) = linked()
        let out = TranscriptScripting.unlink(in: p, scriptId: sc.id)!
        XCTAssertTrue(out.transcriptScripts.isEmpty)
        XCTAssertEqual(clips(out).count, 3)
        XCTAssertTrue(clips(out).allSatisfy { $0.scriptSentenceId == nil })
    }
}
