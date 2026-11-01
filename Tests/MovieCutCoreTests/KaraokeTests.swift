import XCTest
import CoreGraphics
@testable import MovieCutCore

/// カラオケ字幕(文字の装飾 `TextStyle.highlight`): 色をつける字数の計算、保存の往復、描画(左側だけ色が変わる)。
final class KaraokeTests: XCTestCase {
    private func hl(_ mode: String? = nil, times: [Double]? = nil) -> Highlight {
        Highlight(color: "#ff0000", mode: mode, times: times)
    }

    // MARK: 純粋な計算

    func testCharModeProgressesByCharacterWeight() {
        // 3 字・字数で按分: 0.5 の時点は 1.5 字 → 完了した 1 字
        XCTAssertEqual(KaraokeMath.coloredCount(text: "テスト", highlight: hl(), rel: 0.5, duration: 1), 1)
        XCTAssertEqual(KaraokeMath.coloredCount(text: "テスト", highlight: hl(), rel: 0, duration: 1), 0)
        XCTAssertEqual(KaraokeMath.coloredCount(text: "テスト", highlight: hl(), rel: 0.34, duration: 1), 1)
        XCTAssertEqual(KaraokeMath.coloredCount(text: "テスト", highlight: hl(), rel: 0.67, duration: 1), 2)
        // 終わったあとは全部、負の時刻は 0
        XCTAssertEqual(KaraokeMath.coloredCount(text: "テスト", highlight: hl(), rel: 1, duration: 1), 3)
        XCTAssertEqual(KaraokeMath.coloredCount(text: "テスト", highlight: hl(), rel: 5, duration: 1), 3)
        XCTAssertEqual(KaraokeMath.coloredCount(text: "テスト", highlight: hl(), rel: -1, duration: 1), 0)
    }

    func testWordModeStepsByWholeWords() {
        // 単位: "hello " (6 字・重み 5) "world " (6・5) "foo" (3・3)。重み合計 13
        let t = "hello world foo"
        XCTAssertEqual(KaraokeMath.coloredCount(text: t, highlight: hl("word"), rel: 0.3, duration: 1), 0)   // target 3.9 < 5
        XCTAssertEqual(KaraokeMath.coloredCount(text: t, highlight: hl("word"), rel: 0.5, duration: 1), 6)   // target 6.5 → 1 語
        XCTAssertEqual(KaraokeMath.coloredCount(text: t, highlight: hl("word"), rel: 0.8, duration: 1), 12)  // target 10.4 → 2 語
        XCTAssertEqual(KaraokeMath.coloredCount(text: t, highlight: hl("word"), rel: 1, duration: 1), 15)
    }

    func testPerUnitTimesAreUsedWhenCountMatches() {
        // 文字ごとの開始秒が 3 つ → 0.4 秒で 2 字
        let h = hl(times: [0, 0.3, 0.6])
        XCTAssertEqual(KaraokeMath.coloredCount(text: "テスト", highlight: h, rel: 0.4, duration: 1), 2)
        // 数が合わないときは字数で割る(0.4 → 1.2 字 → 1 字)
        let bad = hl(times: [0, 0.3])
        XCTAssertEqual(KaraokeMath.coloredCount(text: "テスト", highlight: bad, rel: 0.4, duration: 1), 1)
    }

    func testNewlinesAreNotCounted() {
        XCTAssertEqual(KaraokeMath.coloredCount(text: "ab\ncd", highlight: hl(), rel: 1, duration: 1), 4)
    }

    // MARK: 保存

    func testHighlightIsOmittedWhenUnsetAndRoundTrips() throws {
        var c = Clip(); c.type = .text
        c.textStyle = TextStyle()
        var st = TextStyle(); st.highlight = Highlight(color: "#ffd54a", mode: "word", times: [0, 0.5])
        c.textStyle = st
        let data = try JSONEncoder().encode(c)
        let back = try JSONDecoder().decode(Clip.self, from: data)
        XCTAssertEqual(back.textStyle?.highlight, Highlight(color: "#ffd54a", mode: "word", times: [0, 0.5]))
        // 既定(未設定)のときは highlight の項目を書かない
        var plain = Clip(); plain.type = .text; plain.textStyle = TextStyle(); plain.textStyle?.bold = false
        let s = String(data: try JSONEncoder().encode(plain), encoding: .utf8) ?? ""
        XCTAssertFalse(s.contains("highlight"))
    }

    func testInvalidColorAndModeFallBack() {
        var h = Highlight(color: "red-ish", mode: "syllable", times: [-1])
        h = h.normalized
        XCTAssertNil(h.color); XCTAssertNil(h.mode); XCTAssertNil(h.times)
        XCTAssertEqual(h.colorOrDefault, Highlight.defaultColor)
    }

    // MARK: 描画

    private func pixels(_ img: CGImage) -> (w: Int, h: Int, d: [UInt8]) {
        var d = [UInt8](repeating: 0, count: img.width * img.height * 4)
        let c = CGContext(data: &d, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return (img.width, img.height, d)
    }

    /// 中央に白い文字を 1 つ置き、色つけの文字(赤)が左側だけに出ることを確かめる。
    func testHighlightColoursOnlyTheSpokenLeftPart() throws {
        var c = Clip(); c.type = .text; c.start = 0; c.duration = 2; c.text = "テスト"; c.fontSize = 60; c.x = 0.5; c.y = 0.5
        c.color = "#ffffff"
        var st = TextStyle(); st.highlight = Highlight(color: "#ff0000", mode: "char"); c.textStyle = st
        var tr = Track(name: "L1"); tr.clips = [c]
        var p = Project(); p.width = 400; p.height = 200; p.bg = "#000000"; p.tracks = [tr]; p.characters = []
        let img = try XCTUnwrap(Renderer(project: p, assets: RenderAssets()).renderImage(t: 1.0))  // 半分(1.5 字 → 1 字)
        let px = pixels(img)
        var leftRed = 0, rightRed = 0
        for y in 0..<px.h { for x in 0..<px.w {
            let i = (y * px.w + x) * 4
            let r = Int(px.d[i]), g = Int(px.d[i + 1]), b = Int(px.d[i + 2])
            if r > 180, g < 90, b < 90 { if x < 200 { leftRed += 1 } else { rightRed += 1 } }
        } }
        XCTAssertGreaterThan(leftRed, 0, "先頭の字は赤で描かれる")
        XCTAssertEqual(rightRed, 0, "まだ話していない右側は赤にならない")
    }
}
