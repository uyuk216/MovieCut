import XCTest
@testable import MovieCutCore

/// タイムラインの問い合わせ(空白・再生位置のクリップ・短いクリップ・欠けた素材の区間・一覧・範囲・発話時間)と、
/// クリップの注記、台本の非発話メモ(※)。
final class TimelineQueryTests: XCTestCase {
    private func clip(_ start: Double, _ dur: Double, id: String = newId(), text: String? = nil, src: String? = nil, type: ClipType = .image, charId: String? = nil) -> Clip {
        var c = Clip()
        c.id = id; c.start = start; c.duration = dur; c.text = text; c.src = src; c.type = type; c.charId = charId
        return c
    }
    private func project(_ tracks: [(name: String, clips: [Clip], hidden: Bool)]) -> Project {
        var p = Project()
        p.tracks = tracks.map { t in
            var tr = Track(name: t.name)
            tr.clips = t.clips
            tr.hidden = t.hidden ? true : nil
            return tr
        }
        return p
    }

    // MARK: 空白(黒穴)

    func testGapStartsBetweenClipsAndNotAfterTheLast() {
        // 0–2, 3–5, 5–6 → 2 秒から 3 秒までが空白。6 秒より後は数えない
        let p = project([("A", [clip(0, 2), clip(3, 2), clip(5, 1)], false)])
        XCTAssertEqual(TimelineQuery.gapStarts(in: p), [2])
        XCTAssertEqual(TimelineQuery.coveredSpans(in: p), [.init(start: 0, end: 2), .init(start: 3, end: 6)])
    }

    func testLeadingGapCountsFromZero() {
        let p = project([("A", [clip(1, 1)], false)])
        XCTAssertEqual(TimelineQuery.gapStarts(in: p), [0])
    }

    func testOverlappingLayersDoNotLeaveAGap() {
        let p = project([("A", [clip(0, 2)], false), ("B", [clip(1, 2)], false), ("C", [clip(3, 1)], false)])
        XCTAssertEqual(TimelineQuery.gapStarts(in: p), [], "0–3 が続いているので空白はない")
    }

    func testHiddenLayerDoesNotFillAGap() {
        let p = project([("A", [clip(0, 1), clip(3, 1)], false), ("隠し", [clip(1, 2)], true)])
        XCTAssertEqual(TimelineQuery.gapStarts(in: p), [1])
    }

    func testNextAndPreviousGapStart() {
        let p = project([("A", [clip(0, 1), clip(2, 1), clip(5, 1)], false)])
        // 空白の始まりは 1 と 3
        XCTAssertEqual(TimelineQuery.gapStarts(in: p), [1, 3])
        XCTAssertEqual(TimelineQuery.nextGapStart(after: 0, in: p), 1)
        XCTAssertEqual(TimelineQuery.nextGapStart(after: 1, in: p), 3, "ちょうど今の空白の始まりにいるときは次の空白へ")
        XCTAssertNil(TimelineQuery.nextGapStart(after: 3, in: p))
        XCTAssertEqual(TimelineQuery.previousGapStart(before: 4, in: p), 3)
        XCTAssertEqual(TimelineQuery.previousGapStart(before: 3, in: p), 1)
        XCTAssertNil(TimelineQuery.previousGapStart(before: 1, in: p))
    }

    func testNoClipsMeansNoGaps() {
        let p = project([("A", [], false)])
        XCTAssertEqual(TimelineQuery.gapStarts(in: p), [])
        XCTAssertNil(TimelineQuery.nextGapStart(after: 0, in: p))
    }

    // MARK: 再生位置のクリップ

    func testClipIdsAtTimeReturnsTopmostLast() {
        let low = clip(0, 4, id: "low")
        let high = clip(1, 2, id: "high")
        let hidden = clip(0, 4, id: "hidden")
        let p = project([("下", [low], false), ("上", [high], false), ("隠し", [hidden], true)])
        XCTAssertEqual(TimelineQuery.clipIds(at: 1.5, in: p), ["low", "high"])
        XCTAssertEqual(TimelineQuery.clipIds(at: 1.5, in: p).last, "high", "描画の後ろ(上のレイヤー)が手前")
        XCTAssertEqual(TimelineQuery.clipIds(at: 3.5, in: p), ["low"])
        XCTAssertEqual(TimelineQuery.clipIds(at: 4, in: p), [], "終わりの時刻は含まない")
        XCTAssertEqual(TimelineQuery.clipIds(at: 0, in: p), ["low"], "頭の時刻は含む")
    }

    // MARK: 短いクリップ

    func testShortClipsAreThoseUnderTheFrameLimit() {
        var p = Project()
        p.fps = 30                          // 6 コマ = 0.2 秒
        let tr = project([("A", [clip(0, 0.1, id: "short"), clip(1, 0.2, id: "exact"), clip(2, 0, id: "zero"), clip(3, 1, id: "long")], false)])
        p.tracks = tr.tracks
        XCTAssertEqual(Set(TimelineQuery.shortClipIds(in: p)), ["short", "zero"], "0.2 秒ちょうどは短いに入れない・長さ 0 は入れる")
        XCTAssertEqual(TimelineQuery.shortClipIds(in: p, minFrames: 1), ["zero"])
    }

    // MARK: 欠けた素材の区間

    func testMissingSpansMergeAndSkipHiddenAndEmptySrc() {
        let p = project([
            ("A", [clip(0, 2, src: "/x/a.mov"), clip(2, 1, src: "/x/ok.mov"), clip(4, 1, src: "")], false),
            ("B", [clip(1, 2, src: "/x/b.mov")], false),
            ("隠し", [clip(9, 1, src: "/x/c.mov")], true),
        ])
        let missing: Set<String> = ["/x/a.mov", "/x/b.mov", "/x/c.mov"]
        let spans = TimelineQuery.missingSpans(in: p) { !missing.contains($0) }
        XCTAssertEqual(spans, [.init(start: 0, end: 3)], "0–2 と 1–3 は結合、隠しのレイヤーと src が空のものは数えない")
        XCTAssertEqual(TimelineQuery.missingSpans(in: p) { _ in true }, [])
    }

    // MARK: 一覧・範囲

    func testClipListingSortsByStartThenLayerOrder() {
        let p = project([("上", [clip(2, 1, id: "c", text: "あ")], false), ("下", [clip(0, 1, id: "a", src: "/m/pic.png", type: .image), clip(2, 1, id: "b", type: .shape)], false)])
        let rows = TimelineQuery.clipListing(in: p)
        XCTAssertEqual(rows.map(\.clipId), ["a", "c", "b"], "同じ開始はレイヤーの並び順")
        XCTAssertEqual(rows[0].label, "pic.png")
        XCTAssertEqual(rows[1].label, "あ", "文字は本文を見出しに")
        XCTAssertEqual(rows[2].label, "shape")
        XCTAssertEqual(rows[1].trackName, "上")
    }

    func testSpanOfSelectedClips() {
        let p = project([("A", [clip(1, 2, id: "a"), clip(5, 3, id: "b")], false)])
        XCTAssertEqual(TimelineQuery.span(ofClipIds: ["a", "b"], in: p), ExportRange(start: 1, end: 8))
        XCTAssertEqual(TimelineQuery.span(ofClipIds: ["a"], in: p), ExportRange(start: 1, end: 3))
        XCTAssertNil(TimelineQuery.span(ofClipIds: [], in: p))
        XCTAssertNil(TimelineQuery.span(ofClipIds: ["zzz"], in: p))
    }

    // MARK: 話者ごとの発話時間

    func testSpeechShareUsesVoiceClipsPerCharacterInRegistrationOrder() {
        var p = Project()
        let chars = Character.defaults()
        p.characters = chars
        p.tracks = [Track(name: "声")]
        p.tracks[0].clips = [
            clip(0, 3, type: .voice, charId: chars[1].id),
            clip(3, 1, type: .voice, charId: chars[0].id),
            clip(4, 9, type: .image, charId: chars[0].id),      // 声ではないので数えない
            clip(5, 2, type: .voice, charId: "unknown"),         // 登録のないキャラは数えない
        ]
        let share = TimelineQuery.speechShare(in: p)
        XCTAssertEqual(share.map(\.name), [chars[0].name, chars[1].name])
        XCTAssertEqual(share[0].seconds, 1, accuracy: 1e-9)
        XCTAssertEqual(share[0].ratio, 0.25, accuracy: 1e-9)
        XCTAssertEqual(share[1].ratio, 0.75, accuracy: 1e-9)
        XCTAssertEqual(TimelineQuery.speechShare(in: Project()), [])
    }

    // MARK: 注記

    func testCleanNoteTrimsFlattensAndCaps() {
        XCTAssertNil(Clip.cleanNote("  \n  "))
        XCTAssertEqual(Clip.cleanNote("  色を直す\n次に "), "色を直す 次に")
        XCTAssertEqual(Clip.cleanNote("一行目\n二行目"), "一行目 二行目")
        XCTAssertEqual(Clip.cleanNote(String(repeating: "あ", count: 300))?.count, Clip.noteMaxLength)
    }

    func testNoteIsWrittenOnlyWhenPresentAndRoundTrips() throws {
        let plain = clip(0, 1, id: "p")
        let plainJSON = String(data: try JSONEncoder().encode(plain), encoding: .utf8) ?? ""
        XCTAssertFalse(plainJSON.contains("\"note\""), "注記が無いクリップには note を書かない")

        var noted = clip(0, 1, id: "n")
        noted.note = "ここを詰める"
        let data = try JSONEncoder().encode(noted)
        let back = try JSONDecoder().decode(Clip.self, from: data)
        XCTAssertEqual(back.note, "ここを詰める")

        var empty = clip(0, 1, id: "e")
        empty.note = ""
        let emptyJSON = String(data: try JSONEncoder().encode(empty), encoding: .utf8) ?? ""
        XCTAssertFalse(emptyJSON.contains("\"note\""), "空の注記は書かない")
    }

    // MARK: 台本の非発話メモ(※)

    func testScriptNoteLinesAreNotSpoken() {
        let chars = Character.defaults()
        XCTAssertTrue(ScriptTimeline.isNote(line: "  ※ 間を長めに"))
        XCTAssertFalse(ScriptTimeline.isNote(line: "キャラ1: ※はセリフの中でも普通の文字"))
        XCTAssertNil(ScriptTimeline.parse(line: "※ ここは作業メモ", characters: chars, selectedCharId: chars[0].id))
        let spoken = ScriptTimeline.parse(line: "キャラ2: こんにちは", characters: chars, selectedCharId: chars[0].id)
        XCTAssertEqual(spoken?.1, "こんにちは")
    }
}

// MARK: - 使用クリップ一覧の書き出し(TSV / CSV)

final class ClipListingExportTests: XCTestCase {
    private func entry(_ label: String, layer: String = "上", start: Double = 1.5, duration: Double = 2, source: String? = nil) -> TimelineQuery.ListEntry {
        TimelineQuery.ListEntry(clipId: "c", trackName: layer, type: .text, start: start, duration: duration, label: label, source: source)
    }

    func testTSVHasHeaderAndFixedDecimalTimes() {
        let out = ClipListingExport.tsv([entry("あ", source: "/m/a.mov")])
        XCTAssertEqual(out, "レイヤー\t名前\t開始(秒)\t長さ(秒)\t素材パス\n上\tあ\t1.500\t2.000\t/m/a.mov\n")
    }

    func testTSVReplacesTabsAndNewlinesInCells() {
        let out = ClipListingExport.tsv([entry("a\tb\nc")])
        let lines = out.split(separator: "\n")
        XCTAssertEqual(lines.count, 2, "改行を含むセルがあっても行は増えない")
        XCTAssertEqual(lines[1].split(separator: "\t", omittingEmptySubsequences: false).count, 5, "列数は 5 のまま")
    }

    func testCSVQuotesCommaQuoteAndNewline() {
        let out = ClipListingExport.csv([entry("a,b"), entry("say \"hi\""), entry("x\ny")])
        XCTAssertTrue(out.hasPrefix("\u{FEFF}"), "先頭は UTF-8 の BOM")
        XCTAssertTrue(out.contains("\"a,b\""))
        XCTAssertTrue(out.contains("\"say \"\"hi\"\"\""))
        XCTAssertTrue(out.contains("\"x\ny\""))
        XCTAssertFalse(out.contains("\"上\""), "引用符が要らないセルは囲まない")
    }

    func testEmptySourceIsEmptyCell() {
        let out = ClipListingExport.csv([entry("t", source: nil)])
        XCTAssertTrue(out.hasSuffix("上,t,1.500,2.000,\r\n"))
    }

    func testListingCarriesSourcePath() {
        var p = Project()
        p.fps = 30
        var c = Clip()
        c.id = "v"; c.type = .video; c.start = 0; c.duration = 1; c.src = "/m/v.mp4"
        var tr = Track(name: "映像"); tr.clips = [c]
        p.tracks = [tr]
        XCTAssertEqual(TimelineQuery.clipListing(in: p).first?.source, "/m/v.mp4")
    }
}
