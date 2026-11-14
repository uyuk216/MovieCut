import XCTest
import CoreGraphics
@testable import MovieCutCore

/// ルビ: 位置決め・字幕ファイルの <ruby> の保持・ファイル形式の往復・描画で読みが出ること。
final class RubyTextTests: XCTestCase {

    // MARK: 位置決め

    func testResolveBasic() {
        let r = RubyText.resolve([RubySpan(base: "相棒", reading: "あいぼう")], in: "俺の相棒は猫だ")
        XCTAssertEqual(r, [RubyText.Resolved(start: 2, end: 4, reading: "あいぼう")])
    }

    func testResolveSequentialDuplicates() {
        // 同じ親文字が 2 回出たら、span の順に対応する現れ方へ 1 つずつ割り当てる
        let spans = [RubySpan(base: "山", reading: "やま"), RubySpan(base: "山", reading: "さん")]
        let r = RubyText.resolve(spans, in: "山と山")
        XCTAssertEqual(r.map { $0.start }, [0, 2])
        XCTAssertEqual(r.map { $0.reading }, ["やま", "さん"])
    }

    func testResolveDropsMissingAndEmpty() {
        let spans = [RubySpan(base: "無い", reading: "ない"), RubySpan(base: "", reading: "x"), RubySpan(base: "山", reading: "")]
        XCTAssertTrue(RubyText.resolve(spans, in: "山がある").isEmpty)
    }

    func testResolveAcrossNewline() {
        // 改行も 1 文字として数える(行をまたぐ位置決めがずれない)
        let r = RubyText.resolve([RubySpan(base: "猫", reading: "ねこ")], in: "犬\n猫")
        XCTAssertEqual(r.first?.start, 2)
    }

    // MARK: <ruby> の読み取り・書き戻し

    func testExtractMarkup() {
        let (plain, spans) = RubyText.extractMarkup("俺の<ruby>相棒<rt>あいぼう</rt></ruby>は<ruby>猫<rp>(</rp><rt>ねこ</rt><rp>)</rp></ruby>だ")
        XCTAssertEqual(plain, "俺の相棒は猫だ")
        XCTAssertEqual(spans, [RubySpan(base: "相棒", reading: "あいぼう"), RubySpan(base: "猫", reading: "ねこ")])
    }

    func testExtractMarkupPassthrough() {
        let (plain, spans) = RubyText.extractMarkup("ただの文です")
        XCTAssertEqual(plain, "ただの文です")
        XCTAssertTrue(spans.isEmpty)
        // 閉じタグが無い壊れた書き方は触らない(後段のタグ除去に任せる)
        let (broken, bSpans) = RubyText.extractMarkup("<ruby>相棒<rt>あいぼう")
        XCTAssertEqual(broken, "<ruby>相棒<rt>あいぼう")
        XCTAssertTrue(bSpans.isEmpty)
    }

    func testMarkupRoundTrip() {
        let text = "俺の相棒は猫だ"
        let spans = [RubySpan(base: "相棒", reading: "あいぼう"), RubySpan(base: "猫", reading: "ねこ")]
        let marked = RubyText.markup(text, spans: spans)
        XCTAssertEqual(marked, "俺の<ruby>相棒<rt>あいぼう</rt></ruby>は<ruby>猫<rt>ねこ</rt></ruby>だ")
        let (plain, back) = RubyText.extractMarkup(marked)
        XCTAssertEqual(plain, text)
        XCTAssertEqual(back, spans)
    }

    // MARK: 字幕ファイル

    func testSubtitleParseKeepsRuby() {
        let vtt = """
        WEBVTT

        00:00.000 --> 00:02.000
        俺の<ruby>相棒<rt>あいぼう</rt></ruby>は猫だ
        """
        let cues = SubtitleFile.parse(vtt)
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].text, "俺の相棒は猫だ")
        XCTAssertEqual(cues[0].ruby, [RubySpan(base: "相棒", reading: "あいぼう")])
    }

    func testSubtitleFormatVttWritesRubySrtDoesNot() {
        let cue = SubtitleCue(start: 0, end: 2, text: "俺の相棒は猫だ", ruby: [RubySpan(base: "相棒", reading: "あいぼう")])
        let vtt = SubtitleFile.format([cue], as: .vtt)
        XCTAssertTrue(vtt.contains("<ruby>相棒<rt>あいぼう</rt></ruby>"), vtt)
        let srt = SubtitleFile.format([cue], as: .srt)
        XCTAssertFalse(srt.contains("<ruby>"), srt)
        XCTAssertTrue(srt.contains("俺の相棒は猫だ"), srt)
        // VTT で書き出したものを読み直すと、本文とルビが戻る
        let back = SubtitleFile.parse(vtt)
        XCTAssertEqual(back.first?.text, cue.text)
        XCTAssertEqual(back.first?.ruby, cue.ruby)
    }

    func testSubtitleImportCarriesRubyToClip() {
        let cue = SubtitleCue(start: 1, end: 3, text: "相棒", ruby: [RubySpan(base: "相棒", reading: "あいぼう")])
        var p = Project(); p.width = 1920; p.height = 1080
        let r = SubtitleImport.apply([cue], to: p)
        XCTAssertEqual(r?.project.allClips.first?.ruby, cue.ruby)
    }

    func testCuesFromProjectCarryRuby() {
        var p = Project(); p.width = 1920; p.height = 1080
        var tr = Track(name: SubtitleFile.layerName)
        var c = Clip(); c.type = .text; c.text = "相棒"; c.start = 1; c.duration = 2
        c.ruby = [RubySpan(base: "相棒", reading: "あいぼう")]
        tr.clips = [c]; p.tracks = [tr]
        let cues = SubtitleFile.cues(from: p)
        XCTAssertEqual(cues.first?.ruby, c.ruby)
    }

    // MARK: ファイル形式

    func testClipRubyRoundTrip() throws {
        var c = Clip(); c.ruby = [RubySpan(base: "相棒", reading: "あいぼう")]
        let data = try JSONEncoder().encode(c)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"ruby\""), json)
        XCTAssertEqual(try JSONDecoder().decode(Clip.self, from: data).ruby, c.ruby)

        // 空なら書かない
        let plain = try JSONEncoder().encode(Clip())
        XCTAssertFalse(String(data: plain, encoding: .utf8)?.contains("\"ruby\"") ?? true)

        // 型の違う値は捨てずに extra へ
        let bad = try JSONDecoder().decode(Clip.self, from: Data(#"{"id":"x","type":"text","ruby":"abc"}"#.utf8))
        XCTAssertTrue(bad.ruby.isEmpty)
        XCTAssertEqual(bad.extra["ruby"], .string("abc"))
        let rewritten = try JSONEncoder().encode(bad)
        XCTAssertTrue(String(data: rewritten, encoding: .utf8)?.contains("\"ruby\":\"abc\"") ?? false)
    }

    // MARK: 描画

    private func brightRows(_ p: Project) throws -> (count: Int, minRow: Int, maxRow: Int) {
        let img = try XCTUnwrap(Renderer(project: p, assets: RenderAssets()).renderImage(t: 0.5))
        var d = [UInt8](repeating: 0, count: img.width * img.height * 4)
        let ctx = CGContext(data: &d, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        var count = 0, lo = img.height, hi = -1
        for row in 0..<img.height {
            for col in 0..<img.width {
                if d[(row * img.width + col) * 4] > 200 {
                    count += 1
                    lo = min(lo, row); hi = max(hi, row)
                }
            }
        }
        return (count, lo, hi)
    }

    private func textProject(ruby: [RubySpan]) -> Project {
        var p = Project(); p.width = 480; p.height = 360; p.bg = "#000000"; p.characters = []
        var c = Clip(); c.type = .text; c.text = "相棒"; c.start = 0; c.duration = 2
        c.x = 0.5; c.y = 0.5; c.fontSize = 96; c.color = "#ffffff"; c.outline = "#000000"
        c.font = "Hiragino Sans"; c.ruby = ruby
        var tr = Track(name: "文字"); tr.clips = [c]; p.tracks = [tr]
        return p
    }

    func testRenderDrawsRubyAboveBase() throws {
        let plain = try brightRows(textProject(ruby: []))
        let with = try brightRows(textProject(ruby: [RubySpan(base: "相棒", reading: "あいぼう")]))
        XCTAssertGreaterThan(plain.count, 0, "親文字が描かれていること")
        XCTAssertGreaterThan(with.count, plain.count, "読みのぶん画素が増える")
        XCTAssertGreaterThan(with.maxRow - with.minRow, plain.maxRow - plain.minRow, "読みは親文字の上に出るので、明るい範囲が縦に広がる")
    }

    func testTextBlockSizeGrowsWithRuby() {
        let r = Renderer(project: Project(), assets: RenderAssets())
        let plain = r.textBlockSize("相棒", size: 96, font: "Hiragino Sans")
        let with = r.textBlockSize("相棒", size: 96, font: "Hiragino Sans", ruby: [RubySpan(base: "相棒", reading: "あいぼう")])
        XCTAssertEqual(plain.width, with.width)
        XCTAssertGreaterThan(with.height, plain.height)
    }
}
