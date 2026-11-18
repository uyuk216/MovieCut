import XCTest
import CoreGraphics
@testable import MovieCutCore

/// 文字制御タグ(装飾タグ #32 / ルビ `<rb>` #31): 解釈・描画・縦書きとの組み合わせ。
/// 仕様は YMM4 公式の文字制御タグリファレンスに合わせる。
final class TextMarkupTests: XCTestCase {

    func parse(_ s: String, size: Double = 50, ls: Double = 0) -> MarkupParsed {
        TextMarkup.parse(s, baseSize: size, baseLetterSpacing: ls)
    }
    func styleAt(_ p: MarkupParsed, _ i: Int) -> MarkupRunStyle { p.stylesByChar()[i] }

    // MARK: パーサ: 素通りと不正タグ

    func testPlainPassthrough() {
        let p = parse("ただの文です")
        XCTAssertEqual(p.plain, "ただの文です")
        XCTAssertFalse(p.hasTags)
        XCTAssertTrue(p.runs.isEmpty)
        XCTAssertTrue(p.rubies.isEmpty)
    }

    func testInvalidTagsAreLiteral() {
        for s in ["a<b", "<xyz>abc", "1 < 2", "<s abc>", "<#ff00zz>いろ", "<#12345>いろ", "<rb東京>", "<rb,よみ>あ", "<rb漢字,>", "a<>b"] {
            let p = parse(s)
            XCTAssertEqual(p.plain, s, "不正なタグはそのまま文字になる: \(s)")
            XCTAssertFalse(p.hasTags, s)
        }
    }

    // MARK: パーサ: 色タグ

    func testColorTagAndReset() {
        let p = parse("<#ff0000>赤い<#>通常")
        XCTAssertEqual(p.plain, "赤い通常")
        XCTAssertTrue(p.hasTags)
        XCTAssertEqual(styleAt(p, 0).color, "#ff0000")
        XCTAssertEqual(styleAt(p, 1).color, "#ff0000")
        XCTAssertNil(styleAt(p, 2).color)
        XCTAssertEqual(p.runs.count, 1)
        XCTAssertEqual(p.runs[0].range, 0..<2)
    }

    func testColorShortForms() {
        XCTAssertEqual(styleAt(parse("<#f>あ"), 0).color, "#ffffff")
        XCTAssertEqual(styleAt(parse("<#a0>あ"), 0).color, "#a0a0a0")
        XCTAssertEqual(styleAt(parse("<#f00>あ"), 0).color, "#ff0000")
        let a = styleAt(parse("<#f008>あ"), 0)
        XCTAssertEqual(a.color, "#ff0000")
        XCTAssertEqual(a.colorAlpha, 0x88 / 255.0, accuracy: 0.001)
    }

    func testColorAlphaAndDual() {
        let a = styleAt(parse("<#ff000080>あ"), 0)
        XCTAssertEqual(a.color, "#ff0000")
        XCTAssertEqual(a.colorAlpha, 0x80 / 255.0, accuracy: 0.001)
        let d = styleAt(parse("<#00ff00,0000ff>あ"), 0)
        XCTAssertEqual(d.color, "#00ff00")
        XCTAssertEqual(d.outlineColor, "#0000ff")
    }

    func testColorNames() {
        XCTAssertEqual(styleAt(parse("<#red>あ"), 0).color, "#ff0000")
        XCTAssertEqual(styleAt(parse("<#DarkOrange>あ"), 0).color, "#ff8c00")
        XCTAssertEqual(styleAt(parse("<#RED>あ"), 0).color, "#ff0000")
        XCTAssertEqual(styleAt(parse("<#red,navy>あ"), 0).outlineColor, "#000080")
    }

    // MARK: パーサ: フォントタグ

    func testFontSizeAndReset() {
        let p = parse("<s80>大<s>小")
        XCTAssertEqual(p.plain, "大小")
        XCTAssertEqual(styleAt(p, 0).size, 80)
        XCTAssertNil(styleAt(p, 1).size)
    }

    func testFontNameAndBISU() {
        let p = parse("<s60,Meiryo,BI>太斜")
        let st = styleAt(p, 0)
        XCTAssertEqual(st.size, 60)
        XCTAssertEqual(st.fontName, "Meiryo")
        XCTAssertEqual(st.bold, true)
        XCTAssertEqual(st.italic, true)
        XCTAssertFalse(st.underline)
        XCTAssertFalse(st.strikethrough)
        let b = parse("<s,,B>あ")
        XCTAssertEqual(styleAt(b, 0).bold, true)
        XCTAssertNil(styleAt(b, 0).size)
        let n = parse("<s,メイリオ>あ")
        XCTAssertEqual(styleAt(n, 0).fontName, "メイリオ")
        XCTAssertNil(styleAt(n, 0).size)
        let u = parse("<s,,U>あ")
        XCTAssertTrue(styleAt(u, 0).underline)
    }

    func testFontArithmetic() {
        XCTAssertEqual(styleAt(parse("<s*=2>あ"), 0).size, 100)
        XCTAssertEqual(styleAt(parse("<s+=10>あ"), 0).size, 60)
        let p = parse("<s80>あ<s+=10>い")
        XCTAssertEqual(styleAt(p, 0).size, 80)
        XCTAssertEqual(styleAt(p, 1).size, 90)
    }

    func testAtTagReplaceDiffReset() {
        let p = parse("<@メイリオ>あ<@>い")
        XCTAssertEqual(styleAt(p, 0).fontName, "メイリオ")
        XCTAssertNil(styleAt(p, 1).fontName)
        // 全置換: 書かなかった装飾はオフ
        let r = parse("<@,B>あ")
        XCTAssertEqual(styleAt(r, 0).bold, true)
        XCTAssertEqual(styleAt(r, 0).italic, false)
        // 差分モード
        let d = parse("あ<@+B>い<@+I>う<@-B>え")
        XCTAssertNil(styleAt(d, 0).bold)
        XCTAssertEqual(styleAt(d, 1).bold, true)
        XCTAssertNil(styleAt(d, 1).italic)
        XCTAssertEqual(styleAt(d, 2).bold, true)
        XCTAssertEqual(styleAt(d, 2).italic, true)
        XCTAssertEqual(styleAt(d, 3).bold, false)
        XCTAssertEqual(styleAt(d, 3).italic, true)
        // <@> はサイズを戻さない
        let s = parse("<s80><@メイリオ>あ<@>い")
        XCTAssertEqual(styleAt(s, 1).size, 80)
        XCTAssertNil(styleAt(s, 1).fontName)
    }

    // MARK: パーサ: ルビ

    func testRubyBasic() {
        let p = parse("<rb東京,とうきょう>に行く")
        XCTAssertEqual(p.plain, "東京に行く")
        XCTAssertEqual(p.rubies.count, 1)
        XCTAssertEqual(p.rubies[0].start, 0)
        XCTAssertEqual(p.rubies[0].end, 2)
        XCTAssertEqual(p.rubies[0].reading, "とうきょう")
        XCTAssertEqual(p.rubies[0].sizeRatio, 0.5, accuracy: 0.001)
    }

    func testRubyParams() {
        XCTAssertEqual(parse("<rb漢字,かんじ,30>テスト").rubies[0].sizeRatio, 0.3, accuracy: 0.001)
        XCTAssertEqual(parse("<rb東京,とうきょう,*=2>").rubies[0].sizeRatio, 1.0, accuracy: 0.001)
        XCTAssertEqual(parse("<rb東京,とうきょう,+=20>").rubies[0].sizeRatio, 0.7, accuracy: 0.001)
        XCTAssertEqual(parse("<rb東京,とうきょう,-=10>").rubies[0].sizeRatio, 0.4, accuracy: 0.001)
        let o = parse("<rb東京,とうきょう,,0,-5>").rubies[0]
        XCTAssertEqual(o.sizeRatio, 0.5, accuracy: 0.001)
        XCTAssertEqual(o.dx, 0); XCTAssertEqual(o.dy, -5)
        let f = parse("<rb東京,とうきょう,50,0,0,游明朝,BI,ff0000,00ffff>").rubies[0]
        XCTAssertEqual(f.fontName, "游明朝")
        XCTAssertEqual(f.bold, true); XCTAssertEqual(f.italic, true)
        XCTAssertEqual(f.color, "#ff0000"); XCTAssertEqual(f.outlineColor, "#00ffff")
        let b = parse("<rb強調,きょうちょう,50,0,0,,B>").rubies[0]
        XCTAssertNil(b.fontName); XCTAssertEqual(b.bold, true); XCTAssertNil(b.italic)
    }

    func testRubyEscapedComma() {
        let p = parse("<rb1\\,000円,せんえん>")
        XCTAssertEqual(p.plain, "1,000円")
        XCTAssertEqual(p.rubies.count, 1)
        XCTAssertEqual(p.rubies[0].end, 6)
        XCTAssertEqual(p.rubies[0].reading, "せんえん")
    }

    // MARK: パーサ: 字間・座標・回転・タイミング

    func testLetterSpacingTag() {
        let p = parse("<ls20>あ<ls>い")
        XCTAssertEqual(styleAt(p, 0).letterSpacing, 20)
        XCTAssertNil(styleAt(p, 1).letterSpacing)
        XCTAssertEqual(styleAt(parse("<ls+=10>あ", ls: 5), 0).letterSpacing, 15)
    }

    func testPositionTags() {
        let p = parse("あ<p+100,+0>い")
        XCTAssertEqual(styleAt(p, 1).offsetX, 100)
        XCTAssertEqual(styleAt(p, 1).offsetY, 0)
        let a = parse("あ<p50,20>い")
        XCTAssertEqual(styleAt(a, 1).offsetX, 50)
        XCTAssertEqual(styleAt(a, 1).offsetY, 20)
        // X は改行でリセット、Y は残る
        let n = parse("<p+100,+10>あ\nい")
        XCTAssertEqual(styleAt(n, 2).offsetX, 0)
        XCTAssertEqual(styleAt(n, 2).offsetY, 10)
    }

    func testProportionalPosition() {
        let p = parse("<pp100,0>あ", size: 50)
        XCTAssertEqual(styleAt(p, 0).offsetX, 50)
    }

    func testRotationTag() {
        let p = parse("<rot30>あ<rot>い")
        XCTAssertEqual(styleAt(p, 0).rotation, 30)
        XCTAssertEqual(styleAt(p, 1).rotation, 0)
        let c = parse("<rot+=15>あ<rot+=15>い")
        XCTAssertEqual(styleAt(c, 0).rotation, 15)
        XCTAssertEqual(styleAt(c, 1).rotation, 30)
    }

    func testTimingTagsConsumed() {
        let p = parse("あ<r5>い<w1>う<c>え<r>お<w*0.5>か<c1>き")
        XCTAssertEqual(p.plain, "あいうえおかき")
        XCTAssertTrue(p.hasTags)
    }

    func testEscape() {
        let p = parse("\\<s80>あ")
        XCTAssertEqual(p.plain, "<s80>あ")
        XCTAssertTrue(p.hasTags)
        XCTAssertNil(styleAt(p, 5).size)
    }

    func testCaseInsensitiveAndSpaces() {
        XCTAssertEqual(styleAt(parse("<S80>あ"), 0).size, 80)
        XCTAssertEqual(parse("<RB東京,とうきょう>").rubies.count, 1)
        XCTAssertEqual(styleAt(parse("<#FF0000>あ"), 0).color, "#ff0000")
        XCTAssertEqual(styleAt(parse("<s 120>あ"), 0).size, 120)
        XCTAssertEqual(parse("<rb 東京, とうきょう, 30>").rubies[0].sizeRatio, 0.3, accuracy: 0.001)
    }

    func testStateAcrossNewline() {
        let p = parse("<#ff0000>あ\nい")
        XCTAssertEqual(styleAt(p, 2).color, "#ff0000")
    }

    func testFAQCombinedExample() {
        let p = parse("<#ff0000><s80><rb東京,とうきょう><s><#>は<rb日本,にほん>の首都です")
        XCTAssertEqual(p.plain, "東京は日本の首都です")
        XCTAssertEqual(p.rubies.count, 2)
        XCTAssertEqual(p.rubies[0].start, 0); XCTAssertEqual(p.rubies[0].end, 2)
        XCTAssertEqual(p.rubies[1].start, 3); XCTAssertEqual(p.rubies[1].end, 5)
        XCTAssertEqual(styleAt(p, 0).color, "#ff0000")
        XCTAssertEqual(styleAt(p, 0).size, 80)
        XCTAssertNil(styleAt(p, 2).color)
        XCTAssertNil(styleAt(p, 2).size)
    }

    // MARK: 描画

    struct Px {
        let w: Int, h: Int
        var d: [UInt8]
        func lum(_ x: Int, _ y: Int) -> Int { let i = (y * w + x) * 4; return Int(d[i]) + Int(d[i + 1]) + Int(d[i + 2]) }
        func ink(x0: Int = 0, x1: Int? = nil, y0: Int = 0, y1: Int? = nil) -> Int {
            var n = 0
            for y in y0..<(y1 ?? h) { for x in x0..<(x1 ?? w) where lum(x, y) > 300 { n += 1 } }
            return n
        }
        func reddish(x0: Int = 0, x1: Int? = nil, y0: Int = 0, y1: Int? = nil) -> Int {
            var n = 0
            for y in y0..<(y1 ?? h) { for x in x0..<(x1 ?? w) { let i = (y * w + x) * 4; if d[i] > 150 && d[i + 1] < 120 { n += 1 } } }
            return n
        }
        var bounds: (minX: Int, maxX: Int, minY: Int, maxY: Int)? {
            var minX = w, maxX = -1, minY = h, maxY = -1
            for y in 0..<h { for x in 0..<w where lum(x, y) > 300 { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) } }
            return maxX < 0 ? nil : (minX, maxX, minY, maxY)
        }
    }

    func px(_ img: CGImage) -> Px {
        var d = [UInt8](repeating: 0, count: img.width * img.height * 4)
        let c = CGContext(data: &d, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return Px(w: img.width, h: img.height, d: d)
    }

    func render(_ clip: Clip, t: Double = 0.5, w: Int = 600, h: Int = 400) throws -> Px {
        var p = Project()
        p.width = w; p.height = h; p.bg = "#000000"; p.characters = []
        var tr = Track(name: "L1"); tr.clips = [clip]
        p.tracks = [tr]
        return px(try XCTUnwrap(Renderer(project: p, assets: RenderAssets()).renderImage(t: t)))
    }

    func textClip(_ s: String, size: Double = 50, vertical: Bool = false) -> Clip {
        var c = Clip(); c.type = .text; c.start = 0; c.duration = 4; c.text = s; c.fontSize = size; c.x = 0.5; c.y = 0.5
        c.color = "#ffffff"; c.outline = "#000000"
        if vertical { var st = TextStyle(); st.vertical = true; c.textStyle = st }
        return c
    }

    func testColorRunPixels() throws {
        let img = try render(textClip("国<#ff0000>国"))
        XCTAssertGreaterThan(img.reddish(x0: 300), 50, "右の文字は赤い")
        XCTAssertEqual(img.reddish(x1: 300), 0, "左の文字は赤くない")
    }

    func testSizeRunPixels() throws {
        let big = try XCTUnwrap(try render(textClip("<s100>国")).bounds)
        let normal = try XCTUnwrap(try render(textClip("国")).bounds)
        XCTAssertGreaterThan(big.maxY - big.minY, (normal.maxY - normal.minY) * 3 / 2, "サイズタグで文字が大きくなる")
    }

    func testRubyPixelsAboveBase() throws {
        let withRuby = try XCTUnwrap(try render(textClip("<rb漢字,かんじ>")).bounds)
        let without = try XCTUnwrap(try render(textClip("漢字")).bounds)
        XCTAssertLessThan(withRuby.minY, without.minY - 10, "ルビは親文字の上に描かれる")
        // 行間が広がる分、枠も縦に大きい
        var p = Project(); p.width = 600; p.height = 400
        let r = Renderer(project: p, assets: RenderAssets())
        let font = textClip("漢字").fontOrDefault
        let a = r.textBlockSize("<rb漢字,かんじ>", size: 50, font: font)
        let b = r.textBlockSize("漢字", size: 50, font: font)
        XCTAssertGreaterThan(a.height, b.height + 20)
        XCTAssertEqual(a.width, b.width, accuracy: 1)
    }

    func testUnderlinePixels() throws {
        let plain = try render(textClip("一一"))
        let under = try render(textClip("<@,U>一一"))
        XCTAssertGreaterThan(under.ink(), plain.ink() + 30, "下線ぶんインクが増える")
        // 下線は文字の下: plain には無い行にインクがある
        var extraRows = 0
        for y in 0..<plain.h {
            let a = plain.ink(y0: y, y1: y + 1), b = under.ink(y0: y, y1: y + 1)
            if a == 0 && b > 20 { extraRows += 1 }
        }
        XCTAssertGreaterThan(extraRows, 0, "文字の下に線の行がある")
    }

    func testInvalidTagRendersLiterally() throws {
        let tagged = try XCTUnwrap(try render(textClip("a<xyz>b")).bounds)
        let plain = try XCTUnwrap(try render(textClip("ab")).bounds)
        XCTAssertGreaterThan(tagged.maxX - tagged.minX, (plain.maxX - plain.minX) * 2, "不正タグは文字として描かれる")
    }

    func testStyledBlockSizeCoversInk() throws {
        let img = try render(textClip("<s80><rb東京,とうきょう>"))
        let b = try XCTUnwrap(img.bounds)
        var p = Project(); p.width = 600; p.height = 400
        let r = Renderer(project: p, assets: RenderAssets())
        let box = r.textBlockSize("<s80><rb東京,とうきょう>", size: 50, font: textClip("東京").fontOrDefault)
        XCTAssertLessThanOrEqual(Double(b.maxX - b.minX), box.width + 40, "インクは枠の幅に概ね収まる")
        XCTAssertLessThanOrEqual(Double(b.maxY - b.minY), box.height + 40, "インクは枠の高さに概ね収まる")
        XCTAssertGreaterThan(box.width, 50)
        XCTAssertGreaterThan(box.height, 50)
    }

    func testVerticalRubyOnRightSide() throws {
        let withRuby = try XCTUnwrap(try render(textClip("<rb漢字,かんじ>", vertical: true)).bounds)
        let without = try XCTUnwrap(try render(textClip("漢字", vertical: true)).bounds)
        XCTAssertGreaterThan(withRuby.maxX, without.maxX + 8, "縦書きのルビは列の右に出る")
    }

    func testVerticalTagsAreConsumedNotDrawn() throws {
        let tagged = try XCTUnwrap(try render(textClip("<#ff0000>国国", vertical: true)).bounds)
        let plain = try XCTUnwrap(try render(textClip("国国", vertical: true)).bounds)
        XCTAssertEqual(tagged.maxX - tagged.minX, plain.maxX - plain.minX, accuracy: 3, "タグ文字は描かれない")
        XCTAssertEqual(tagged.maxY - tagged.minY, plain.maxY - plain.minY, accuracy: 3)
        let img = try render(textClip("<#ff0000>国国", vertical: true))
        XCTAssertEqual(img.reddish(), 0, "縦書きでは色タグは付かない(従来経路)")
    }

    func testSubtitleRubyFromVoiceText() throws {
        func voice(_ s: String) -> Clip {
            var c = Clip(); c.type = .voice; c.start = 0; c.duration = 4; c.text = s; c.fontSize = 50
            return c
        }
        let withRuby = try XCTUnwrap(try render(voice("<rb漢字,かんじ>です")).bounds)
        let without = try XCTUnwrap(try render(voice("漢字です")).bounds)
        XCTAssertLessThan(withRuby.minY, without.minY - 8, "字幕でもルビが上に出る")
    }

    func testTypewriterCountsPlainCharsOnly() throws {
        // タイプライター: タグを文字数に数えると、途中でタグ分だけ表示が遅れる
        var c = textClip("<#ff0000>国国国国")
        var a = TextAnim(kind: "typewriter"); a.duration = 1
        c.textAnim = a
        let mid = try render(c, t: 0.5)   // 開始から 0.5 秒 = 全体の半分 → 2 文字
        let full = try render(textClip("<#ff0000>国国国国"), t: 0.5)
        XCTAssertGreaterThan(mid.ink(), 50)
        XCTAssertLessThan(mid.ink(), full.ink() * 3 / 4, "半分だけ出る(タグは数えない)")
    }
}
