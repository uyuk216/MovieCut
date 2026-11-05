import XCTest
import CoreGraphics
@testable import MovieCutCore

/// 縦書き(右の列から左へ)と、1 文字ずつの文字アニメーション(字幕にも使える)。
final class VerticalTextTests: XCTestCase {
    struct Px {
        let w: Int, h: Int
        var d: [UInt8]
        func lum(_ x: Int, _ y: Int) -> Int { let i = (y * w + x) * 4; return Int(d[i]) + Int(d[i + 1]) + Int(d[i + 2]) }
        func ink(x0: Int = 0, x1: Int? = nil, y0: Int = 0, y1: Int? = nil) -> Int {
            var n = 0
            for y in y0..<(y1 ?? h) { for x in x0..<(x1 ?? w) where lum(x, y) > 300 { n += 1 } }
            return n
        }
        var bounds: (w: Int, h: Int)? {
            var minX = w, maxX = -1, minY = h, maxY = -1
            for y in 0..<h { for x in 0..<w where lum(x, y) > 300 { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) } }
            return maxX < 0 ? nil : (maxX - minX + 1, maxY - minY + 1)
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

    func textClip(_ s: String, size: Double = 50, vertical: Bool = false, style: TextStyle? = nil, anim: TextAnim? = nil) -> Clip {
        var c = Clip(); c.type = .text; c.start = 0; c.duration = 4; c.text = s; c.fontSize = size; c.x = 0.5; c.y = 0.5
        c.color = "#ffffff"; c.outline = "#000000"
        var st = style ?? TextStyle()
        if vertical { st.vertical = true }
        c.textStyle = st.isEmpty ? nil : st
        c.textAnim = anim
        return c
    }

    func voiceClip(_ s: String, vertical: Bool = false, anim: TextAnim? = nil) -> Clip {
        var c = Clip(); c.type = .voice; c.start = 0; c.duration = 4; c.text = s; c.fontSize = 50
        var st = TextStyle(); if vertical { st.vertical = true }
        c.textStyle = st.isEmpty ? nil : st
        c.textAnim = anim
        return c
    }

    // MARK: 縦書き

    func testVerticalTextIsTallerThanWide() throws {
        let img = try render(textClip("縦書きの文字です", vertical: true))
        let b = try XCTUnwrap(img.bounds)
        XCTAssertGreaterThan(b.h, b.w * 3, "縦書きは縦に長い(\(b.w)×\(b.h))")
        let horizontal = try XCTUnwrap(try render(textClip("縦書きの文字です")).bounds)
        XCTAssertGreaterThan(horizontal.w, horizontal.h * 3, "横書きは横に長い")
    }

    func testColumnsRunRightToLeft() throws {
        // 最初の行(インクの多い「国」3 つ)がいちばん右の列
        let img = try render(textClip("国国国\n一", vertical: true))
        let right = img.ink(x0: 300), left = img.ink(x1: 300)
        XCTAssertGreaterThan(right, left * 2, "最初の行は右の列(右 \(right) / 左 \(left))")
        XCTAssertGreaterThan(left, 20, "2 列目は左にある")
    }

    func testCharactersRunTopToBottom() throws {
        let img = try render(textClip("国国一", vertical: true))
        XCTAssertGreaterThan(img.ink(y1: 200), img.ink(y0: 200) * 2, "先頭の文字は上")
    }

    func testBlockIsCenteredOnPosition() throws {
        let img = try render(textClip("国国国\n国国国", vertical: true))
        var minX = 600, maxX = 0, minY = 400, maxY = 0
        for y in 0..<img.h { for x in 0..<img.w where img.lum(x, y) > 300 { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) } }
        XCTAssertEqual(Double(minX + maxX) / 2, 300, accuracy: 6)
        XCTAssertEqual(Double(minY + maxY) / 2, 200, accuracy: 6)
    }

    func testLongVowelMarkIsRotatedInVertical() throws {
        // 長音「ー」: 横書きは横棒、縦書きは縦棒(縦書き用の字形)
        let h = try XCTUnwrap(try render(textClip("ー", size: 120)).bounds)
        let v = try XCTUnwrap(try render(textClip("ー", size: 120, vertical: true)).bounds)
        XCTAssertGreaterThan(h.w, h.h * 3)
        XCTAssertGreaterThan(v.h, v.w * 3)
    }

    func testVerticalPunctuationMovesToUpperRight() throws {
        // 「、」は横書きでは左下、縦書きでは右上に寄る
        func centroid(_ vertical: Bool) throws -> (x: Double, y: Double) {
            let img = try render(textClip("、", size: 200, vertical: vertical))
            var sx = 0.0, sy = 0.0, n = 0.0
            for y in 0..<img.h { for x in 0..<img.w where img.lum(x, y) > 300 { sx += Double(x); sy += Double(y); n += 1 } }
            XCTAssertGreaterThan(n, 50)
            return (sx / n - 300, sy / n - 200)
        }
        let h = try centroid(false), v = try centroid(true)
        XCTAssertGreaterThan(v.x, h.x + 10, "縦書きでは右へ寄る")
        XCTAssertLessThan(v.y, h.y - 10, "縦書きでは上へ寄る")
    }

    func testVerticalStyleStillAppliesShadowBoxAndSpacing() throws {
        var st = TextStyle()
        st.shadow = .init(color: "#ff0000", dx: 20, dy: 0, blur: 0, opacity: 1)
        let img = try render(textClip("国国", vertical: true, style: st))
        var red = 0
        for y in 0..<img.h { for x in 0..<img.w { let i = (y * img.w + x) * 4; if img.d[i] > 150 && img.d[i + 1] < 80 { red += 1 } } }
        XCTAssertGreaterThan(red, 100, "影も縦書きの文字に付く")
        var boxed = TextStyle(); boxed.box = .init(color: "#00ff00", opacity: 1, paddingX: 40, paddingY: 40, cornerRadius: 0)
        let b = try render(textClip("国国", vertical: true, style: boxed))
        let i = (200 * b.w + 300) * 4
        XCTAssertGreaterThan(Int(b.d[i + 1]), 150, "箱は縦書きの枠の後ろ")
        var sp = TextStyle(); sp.letterSpacing = 30
        let spaced = try XCTUnwrap(try render(textClip("国国国", vertical: true, style: sp)).bounds)
        let tight = try XCTUnwrap(try render(textClip("国国国", vertical: true)).bounds)
        XCTAssertGreaterThan(spaced.h, tight.h + 40, "字間は縦の間隔になる")
    }

    func testVerticalAlignTopAndBottom() throws {
        func cy(_ align: String) throws -> Double {
            var st = TextStyle(); st.align = align
            let img = try render(textClip("国国国国\n国", vertical: true, style: st))
            // 左の列(1 文字だけの列)の位置
            var sy = 0.0, n = 0.0
            for y in 0..<img.h { for x in 0..<300 where img.lum(x, y) > 300 { sy += Double(y); n += 1 } }
            return sy / n
        }
        let top = try cy("left"), mid = try cy("center"), bottom = try cy("right")
        XCTAssertLessThan(top, mid - 15)
        XCTAssertGreaterThan(bottom, mid + 15)
    }

    func testVerticalLayoutSizeMatchesBlockSize() {
        let f = TextFont(name: "Hiragino Maru Gothic ProN", size: 50)
        let text = "あいうえ\nかき"
        let lay = VerticalText.layout(text, font: f, size: 50, spacing: 0, lineHeight: 1.2, align: .center)
        let size = VerticalText.blockSize(text, size: 50, spacing: 0, lineHeight: 1.2)
        XCTAssertEqual(lay.width, Double(size.width), accuracy: 0.001)
        XCTAssertEqual(lay.height, Double(size.height), accuracy: 0.001)
        XCTAssertEqual(lay.chars.count, 6)
        XCTAssertEqual(lay.columnCount, 2)
        XCTAssertEqual(size.width, 120, accuracy: 0.001)   // 2 列 × 50 × 1.2
        XCTAssertEqual(size.height, 200, accuracy: 0.001)  // 4 文字 × 50
    }

    func testVerticalIsStableAcrossCachedRenders() throws {
        let a = try render(textClip("縦書き", vertical: true), t: 0.5)
        let b = try render(textClip("縦書き", vertical: true), t: 0.5)
        XCTAssertEqual(a.d, b.d)
    }

    func testTypewriterWorksOnVerticalText() throws {
        var a = TextAnim(kind: "typewriter"); a.duration = 1
        let early = try render(textClip("国国国国", vertical: true, anim: a), t: 0.5)
        let done = try render(textClip("国国国国", vertical: true, anim: a), t: 1.5)
        let full = try render(textClip("国国国国", vertical: true))
        XCTAssertEqual(done.d, full.d)
        XCTAssertGreaterThan(early.ink(), 50)
        XCTAssertLessThan(early.ink(), done.ink() * 3 / 4)
        XCTAssertGreaterThan(early.ink(y1: 200), early.ink(y0: 200) * 2, "上から出てくる")
    }

    // MARK: ファイル

    func testVerticalFieldIsOptionalAndRoundTrips() throws {
        var s = TextStyle()
        XCTAssertTrue(s.isEmpty)
        s.vertical = true
        XCTAssertFalse(s.isEmpty)
        let data = try JSONEncoder().encode(s)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"vertical\":true"))
        XCTAssertEqual(try JSONDecoder().decode(TextStyle.self, from: data).vertical, true)
        // 既定のときは書かない
        s.vertical = nil
        s.shadow = .init()
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(s), as: UTF8.self).contains("vertical"))
        // 読めない値は捨てずに残す
        let odd = try JSONDecoder().decode(TextStyle.self, from: Data("{\"vertical\":\"yes\"}".utf8))
        XCTAssertNil(odd.vertical)
        XCTAssertTrue(String(decoding: try JSONEncoder().encode(odd), as: UTF8.self).contains("\"yes\""))
    }

    func testSetVerticalEditing() {
        var c = textClip("あ")
        XCTAssertTrue(TextStyleEditing.setVertical(&c, true))
        XCTAssertEqual(c.textStyle?.vertical, true)
        XCTAssertFalse(TextStyleEditing.setVertical(&c, true), "変わらない編集は false")
        XCTAssertTrue(TextStyleEditing.setVertical(&c, false))
        XCTAssertNil(c.textStyle, "既定に戻ると項目ごと消える")
        var v = voiceClip("あ")
        XCTAssertTrue(TextStyleEditing.setVertical(&v, true), "字幕(ボイス)も縦書きにできる")
    }

    func testVerticalProjectRoundTripKeepsOtherClipsByteForByte() throws {
        var p = Project()
        var tr = Track(name: "L1")
        tr.clips = [textClip("あ", vertical: true), textClip("い")]
        p.tracks = [tr]
        let data = try p.encoded()
        let back = try Project.decode(from: data)
        XCTAssertEqual(back.tracks[0].clips[0].textStyle?.vertical, true)
        XCTAssertNil(back.tracks[0].clips[1].textStyle)
        XCTAssertEqual(try back.encoded(), data)
    }

    // MARK: 1 文字ずつ

    func testPerCharFieldRoundTripsAndIsOptional() throws {
        var a = TextAnim(kind: "pop")
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(a), as: UTF8.self).contains("perChar"))
        a.perChar = 0.1
        let data = try JSONEncoder().encode(a)
        XCTAssertEqual(try JSONDecoder().decode(TextAnim.self, from: data).perChar, 0.1)
        XCTAssertNil(TextAnim(kind: "scrollUp").perCharOrNil)
        var scroll = TextAnim(kind: "scrollUp"); scroll.perChar = 0.1
        XCTAssertNil(scroll.perCharOrNil, "スクロールでは1文字ずつにしない")
    }

    func testPerCharStateStaggersEachCharacter() {
        var a = TextAnim(kind: "fadeIn"); a.duration = 0.4; a.perChar = 0.2
        // rel = 0.3: 0 文字目は 0.3/0.4、1 文字目は 0.1/0.4、2 文字目はまだ
        let s0 = TextAnimMath.charState(a, index: 0, rel: 0.3, size: 50)
        let s1 = TextAnimMath.charState(a, index: 1, rel: 0.3, size: 50)
        let s2 = TextAnimMath.charState(a, index: 2, rel: 0.3, size: 50)
        XCTAssertEqual(s0.state.alpha, 0.75, accuracy: 1e-9)
        XCTAssertEqual(s1.state.alpha, 0.25, accuracy: 1e-9)
        XCTAssertTrue(s2.hidden)
        XCTAssertFalse(s0.hidden)
        XCTAssertEqual(TextAnimMath.perCharTotal(a, count: 3), 0.8, accuracy: 1e-9)
        XCTAssertTrue(TextAnimMath.perCharActive(a, count: 3, rel: 0.79))
        XCTAssertFalse(TextAnimMath.perCharActive(a, count: 3, rel: 0.81))
        // 終わった文字は静止
        let done = TextAnimMath.charState(a, index: 0, rel: 0.5, size: 50)
        XCTAssertFalse(done.state.active); XCTAssertFalse(done.hidden)
    }

    func testPerCharPopScalesAroundOwnCenter() {
        var a = TextAnim(kind: "pop"); a.duration = 1; a.perChar = 0.5
        let s = TextAnimMath.charState(a, index: 0, rel: 0.3, size: 50)
        XCTAssertGreaterThan(s.state.scale, 0.6)
        XCTAssertNotEqual(s.state.scale, 1)
    }

    func testPerCharShakeDiffersBetweenCharacters() {
        var a = TextAnim(kind: "shake"); a.duration = 1; a.perChar = 0
        a.perChar = 0.01
        let x = TextAnimMath.charState(a, index: 3, rel: 0.5, size: 100).state
        let y = TextAnimMath.charState(a, index: 4, rel: 0.5, size: 100).state
        XCTAssertTrue(x.dx != y.dx || x.dy != y.dy)
        // 既存のシェイクは、塩を足しても変わらない
        let base = TextAnimMath.shakeOffset(rel: 0.3, duration: 1, amplitude: 5)
        let salted0 = TextAnimMath.shakeOffset(rel: 0.3, duration: 1, amplitude: 5, salt: 0)
        XCTAssertEqual(base.dx, salted0.dx); XCTAssertEqual(base.dy, salted0.dy)
    }

    func testPerCharFadeRendersLeftToRight() throws {
        var a = TextAnim(kind: "fadeIn"); a.duration = 0.4; a.perChar = 0.3
        let text = "国国国国国"
        let mid = try render(textClip(text, size: 70, anim: a), t: 0.5)
        let left = mid.ink(x1: 300), right = mid.ink(x0: 300)
        XCTAssertGreaterThan(left, right + 100, "左の文字から出てくる(左 \(left) / 右 \(right))")
        let none = try render(textClip(text, size: 70, anim: a), t: 0.0)
        XCTAssertEqual(none.ink(), 0, "最初は 1 文字も見えない")
    }

    func testPerCharFinishesIntoTheSameImageAsStaticText() throws {
        var a = TextAnim(kind: "pop"); a.duration = 0.3; a.perChar = 0.1
        let end = try render(textClip("あいう", size: 70, anim: a), t: 1.0)
        let plain = try render(textClip("あいう", size: 70))
        XCTAssertEqual(end.d, plain.d)
    }

    func testPerCharPopDrawsEveryCharacterEventually() throws {
        var a = TextAnim(kind: "pop"); a.duration = 0.3; a.perChar = 0.1
        let running = try render(textClip("国国国", size: 70, anim: a), t: 0.15)
        let plain = try render(textClip("国国国", size: 70))
        XCTAssertGreaterThan(running.ink(), 50)
        XCTAssertLessThan(running.ink(), plain.ink(), "まだ出きっていない")
    }

    func testPerCharWorksWithVerticalAndBubble() throws {
        var a = TextAnim(kind: "fadeIn"); a.duration = 0.3; a.perChar = 0.3
        var c = textClip("国国国国", size: 60, vertical: true, anim: a)
        c.bubble = Bubble()
        let mid = try render(c, t: 0.45)
        XCTAssertGreaterThan(mid.ink(y1: 200), 50)
        let tail = try render(c, t: 3.0)
        XCTAssertGreaterThan(tail.ink(), 50)
    }

    func testPerCharRotatedClipStillDraws() throws {
        var a = TextAnim(kind: "pop"); a.duration = 0.3; a.perChar = 0.1
        var c = textClip("国国国", size: 70, anim: a)
        c.rotation = 15
        XCTAssertGreaterThan(try render(c, t: 0.2).ink(), 50)
    }

    func testSetPerCharEditing() {
        var c = textClip("あ")
        XCTAssertFalse(TextStyleEditing.setPerChar(&c, 0.1), "アニメーションが無いときは何もしない")
        _ = TextStyleEditing.setAnim(&c, kind: .pop)
        XCTAssertTrue(TextStyleEditing.setPerChar(&c, 0.1))
        XCTAssertEqual(c.textAnim?.perChar, 0.1)
        XCTAssertFalse(TextStyleEditing.setPerChar(&c, 0.1))
        XCTAssertTrue(TextStyleEditing.setPerChar(&c, 99))
        XCTAssertEqual(c.textAnim?.perChar, 1, "範囲に収める")
        XCTAssertTrue(TextStyleEditing.setPerChar(&c, nil))
        XCTAssertNil(c.textAnim?.perChar)
        _ = TextStyleEditing.setAnim(&c, kind: .pop)
        _ = TextStyleEditing.setPerChar(&c, 0.1)
        XCTAssertTrue(TextStyleEditing.setAnim(&c, kind: .scrollUp))
        XCTAssertNil(c.textAnim?.perChar, "スクロールに替えると1文字ずつは外れる")
    }

    // MARK: 字幕(ボイス)

    func testVoiceSubtitleCanUseTextAnimations() throws {
        var v = voiceClip("国国国国")
        XCTAssertTrue(TextStyleEditing.setAnim(&v, kind: .typewriter, duration: 1))
        XCTAssertFalse(TextStyleEditing.setAnim(&v, kind: .scrollUp), "字幕はスクロールしない")
        let early = try render(v, t: 0.25)
        let done = try render(v, t: 2.0)
        var plainClip = voiceClip("国国国国")
        plainClip.textAnim = nil
        let plain = try render(plainClip, t: 2.0)
        XCTAssertEqual(done.d, plain.d, "終われば静止した字幕と同じ")
        XCTAssertGreaterThan(early.ink(), 20)
        XCTAssertLessThan(early.ink(), done.ink() / 2, "タイプライターで少しずつ出る")
    }

    func testVoiceSubtitleFadeAndPerChar() throws {
        var v = voiceClip("国国国国国国")
        XCTAssertTrue(TextStyleEditing.setAnim(&v, kind: .fadeIn, duration: 0.3))
        XCTAssertTrue(TextStyleEditing.setPerChar(&v, 0.3))
        let mid = try render(v, t: 0.6)
        let full = try render(v, t: 3.0)
        XCTAssertGreaterThan(mid.ink(), 20)
        XCTAssertLessThan(mid.ink(), full.ink())
        XCTAssertGreaterThan(mid.ink(x1: 300), mid.ink(x0: 300), "左の文字から")
    }

    func testVoiceSubtitleVerticalSitsAtRightEdge() throws {
        let img = try render(voiceClip("縦の字幕です", vertical: true))
        let b = try XCTUnwrap(img.bounds)
        XCTAssertGreaterThan(b.h, b.w * 3)
        XCTAssertEqual(img.ink(x1: 300), 0, "右半分にだけ出る")
        XCTAssertGreaterThan(img.ink(x0: 450), 100)
    }

    func testVoiceAnimationsRoundTripThroughProjectFile() throws {
        var v = voiceClip("あ", vertical: true)
        _ = TextStyleEditing.setAnim(&v, kind: .pop)
        _ = TextStyleEditing.setPerChar(&v, 0.05)
        var p = Project(); var tr = Track(name: "V"); tr.clips = [v]; p.tracks = [tr]
        let data = try p.encoded()
        let back = try Project.decode(from: data)
        XCTAssertEqual(back.tracks[0].clips[0].textAnim?.perChar, 0.05)
        XCTAssertEqual(back.tracks[0].clips[0].textStyle?.vertical, true)
        XCTAssertEqual(try back.encoded(), data)
    }
}
