import XCTest
@testable import MovieCutCore

/// 単語単位のテキスト編集(Core): 文への単語時刻の引き継ぎ(ある場合だけ)・選んだ単語の取り除き(詰まる/詰まらない)・
/// 単語の時刻が無い素材での明示的な失敗(推定で文に広げない)。
final class TranscriptWordEditTests: XCTestCase {

    func audioClip(id: String, start: Double, duration: Double, src: String = "/x.wav") -> Clip {
        var c = Clip(); c.id = id; c.type = .audio; c.start = start; c.duration = duration; c.src = src
        return c
    }

    func seg(_ text: String, _ a: Double, _ b: Double, words: [TranscriptSegment] = []) -> TranscriptSegment {
        TranscriptSegment(text: text, start: a, end: b, words: words)
    }

    func word(_ text: String, _ a: Double, _ b: Double) -> TranscriptSegment {
        TranscriptSegment(text: text, start: a, end: b)
    }

    /// 6 秒クリップ・1 文(0–6)に単語 3 件(0–2 / 2–3.5 / 4–6)。3.5–4 はどの単語にも属さない間。
    var timedSentence: TranscriptSentence {
        TranscriptSentence(text: "一二三", start: 0, end: 6,
                           words: [word("一", 0, 2), word("二", 2, 3.5), word("三", 4, 6)])
    }

    func projectWithSource() -> Project {
        var p = Project.new()
        var tr = Track(name: "音")
        tr.clips = [audioClip(id: "a", start: 0, duration: 6), audioClip(id: "later", start: 6, duration: 2)]
        p.tracks = [tr]
        return p
    }

    typealias Sel = TranscriptWordEdit.Selection

    // MARK: 文への単語時刻の引き継ぎ

    func testSentencesKeepWordTimingWhenPhrasesCarryWords() {
        // Speech / Whisper(トークン使用可) の形: 文(フレーズ)が words を持って返る
        let clip = audioClip(id: "a", start: 0, duration: 6)
        let phrases = [
            seg("今日は晴れ", 0, 3, words: [word("今日は", 0, 1.5), word("晴れ", 1.5, 3)]),
            seg("明日は雨", 4, 6, words: [word("明日は", 4, 5), word("雨", 5, 6)]),
        ]
        let s = TranscriptTextEdit.sentences(from: phrases, clip: clip)
        XCTAssertEqual(s.count, 2)
        XCTAssertTrue(s[0].hasWordTiming, "単語の時刻を引き継ぐ")
        XCTAssertEqual(s[0].words.map(\.text), ["今日は", "晴れ"])
        XCTAssertEqual(s[0].words[1].start, 1.5, accuracy: 1e-9)
        XCTAssertEqual(s[1].words.map(\.text), ["明日は", "雨"])
        XCTAssertEqual(TranscriptWordEdit.wordEditableSentenceIndices(s), [0, 1])
    }

    func testSentencesKeepWordTimingThroughGroupingOfRawWords() {
        // 認識器内部の形: 単語の列 → TranscriptGrouping で文にまとめた結果(words つき)を渡す
        let clip = audioClip(id: "a", start: 0, duration: 3)
        let grouped = TranscriptGrouping.phrases(from: [word("おはよう。", 0, 0.8), word("今日は", 1.0, 1.4), word("晴れ", 1.4, 1.8)])
        let s = TranscriptTextEdit.sentences(from: grouped, clip: clip)
        XCTAssertEqual(s.map(\.text), ["おはよう。", "今日は晴れ"])
        XCTAssertTrue(s[0].hasWordTiming)
        XCTAssertEqual(s[1].words.map(\.text), ["今日は", "晴れ"])
        XCTAssertEqual(s[1].words[0].start, 1.0, accuracy: 1e-9)
    }

    func testSentencesFromBareSegmentsHaveNoWordTiming() {
        // words を持たない要素(Whisper の文単位フォールバック等)は、要素を「1 単語」と言い換えず時刻なしにする
        let clip = audioClip(id: "a", start: 0, duration: 3)
        let s = TranscriptTextEdit.sentences(from: [seg("一文目。", 0, 1), seg("二文目。", 1, 2)], clip: clip)
        XCTAssertEqual(s.map(\.text), ["一文目。", "二文目。"])
        XCTAssertTrue(s.allSatisfy { !$0.hasWordTiming }, "単語の時刻は無い(文単位まで)")
        XCTAssertTrue(TranscriptWordEdit.wordEditableSentenceIndices(s).isEmpty)
        XCTAssertFalse(TranscriptWordEdit.canEditWords(s[0]))
    }

    func testMixedPhrasesOnlyTimedOnesGetWords() {
        let clip = audioClip(id: "a", start: 0, duration: 6)
        let phrases = [
            seg("時刻あり", 0, 2, words: [word("時刻", 0, 1), word("あり", 1, 2)]),
            seg("時刻なし。", 3, 5),
        ]
        let s = TranscriptTextEdit.sentences(from: phrases, clip: clip)
        XCTAssertEqual(s.count, 2)
        XCTAssertTrue(s[0].hasWordTiming)
        XCTAssertFalse(s[1].hasWordTiming, "時刻の無い文は文単位まで(混ざっても推定しない)")
        XCTAssertEqual(TranscriptWordEdit.wordEditableSentenceIndices(s), [0])
    }

    func testWordTimesAreClampedInsideTheClip() {
        let clip = audioClip(id: "a", start: 0, duration: 3)
        let phrases = [seg("末尾", 2.5, 3.6, words: [word("末", 2.5, 3.0), word("尾", 3.0, 3.6)])]
        let s = TranscriptTextEdit.sentences(from: phrases, clip: clip)
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s[0].end, 3, accuracy: 1e-9)
        XCTAssertEqual(s[0].words.count, 1, "クリップの外だけの単語は落とす")
        XCTAssertEqual(s[0].words[0].text, "末")
    }

    // MARK: 取り除く範囲への変換

    func testCutsForSelectedWordsAreSortedRanges() {
        let cuts = TranscriptWordEdit.cuts(sentences: [timedSentence],
                                           selections: [Sel(sentence: 0, word: 2), Sel(sentence: 0, word: 0)])
        XCTAssertEqual(cuts?.map(\.start), [0, 4], "開始順に整う")
        XCTAssertEqual(cuts?.map(\.end), [2, 6])
    }

    func testCutsFailAsAWholeWhenSelectionTouchesWordlessSentence() {
        let wordless = TranscriptSentence(text: "時刻なし", start: 0, end: 2)
        XCTAssertNil(TranscriptWordEdit.cuts(sentences: [timedSentence, wordless],
                                             selections: [Sel(sentence: 0, word: 0), Sel(sentence: 1, word: 0)]),
                     "時刻の無い文が混ざったら、推定で文に広げず全体を失敗にする")
        XCTAssertNil(TranscriptWordEdit.cuts(sentences: [timedSentence], selections: []), "選択が空なら nil")
        XCTAssertNil(TranscriptWordEdit.cuts(sentences: [timedSentence], selections: [Sel(sentence: 9, word: 0)]),
                     "範囲外だけの指定は有効な単語が無いので nil")
    }

    // MARK: 単語の取り除き(プロジェクト)

    func testRemovingMiddleWordRipplesAndPullsLaterClip() throws {
        let p = projectWithSource()
        let r = try XCTUnwrap(TranscriptWordEdit.removeWords(in: p, clipId: "a", sentences: [timedSentence],
                                                             selections: [Sel(sentence: 0, word: 1)], ripple: true))
        let clips = r.project.tracks[0].clips.sorted { $0.start < $1.start }
        let pieces = clips.filter { $0.id != "later" }
        XCTAssertEqual(pieces.map(\.duration), [2, 2.5], "残りは 0–2 と 3.5–6(間の 0.5 も残る)")
        XCTAssertEqual(pieces[1].start, 2, accuracy: 1e-9, "後ろの断片は詰まる")
        XCTAssertEqual(pieces[1].offset, 3.5, accuracy: 1e-9, "素材の位置は単語の終わりから")
        let later = try XCTUnwrap(clips.first { $0.id == "later" })
        XCTAssertEqual(later.start, 4.5, accuracy: 1e-9, "後ろのクリップは取り除いた 1.5 秒ぶん詰まる")
        XCTAssertEqual(p.tracks[0].clips.map(\.duration), [6, 2], "元のプロジェクトは変更しない")
    }

    func testRemovingWordWithoutRippleLeavesAGap() throws {
        let p = projectWithSource()
        let r = try XCTUnwrap(TranscriptWordEdit.removeWords(in: p, clipId: "a", sentences: [timedSentence],
                                                             selections: [Sel(sentence: 0, word: 1)], ripple: false))
        let pieces = r.project.tracks[0].clips.filter { $0.id != "later" }.sorted { $0.start < $1.start }
        XCTAssertEqual(pieces.count, 2)
        XCTAssertEqual(pieces[1].start, 3.5, accuracy: 1e-9, "詰めないときは元の位置のまま(穴が空く)")
        let later = try XCTUnwrap(r.project.tracks[0].clips.first { $0.id == "later" })
        XCTAssertEqual(later.start, 6, accuracy: 1e-9, "後ろのクリップは動かない")
    }

    func testRemovingWordsAcrossSentences() throws {
        let p = projectWithSource()
        let second = TranscriptSentence(text: "四五", start: 0, end: 6, words: [word("四", 0, 2), word("五", 4, 6)])
        // 別々の文から 1 単語ずつ(範囲は文をまたいでよい)。「二」(2–3.5)と「五」(4–6)
        let r = try XCTUnwrap(TranscriptWordEdit.removeWords(in: p, clipId: "a", sentences: [timedSentence, second],
                                                             selections: [Sel(sentence: 0, word: 1), Sel(sentence: 1, word: 1)], ripple: true))
        let total = r.project.tracks[0].clips.filter { $0.id != "later" }.map(\.duration).reduce(0, +)
        XCTAssertEqual(total, 6 - 1.5 - 2, accuracy: 1e-9, "2 単語ぶん短くなる")
    }

    func testRemovingEveryWordLeavesUncoveredGapAsPiece() throws {
        // 単語が覆っていない間(3.5–4 の 0.5 秒)は単語削除では消えない(文の範囲へは広げない)
        let p = projectWithSource()
        let r = try XCTUnwrap(TranscriptWordEdit.removeWords(in: p, clipId: "a", sentences: [timedSentence],
                                                             selections: [Sel(sentence: 0, word: 0), Sel(sentence: 0, word: 1), Sel(sentence: 0, word: 2)],
                                                             ripple: true))
        let pieces = r.project.tracks[0].clips.filter { $0.id != "later" }
        XCTAssertEqual(pieces.count, 1)
        XCTAssertEqual(pieces[0].duration, 0.5, accuracy: 1e-9)
        XCTAssertEqual(pieces[0].offset, 3.5, accuracy: 1e-9, "残るのは単語に属さない間だけ")
    }

    func testRemovingAllCoveringWordsIsRefused() {
        // 単語がクリップ全体を覆う場合は、文の全削除と同じく拒否する
        var p = Project.new()
        var tr = Track(name: "音"); tr.clips = [audioClip(id: "a", start: 0, duration: 2)]
        p.tracks = [tr]
        let full = TranscriptSentence(text: "一二", start: 0, end: 2, words: [word("一", 0, 1), word("二", 1, 2)])
        XCTAssertNil(TranscriptWordEdit.removeWords(in: p, clipId: "a", sentences: [full],
                                                    selections: [Sel(sentence: 0, word: 0), Sel(sentence: 0, word: 1)], ripple: true))
        XCTAssertNil(TranscriptWordEdit.removeWords(in: p, clipId: "無い", sentences: [full],
                                                    selections: [Sel(sentence: 0, word: 0)], ripple: true))
    }
}
