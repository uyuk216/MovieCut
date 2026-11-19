import XCTest
@testable import MovieCutCore

/// Paper Edit(Core): 行選択(並び順・重複)→ クリップ列の生成(区間の対応・順序)と、配置(タイムライン / 末尾 / 新しいシーン)。
/// 元クリップは変更しないこと、置けない条件では何も作らないことも確かめる。
final class PaperEditTests: XCTestCase {

    func audioClip(id: String, start: Double, duration: Double, offset: Double = 0, src: String = "/x.wav") -> Clip {
        var c = Clip(); c.id = id; c.type = .audio; c.start = start; c.duration = duration; c.offset = offset; c.src = src
        return c
    }

    /// 6 秒クリップの 3 文(0–2 / 2–3.5 / 4–6)。
    let sentences = [
        TranscriptSentence(text: "一", start: 0, end: 2),
        TranscriptSentence(text: "二", start: 2, end: 3.5),
        TranscriptSentence(text: "三", start: 4, end: 6),
    ]

    func projectWithSource() -> Project {
        var p = Project.new()
        var tr = Track(name: "音")
        tr.clips = [audioClip(id: "a", start: 0, duration: 6, offset: 10)]
        p.tracks = [tr]
        return p
    }

    // MARK: 選択の解決(順序・重複・範囲外)

    func testOrderedSentencesKeepGivenOrderNotTimeOrder() {
        let got = PaperEdit.orderedSentences(from: sentences, order: [2, 0])
        XCTAssertEqual(got.map(\.text), ["三", "一"], "指定した並び順どおり(時刻順に戻さない)")
    }

    func testOrderedSentencesRepeatDuplicatesAndDropOutOfRange() {
        let got = PaperEdit.orderedSentences(from: sentences, order: [1, 1, 9, -1, 0])
        XCTAssertEqual(got.map(\.text), ["二", "二", "一"], "重複は繰り返し、範囲外は捨てる")
        XCTAssertTrue(PaperEdit.orderedSentences(from: sentences, order: []).isEmpty)
        XCTAssertTrue(PaperEdit.orderedSentences(from: [], order: [0]).isEmpty)
    }

    // MARK: 区間 → クリップ(対応)

    func testSubclipMapsSentenceToSourceRangeAndLeavesSourceUntouched() {
        let src = audioClip(id: "a", start: 5, duration: 6, offset: 10)
        let before = src
        let c = PaperEdit.subclip(source: src, sentence: sentences[1], startAt: 20)
        let got = try! XCTUnwrap(c)
        XCTAssertEqual(got.offset, 12, accuracy: 1e-9, "素材の頭 = 元の offset + 文の開始(2 秒)")
        XCTAssertEqual(got.duration, 1.5, accuracy: 1e-9)
        XCTAssertEqual(got.start, 20, accuracy: 1e-9, "配置時刻は指定どおり")
        XCTAssertEqual(got.src, "/x.wav")
        XCTAssertEqual(got.type, .audio)
        XCTAssertNotEqual(got.id, "a", "新しいクリップは新しい id")
        XCTAssertEqual(src, before, "元クリップは変更しない")
    }

    func testSubclipClampsSentenceToClipBounds() {
        let src = audioClip(id: "a", start: 0, duration: 6)
        let c = try! XCTUnwrap(PaperEdit.subclip(source: src, sentence: TranscriptSentence(text: "x", start: -1, end: 99), startAt: 0))
        XCTAssertEqual(c.offset, 0, accuracy: 1e-9)
        XCTAssertEqual(c.duration, 6, accuracy: 1e-9, "クリップの長さの外へは出さない")
    }

    func testSubclipRejectsUnsupportedAndTooShort() {
        var fast = audioClip(id: "a", start: 0, duration: 6)
        fast.speed = 2
        XCTAssertNil(PaperEdit.subclip(source: fast, sentence: sentences[0], startAt: 0), "速度変更クリップは 1 対 1 でないので対象外")
        let src = audioClip(id: "a", start: 0, duration: 6)
        XCTAssertNil(PaperEdit.subclip(source: src, sentence: TranscriptSentence(text: "x", start: 1, end: 1.0005), startAt: 0), "短すぎる区間は作らない")
        XCTAssertNil(PaperEdit.subclip(source: src, sentence: sentences[0], startAt: -1), "負の配置時刻は作らない")
    }

    // MARK: クリップ列(順序・つながり)

    func testClipsAreContiguousInSelectedOrder() {
        let src = audioClip(id: "a", start: 0, duration: 6, offset: 0)
        let ordered = PaperEdit.orderedSentences(from: sentences, order: [2, 0])
        let made = try! XCTUnwrap(PaperEdit.clips(source: src, ordered: ordered, startAt: 5))
        XCTAssertEqual(made.count, 2)
        XCTAssertEqual(made[0].start, 5, accuracy: 1e-9)
        XCTAssertEqual(made[0].offset, 4, accuracy: 1e-9, "先頭は「三」(4 秒から)")
        XCTAssertEqual(made[0].duration, 2, accuracy: 1e-9)
        XCTAssertEqual(made[1].start, 7, accuracy: 1e-9, "隙間なく次が続く")
        XCTAssertEqual(made[1].offset, 0, accuracy: 1e-9)
        XCTAssertEqual(Set(made.map(\.id)).count, 2, "id は重ならない")
    }

    func testClipsWithDuplicateSelectionMakeSeparateClips() {
        let src = audioClip(id: "a", start: 0, duration: 6)
        let ordered = PaperEdit.orderedSentences(from: sentences, order: [1, 1])
        let made = try! XCTUnwrap(PaperEdit.clips(source: src, ordered: ordered, startAt: 0))
        XCTAssertEqual(made.count, 2)
        XCTAssertEqual(made.map(\.offset), [2, 2], "同じ区間を 2 回使う")
        XCTAssertNotEqual(made[0].id, made[1].id)
        XCTAssertEqual(made[1].start, 1.5, accuracy: 1e-9)
    }

    func testClipsFailAsAWholeWhenAnySentenceCannotBeUsed() {
        let src = audioClip(id: "a", start: 0, duration: 6)
        let bad = [sentences[0], TranscriptSentence(text: "x", start: 3, end: 3)]
        XCTAssertNil(PaperEdit.clips(source: src, ordered: bad, startAt: 0), "黙って飛ばさず全体を失敗にする")
        XCTAssertNil(PaperEdit.clips(source: src, ordered: [], startAt: 0))
    }

    // MARK: 配置(タイムライン)

    func testAssembleToTimelinePlacesInOrderAndKeepsOriginal() throws {
        let p = projectWithSource()
        let r = try XCTUnwrap(PaperEdit.assemble(in: p, sourceClipId: "a", sentences: sentences,
                                                 order: [2, 0], destination: .timeline(trackIndex: 0, startAt: 10)))
        XCTAssertNil(r.sceneId)
        let clips = r.project.tracks[0].clips.sorted { $0.start < $1.start }
        XCTAssertEqual(clips.count, 3, "元 1 本 + 新規 2 本")
        let original = try XCTUnwrap(clips.first { $0.id == "a" })
        XCTAssertEqual(original, p.tracks[0].clips[0], "元クリップはそのまま")
        let made = clips.filter { $0.id != "a" }
        XCTAssertEqual(r.clipIds, made.map(\.id), "返す id は並び順どおり")
        XCTAssertEqual(made[0].start, 10, accuracy: 1e-9)
        XCTAssertEqual(made[0].offset, 14, accuracy: 1e-9, "「三」= 元 offset 10 + 4 秒")
        XCTAssertEqual(made[1].start, 12, accuracy: 1e-9)
        XCTAssertEqual(made[1].offset, 10, accuracy: 1e-9)
    }

    func testAssembleAppendToTrackStartsAtTrackEnd() throws {
        let p = projectWithSource()
        let r = try XCTUnwrap(PaperEdit.assemble(in: p, sourceClipId: "a", sentences: sentences,
                                                 order: [0], destination: .appendToTrack(0)))
        let made = try XCTUnwrap(r.project.tracks[0].clips.first { $0.id == r.clipIds[0] })
        XCTAssertEqual(made.start, 6, accuracy: 1e-9, "元のクリップ(0–6)の末尾から")
    }

    func testAssembleRefusesOverlapLockedTrackAndEmptySelection() {
        let p = projectWithSource()
        XCTAssertNil(PaperEdit.assemble(in: p, sourceClipId: "a", sentences: sentences,
                                        order: [0], destination: .timeline(trackIndex: 0, startAt: 3)), "既存と重なる場所には置かない")
        XCTAssertNil(PaperEdit.assemble(in: p, sourceClipId: "a", sentences: sentences,
                                        order: [], destination: .appendToTrack(0)), "選択が空なら作らない")
        XCTAssertNil(PaperEdit.assemble(in: p, sourceClipId: "無い", sentences: sentences,
                                        order: [0], destination: .appendToTrack(0)))
        XCTAssertNil(PaperEdit.assemble(in: p, sourceClipId: "a", sentences: sentences,
                                        order: [0], destination: .timeline(trackIndex: 9, startAt: 10)), "範囲外のレイヤー")
        var locked = p
        locked.tracks[0].locked = true
        XCTAssertNil(PaperEdit.assemble(in: locked, sourceClipId: "a", sentences: sentences,
                                        order: [0], destination: .appendToTrack(0)), "ロックされたレイヤーには置かない")
    }

    // MARK: 配置(新しいシーン)

    func testAssembleToNewSceneBuildsSceneAndLeavesTimelineUntouched() throws {
        let p = projectWithSource()
        let r = try XCTUnwrap(PaperEdit.assemble(in: p, sourceClipId: "a", sentences: sentences,
                                                 order: [1, 1, 0], destination: .newScene(name: " ラフ 1 ")))
        let sceneId = try XCTUnwrap(r.sceneId)
        XCTAssertEqual(r.project.tracks, p.tracks, "タイムラインは変えない")
        XCTAssertEqual(r.project.scenes.count, 1)
        let scene = try XCTUnwrap(r.project.scene(withId: sceneId))
        XCTAssertEqual(scene.name, "ラフ 1", "前後の空白は取り除く")
        let clips = scene.tracks[0].clips.sorted { $0.start < $1.start }
        XCTAssertEqual(clips.map(\.id), r.clipIds)
        XCTAssertEqual(clips.map(\.start), [0, 1.5, 3], "シーンの頭から隙間なく(重複選択も繰り返す)")
        XCTAssertEqual(clips.map(\.offset), [12, 12, 10])
        XCTAssertNil(PaperEdit.assemble(in: p, sourceClipId: "a", sentences: sentences,
                                        order: [0], destination: .newScene(name: "  ")), "名前が空なら作らない")
    }
}
