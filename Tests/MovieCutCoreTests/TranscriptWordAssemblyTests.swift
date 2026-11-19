import XCTest
@testable import MovieCutCore

/// 単語単位の組み立て(Core): 単語の並びの解決(順序・繰り返し・解決できない指定は全体を失敗)、
/// 組み立て列の並べ替え(文の組み立てと同じ計算)、並べた順で組み立てられること。
final class TranscriptWordAssemblyTests: XCTestCase {

    func audioClip(id: String, start: Double, duration: Double, offset: Double = 0, src: String = "/x.wav") -> Clip {
        var c = Clip(); c.id = id; c.type = .audio; c.start = start; c.duration = duration; c.offset = offset; c.src = src
        return c
    }

    func word(_ text: String, _ a: Double, _ b: Double) -> TranscriptSegment {
        TranscriptSegment(text: text, start: a, end: b)
    }

    /// 6 秒クリップの 2 文(単語 2 件ずつ)。文 0: 一(0–2)・二(2–3.5)、文 1: 三(4–5)・四(5–6)。
    var timedSentences: [TranscriptSentence] {
        [
            TranscriptSentence(text: "一二", start: 0, end: 3.5, words: [word("一", 0, 2), word("二", 2, 3.5)]),
            TranscriptSentence(text: "三四", start: 4, end: 6, words: [word("三", 4, 5), word("四", 5, 6)]),
        ]
    }

    func projectWithSource() -> Project {
        var p = Project.new()
        var tr = Track(name: "音")
        tr.clips = [audioClip(id: "a", start: 0, duration: 6, offset: 10)]
        p.tracks = [tr]
        return p
    }

    typealias Sel = TranscriptWordEdit.Selection

    // MARK: 並びの解決

    func testResolvedWordsKeepGivenOrderAndRepeatDuplicates() throws {
        let got = try XCTUnwrap(TranscriptWordEdit.resolvedWords(
            sentences: timedSentences, order: [Sel(sentence: 1, word: 0), Sel(sentence: 0, word: 1), Sel(sentence: 1, word: 0)]))
        XCTAssertEqual(got.map(\.text), ["三", "二", "三"], "指定した並び順どおり(時刻順に戻さない・繰り返しも残す)")
        XCTAssertEqual(got.map(\.start), [4, 2, 4])
        XCTAssertEqual(got.map(\.end), [5, 3.5, 5])
    }

    func testResolvedWordsRejectUnresolvableSelectionsAsAWhole() {
        let wordless = TranscriptSentence(text: "時刻なし", start: 0, end: 2)
        let mixed = timedSentences + [wordless]
        XCTAssertNil(TranscriptWordEdit.resolvedWords(sentences: timedSentences, order: []), "空の並びは nil")
        XCTAssertNil(TranscriptWordEdit.resolvedWords(sentences: timedSentences, order: [Sel(sentence: 9, word: 0)]),
                     "範囲外の文は、黙って捨てず全体を失敗にする")
        XCTAssertNil(TranscriptWordEdit.resolvedWords(sentences: timedSentences, order: [Sel(sentence: 0, word: 9)]),
                     "範囲外の単語も全体を失敗にする")
        XCTAssertNil(TranscriptWordEdit.resolvedWords(sentences: mixed, order: [Sel(sentence: 0, word: 0), Sel(sentence: 2, word: 0)]),
                     "単語の時刻が無い文の単語が混ざったら全体を失敗にする(文に広げない)")
        let tooShort = TranscriptSentence(text: "x", start: 0, end: 1, words: [word("x", 0, 0.0005)])
        XCTAssertNil(TranscriptWordEdit.resolvedWords(sentences: [tooShort], order: [Sel(sentence: 0, word: 0)]),
                     "短すぎる単語の区間は組み立てられない")
    }

    // MARK: 組み立て列の並べ替え(文の組み立てと同じ計算)

    func testWordReorderHelpersMatchSentenceReorderSemantics() {
        let a = Sel(sentence: 0, word: 0), b = Sel(sentence: 0, word: 1)
        let c = Sel(sentence: 1, word: 0), d = Sel(sentence: 1, word: 1)
        let order = [a, b, c, d]
        XCTAssertEqual(TranscriptWordEdit.movingWords(order, from: 0, to: 2), [b, c, a, d], "抜いて行き先へ差す")
        XCTAssertEqual(TranscriptWordEdit.movingWords(order, from: 1, to: 1), order, "同じ位置はそのまま")
        XCTAssertEqual(TranscriptWordEdit.movingWords(order, from: 9, to: 0), order, "範囲外はそのまま")
        XCTAssertEqual(TranscriptWordEdit.reorderedWords(order, fromOffsets: [0], toOffset: 3), [b, c, a, d], "onMove と同じ意味")
        XCTAssertEqual(TranscriptWordEdit.reorderedWords(order, fromOffsets: [0, 1], toOffset: 4), [c, d, a, b], "複数件をまとめて末尾へ")
        XCTAssertEqual(TranscriptWordEdit.reorderedWords(order, fromOffsets: [], toOffset: 1), order, "空の指定はそのまま")
        XCTAssertEqual(TranscriptWordEdit.movingWordEntry(order, at: 1, by: -1), [b, a, c, d], "上へ")
        XCTAssertEqual(TranscriptWordEdit.movingWordEntry(order, at: 0, by: -1), order, "先頭で上へはそのまま")
        XCTAssertEqual(TranscriptWordEdit.movingWordEntry(order, at: 3, by: 1), order, "末尾で下へはそのまま")
        XCTAssertEqual(TranscriptWordEdit.movingWordEntryToEdge(order, at: 2, toEnd: false), [c, a, b, d], "先頭へ")
        XCTAssertEqual(TranscriptWordEdit.movingWordEntryToEdge(order, at: 1, toEnd: true), [a, c, d, b], "末尾へ")
    }

    // MARK: 組み立て(プロジェクトへの配置)

    func testAssembleWordsPlacesWordClipsInGivenOrderAndLeavesSourceUntouched() throws {
        let p = projectWithSource()
        // 四(5–6) → 一(0–2) の順で組み立てる
        let r = try XCTUnwrap(TranscriptWordEdit.assembleWords(
            in: p, sourceClipId: "a", sentences: timedSentences,
            order: [Sel(sentence: 1, word: 1), Sel(sentence: 0, word: 0)], destination: .appendToTrack(0)))
        let made = r.project.tracks[0].clips.filter { $0.id != "a" }.sorted { $0.start < $1.start }
        XCTAssertEqual(made.map(\.offset), [15, 10], "並べた順(四・一)で素材区間が並ぶ")
        XCTAssertEqual(made.map(\.duration), [1, 2])
        XCTAssertEqual(made.map(\.start), [6, 7], "元のレイヤーの末尾から隙間なく")
        XCTAssertEqual(r.clipIds, made.map(\.id), "返す id も組み立てた順")
        XCTAssertNil(r.sceneId)
        let source = try XCTUnwrap(r.project.tracks[0].clips.first { $0.id == "a" })
        XCTAssertEqual(source.start, 0, accuracy: 1e-9)
        XCTAssertEqual(source.duration, 6, accuracy: 1e-9)
        XCTAssertEqual(source.offset, 10, accuracy: 1e-9, "元クリップは変更しない")
        XCTAssertEqual(p.tracks[0].clips.count, 1, "元のプロジェクトは変更しない")
    }

    func testAssembleWordsToNewScene() throws {
        let p = projectWithSource()
        let r = try XCTUnwrap(TranscriptWordEdit.assembleWords(
            in: p, sourceClipId: "a", sentences: timedSentences,
            order: [Sel(sentence: 0, word: 1)], destination: .newScene(name: "単語ラフ")))
        let sceneId = try XCTUnwrap(r.sceneId)
        XCTAssertEqual(r.project.scenes.count, 1)
        XCTAssertEqual(r.project.scenes[0].id, sceneId)
        XCTAssertEqual(r.project.scenes[0].name, "単語ラフ")
        let clips = r.project.scenes[0].tracks[0].clips
        XCTAssertEqual(clips.count, 1)
        XCTAssertEqual(clips[0].offset, 12, accuracy: 1e-9, "「二」の区間(素材の 10 + 2)")
        XCTAssertEqual(clips[0].start, 0, accuracy: 1e-9, "シーンの中では 0 秒から")
        XCTAssertEqual(r.project.tracks[0].clips.count, 1, "タイムラインには足さない")
    }

    func testAssembleWordsFailsAsAWholeWhenAnyWordIsWordless() {
        let p = projectWithSource()
        let wordless = TranscriptSentence(text: "時刻なし", start: 0, end: 2)
        XCTAssertNil(TranscriptWordEdit.assembleWords(
            in: p, sourceClipId: "a", sentences: timedSentences + [wordless],
            order: [Sel(sentence: 0, word: 0), Sel(sentence: 2, word: 0)], destination: .appendToTrack(0)),
            "解決できない単語が 1 件でもあれば、黙って飛ばさず全体を失敗にする")
        XCTAssertNil(TranscriptWordEdit.assembleWords(
            in: p, sourceClipId: "無い", sentences: timedSentences,
            order: [Sel(sentence: 0, word: 0)], destination: .appendToTrack(0)), "対象が無ければ失敗")
    }

    func testAssembleWordsRejectsUnsupportedSource() {
        var p = Project.new()
        var fast = audioClip(id: "a", start: 0, duration: 6)
        fast.speed = 2
        var tr = Track(name: "音"); tr.clips = [fast]
        p.tracks = [tr]
        XCTAssertNil(TranscriptWordEdit.assembleWords(
            in: p, sourceClipId: "a", sentences: timedSentences,
            order: [Sel(sentence: 0, word: 0)], destination: .appendToTrack(0)),
            "速度変更クリップは 1 対 1 でないので対象外(文の組み立てと同じ)")
    }
}
