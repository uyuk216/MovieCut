import XCTest
import CoreGraphics
@testable import MovieCutCore

/// B1 文字の装飾(影・箱・グラデーション・字間・行間・揃え・太字・斜体)、文字のアニメーション、保存したスタイル。
final class TextStyleTests: XCTestCase {
    struct Pixels {
        let w: Int, h: Int
        var d: [UInt8]
        func rgb(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) { let i = (y * w + x) * 4; return (Int(d[i]), Int(d[i + 1]), Int(d[i + 2])) }
        /// 背景(黒)でない画素の枠。
        func bounds(where test: (Int, Int, Int) -> Bool = { r, g, b in r + g + b > 60 }) -> (minX: Int, maxX: Int, minY: Int, maxY: Int, count: Int)? {
            var minX = w, maxX = -1, minY = h, maxY = -1, n = 0
            for y in 0..<h { for x in 0..<w { let c = rgb(x, y); if test(c.r, c.g, c.b) { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y); n += 1 } } }
            return n == 0 ? nil : (minX, maxX, minY, maxY, n)
        }
        func centroid(where test: (Int, Int, Int) -> Bool) -> (x: Double, y: Double, n: Int)? {
            var sx = 0.0, sy = 0.0, n = 0
            for y in 0..<h { for x in 0..<w { let c = rgb(x, y); if test(c.r, c.g, c.b) { sx += Double(x); sy += Double(y); n += 1 } } }
            return n == 0 ? nil : (sx / Double(n), sy / Double(n), n)
        }
    }

    func pixels(_ img: CGImage) -> Pixels {
        var d = [UInt8](repeating: 0, count: img.width * img.height * 4)
        let c = CGContext(data: &d, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return Pixels(w: img.width, h: img.height, d: d)
    }

    func render(_ clip: Clip, t: Double = 0.5, w: Int = 600, h: Int = 300) throws -> Pixels {
        var p = Project()
        p.width = w; p.height = h; p.bg = "#000000"; p.characters = []
        var tr = Track(name: "L1"); tr.clips = [clip]
        p.tracks = [tr]
        return pixels(try XCTUnwrap(Renderer(project: p, assets: RenderAssets()).renderImage(t: t)))
    }

    func textClip(_ s: String, size: Double = 60, style: TextStyle? = nil, anim: TextAnim? = nil) -> Clip {
        var c = Clip(); c.type = .text; c.start = 0; c.duration = 4; c.text = s; c.fontSize = size; c.x = 0.5; c.y = 0.5
        c.color = "#ffffff"; c.outline = "#000000"
        c.textStyle = style; c.textAnim = anim
        return c
    }

    func isWhiteish(_ r: Int, _ g: Int, _ b: Int) -> Bool { r > 200 && g > 200 && b > 200 }

    // MARK: 影

    func testShadowAppearsOffsetToBottomRight() throws {
        let plain = try render(textClip("HHH", size: 90))
        var st = TextStyle(); st.shadow = .init(color: "#ff0000", dx: 30, dy: 20, blur: 0, opacity: 1)
        let shadowed = try render(textClip("HHH", size: 90, style: st))
        func red(_ r: Int, _ g: Int, _ b: Int) -> Bool { r > 150 && g < 80 && b < 80 }
        XCTAssertNil(plain.centroid(where: red), "影なしでは赤い画素は出ない")
        let rc = try XCTUnwrap(shadowed.centroid(where: red))
        let wc = try XCTUnwrap(shadowed.centroid(where: isWhiteish))
        XCTAssertGreaterThan(rc.n, 200)
        XCTAssertGreaterThan(rc.x - wc.x, 8, "影は右へずれる")
        XCTAssertGreaterThan(rc.y - wc.y, 5, "影は下へずれる(画面の下 = y が大きい)")
        // 文字そのものの位置は動かない
        let wp = try XCTUnwrap(plain.centroid(where: isWhiteish))
        XCTAssertEqual(wc.x, wp.x, accuracy: 0.6)
        XCTAssertEqual(wc.y, wp.y, accuracy: 0.6)
    }

    func testShadowOpacityAndBlurSoften() throws {
        var hard = TextStyle(); hard.shadow = .init(color: "#ff0000", dx: 0, dy: 0, blur: 0, opacity: 1)
        var soft = TextStyle(); soft.shadow = .init(color: "#ff0000", dx: 0, dy: 0, blur: 20, opacity: 0.5)
        let a = try render(textClip("HH", size: 90, style: hard)), b = try render(textClip("HH", size: 90, style: soft))
        let ba = try XCTUnwrap(a.bounds { r, g, bl in r > 40 }), bb = try XCTUnwrap(b.bounds { r, g, bl in r > 40 })
        XCTAssertGreaterThan(bb.maxX - bb.minX, ba.maxX - ba.minX, "ぼかした影は外へ広がる")
        // 濃さ 0 は何も描かない(影なしと同じ)
        var zero = TextStyle(); zero.shadow = .init(color: "#ff0000", dx: 20, dy: 20, blur: 5, opacity: 0)
        let plain = try render(textClip("HH", size: 90)), z = try render(textClip("HH", size: 90, style: zero))
        XCTAssertEqual(plain.d, z.d)
    }

    // MARK: 箱

    func testBoxColourBehindText() throws {
        var st = TextStyle(); st.box = .init(color: "#00ff00", opacity: 1, paddingX: 60, paddingY: 30, cornerRadius: 0)
        let plain = try render(textClip("HHH", size: 60))
        let boxed = try render(textClip("HHH", size: 60, style: st))
        let tb = try XCTUnwrap(plain.bounds())
        // 文字の枠の左外 40px: 余白(60)の内側 → 緑
        let c = boxed.rgb(tb.minX - 40, (tb.minY + tb.maxY) / 2)
        XCTAssertEqual(c.g, 255); XCTAssertLessThan(c.r, 10); XCTAssertLessThan(c.b, 10)
        XCTAssertEqual(plain.rgb(tb.minX - 40, (tb.minY + tb.maxY) / 2).g, 0)
        // 余白の外は背景のまま
        XCTAssertEqual(boxed.rgb(tb.minX - 90, (tb.minY + tb.maxY) / 2).g, 0)
        // 文字は箱の上に描かれる(白い画素が残る)
        XCTAssertNotNil(boxed.bounds(where: isWhiteish))
        // 箱の大きさ = 文字の枠 + 余白(縦も)
        let gb = try XCTUnwrap(boxed.bounds { r, g, b in g > 200 && r < 60 })
        XCTAssertGreaterThan(gb.maxY - gb.minY, 60)
    }

    func testBoxOpacityBlendsAndRoundedCornerIsCut() throws {
        var st = TextStyle(); st.box = .init(color: "#ffffff", opacity: 0.5, paddingX: 40, paddingY: 40, cornerRadius: 40)
        let img = try render(textClip("HH", size: 60, style: st))
        let g = try XCTUnwrap(img.bounds { r, g, b in g > 100 })
        let mid = img.rgb((g.minX + g.maxX) / 2, g.minY + 3)
        XCTAssertEqual(Double(mid.g), 127.5, accuracy: 3)
        // 角は丸く欠ける
        XCTAssertLessThan(img.rgb(g.minX, g.minY).g, 20)
    }

    // MARK: グラデーション

    func testGradientEndpointsDiffer() throws {
        var h = TextStyle(); h.gradient = .init(color1: "#ff0000", color2: "#0000ff", angle: 0)
        let img = try render(textClip("HHHHHH", size: 90, style: h), w: 800)
        func redish(_ r: Int, _ g: Int, _ b: Int) -> Bool { r > 150 && b < 100 && g < 100 }
        func blueish(_ r: Int, _ g: Int, _ b: Int) -> Bool { b > 150 && r < 100 && g < 100 }
        func endColours(_ img: Pixels, horizontal: Bool) -> (first: (r: Double, b: Double), last: (r: Double, b: Double)) {
            var pts: [(Int, Int, Int, Int)] = []
            for y in 0..<img.h { for x in 0..<img.w { let c = img.rgb(x, y); if max(c.r, c.g, c.b) - min(c.r, c.g, c.b) > 120 { pts.append((horizontal ? x : y, c.r, c.g, c.b)) } } }
            pts.sort { $0.0 < $1.0 }
            let k = max(1, pts.count / 10)
            func avg(_ s: ArraySlice<(Int, Int, Int, Int)>) -> (r: Double, b: Double) { (Double(s.map { $0.1 }.reduce(0, +)) / Double(s.count), Double(s.map { $0.3 }.reduce(0, +)) / Double(s.count)) }
            return (avg(pts.prefix(k)), avg(pts.suffix(k)))
        }
        let e = endColours(img, horizontal: true)
        XCTAssertGreaterThan(e.first.r, e.first.b + 60, "角度 0: 左端は color1(赤)")
        XCTAssertGreaterThan(e.last.b, e.last.r + 60, "角度 0: 右端は color2(青)")
        var v = TextStyle(); v.gradient = .init(color1: "#ff0000", color2: "#0000ff", angle: 90)
        let vi = try render(textClip("H\nH\nH", size: 80, style: v), h: 400)
        let ve = endColours(vi, horizontal: false)
        XCTAssertGreaterThan(ve.first.r, ve.first.b + 60, "角度 90: 上端は color1(赤)")
        XCTAssertGreaterThan(ve.last.b, ve.last.r + 60, "角度 90: 下端は color2(青)")
    }

    // MARK: 字間・行間・揃え・太字・斜体

    func testLetterSpacingWidensAndStaysCentred() throws {
        let plain = try XCTUnwrap(try render(textClip("ABCDE", size: 60)).bounds())
        var st = TextStyle(); st.letterSpacing = 20
        let wide = try XCTUnwrap(try render(textClip("ABCDE", size: 60, style: st)).bounds())
        XCTAssertEqual(Double((wide.maxX - wide.minX) - (plain.maxX - plain.minX)), 80, accuracy: 6, "4 つの隙間 × 20px")
        XCTAssertEqual(Double(wide.minX + wide.maxX) / 2, Double(plain.minX + plain.maxX) / 2, accuracy: 3, "中央揃えは字間で動かない")
    }

    func testLineHeightChangesBlockHeight() throws {
        let a = try XCTUnwrap(try render(textClip("H\nH", size: 50), h: 400).bounds())
        var st = TextStyle(); st.lineHeight = 2
        let b = try XCTUnwrap(try render(textClip("H\nH", size: 50, style: st), h: 400).bounds())
        XCTAssertEqual(Double((b.maxY - b.minY) - (a.maxY - a.minY)), 50 * (2 - 1.2), accuracy: 3)
    }

    func testAlignment() throws {
        func lineLeft(_ img: Pixels, top: Bool) -> Int {
            let cut = img.h / 2
            let b = img.bounds { r, g, bl in r + g + bl > 60 }
            _ = b
            var m = img.w
            for y in (top ? 0..<cut : cut..<img.h) { for x in 0..<img.w { let c = img.rgb(x, y); if c.r + c.g + c.b > 60 { m = min(m, x); break } } }
            return m
        }
        let text = "HHHHHHHH\nHH"
        let center = try render(textClip(text, size: 50), h: 400)
        var l = TextStyle(); l.align = "left"
        let left = try render(textClip(text, size: 50, style: l), h: 400)
        var r = TextStyle(); r.align = "right"
        let right = try render(textClip(text, size: 50, style: r), h: 400)
        XCTAssertGreaterThan(lineLeft(center, top: false), lineLeft(center, top: true) + 40, "中央: 短い行は内側から始まる")
        XCTAssertEqual(lineLeft(left, top: false), lineLeft(left, top: true), accuracy: 6, "左揃え: 行頭が揃う")
        XCTAssertGreaterThan(lineLeft(right, top: false), lineLeft(center, top: false) + 40, "右揃え: 短い行は右へ寄る")
    }

    func testDefaultEquivalentStyleIsPixelIdenticalToNoStyle() throws {
        var st = TextStyle(); st.align = "center"; st.lineHeight = 1.2; st.letterSpacing = 0; st.bold = true; st.italic = false
        let a = try render(textClip("あいう\nabc", size: 48)), b = try render(textClip("あいう\nabc", size: 48, style: st))
        XCTAssertEqual(a.d, b.d)
    }

    func testItalicShearsAndRegularWeightIsThinner() throws {
        // 斜体: 上の画素の重心が右へずれる
        var it = TextStyle(); it.italic = true
        func topBottom(_ img: Pixels) throws -> Double {
            let b = try XCTUnwrap(img.bounds(where: isWhiteish)); let mid = (b.minY + b.maxY) / 2
            let t = try XCTUnwrap(img.centroid { r, g, bl in false })
            _ = t; return Double(mid)
        }
        _ = try? topBottom
        let plain = try render(textClip("I", size: 120)), slanted = try render(textClip("I", size: 120, style: it))
        func xAt(_ img: Pixels, upper: Bool) throws -> Double {
            let b = try XCTUnwrap(img.bounds(where: isWhiteish))
            let y0 = upper ? b.minY : b.maxY - 10, y1 = upper ? b.minY + 10 : b.maxY
            var sx = 0.0, n = 0.0
            for y in y0..<y1 { for x in 0..<img.w { let c = img.rgb(x, y); if isWhiteish(c.r, c.g, c.b) { sx += Double(x); n += 1 } } }
            return sx / max(n, 1)
        }
        let dPlain = try xAt(plain, upper: true) - xAt(plain, upper: false)
        let dSlant = try xAt(slanted, upper: true) - xAt(slanted, upper: false)
        XCTAssertEqual(dPlain, 0, accuracy: 2)
        XCTAssertGreaterThan(dSlant, 15, "斜体は上が右へ傾く")
        // 太字 off は、太字より白い画素が少ない
        var reg = TextStyle(); reg.bold = false
        let bold = try render(textClip("HH", size: 80)), regular = try render(textClip("HH", size: 80, style: reg))
        XCTAssertLessThanOrEqual(try XCTUnwrap(regular.bounds(where: isWhiteish)).count, try XCTUnwrap(bold.bounds(where: isWhiteish)).count)
    }

    // MARK: 変形・キーフレーム・トランジション・エフェクトとの併用(A1〜A3)

    func testStyledTextRotatesWithClipAndStillRenders() throws {
        var st = TextStyle(); st.shadow = .init(color: "#ff0000", dx: 10, dy: 10, blur: 0, opacity: 1); st.box = .init(color: "#0000ff", opacity: 1, paddingX: 20, paddingY: 10, cornerRadius: 6)
        var c = textClip("HHH", size: 70, style: st)
        c.rotation = 90
        let img = try render(c)
        let b = try XCTUnwrap(img.bounds(where: isWhiteish))
        XCTAssertGreaterThan(b.maxY - b.minY, b.maxX - b.minX, "90°回すと縦長になる")
        XCTAssertNotNil(img.bounds { r, g, bl in bl > 200 && r < 40 }, "箱も回る")
        // 回した文字の影は文字と一緒に回る(画面の下ではなく回転後の向きへ)
        c.rotation = 0
        let upright = try render(c)
        let ru = try XCTUnwrap(upright.centroid { r, g, b in r > 150 && g < 80 && b < 80 })
        let wu = try XCTUnwrap(upright.centroid(where: isWhiteish))
        XCTAssertGreaterThan(ru.x, wu.x)
    }

    func testStyledTextWithEffectAndTransitionDoesNotCrash() throws {
        var st = TextStyle(); st.shadow = .init(); st.gradient = .init()
        var c = textClip("効果", size: 70, style: st)
        c.effects = [Effect(.sepia)]
        c.transitionIn = Transition(kind: "fade", duration: 0.5)
        XCTAssertNotNil(try render(c, t: 0.2).bounds())
        XCTAssertNotNil(try render(c, t: 1.0).bounds())
    }

    // MARK: タイプライター・ポップ・シェイク

    func testTypewriterVisibleCountVsTime() {
        XCTAssertEqual(TextAnimMath.visibleCount(total: 10, rel: 0, duration: 2), 0)
        XCTAssertEqual(TextAnimMath.visibleCount(total: 10, rel: 0.5, duration: 2), 2)
        XCTAssertEqual(TextAnimMath.visibleCount(total: 10, rel: 1.0, duration: 2), 5)
        XCTAssertEqual(TextAnimMath.visibleCount(total: 10, rel: 1.99, duration: 2), 9)
        XCTAssertEqual(TextAnimMath.visibleCount(total: 10, rel: 2, duration: 2), 10)
        XCTAssertEqual(TextAnimMath.visibleCount(total: 10, rel: 99, duration: 2), 10)
        XCTAssertEqual(TextAnimMath.visibleCount(total: 10, rel: -1, duration: 2), 0)
        XCTAssertEqual(TextAnimMath.visibleCount(total: 0, rel: 1, duration: 2), 0)
        // 改行は数えない
        let s = TextAnimMath.state(TextAnim(kind: "typewriter", duration: 1), text: "ab\ncd", rel: 0.5, size: 50)
        XCTAssertEqual(s.visible, 2); XCTAssertTrue(s.active)
        XCTAssertFalse(TextAnimMath.state(TextAnim(kind: "typewriter", duration: 1), text: "ab", rel: 1, size: 50).active)
    }

    func testTypewriterRendersMoreInkOverTimeWithoutMoving() throws {
        let anim = TextAnim(kind: "typewriter", duration: 2)
        let c = textClip("HHHHHHHH", size: 60, anim: anim)
        let early = try render(c, t: 0.5), mid = try render(c, t: 1.0), full = try render(c, t: 2.5)
        let e = try XCTUnwrap(early.bounds(where: isWhiteish)), m = try XCTUnwrap(mid.bounds(where: isWhiteish)), f = try XCTUnwrap(full.bounds(where: isWhiteish))
        XCTAssertLessThan(e.count, m.count); XCTAssertLessThan(m.count, f.count)
        XCTAssertEqual(e.minX, f.minX, "左端は動かない(全文字ぶんで位置が決まる)")
        XCTAssertEqual(full.d, try render(textClip("HHHHHHHH", size: 60), t: 2.5).d, "終わったあとはアニメなしと同じ")
        XCTAssertNil(try render(c, t: 0.0).bounds(where: isWhiteish), "0 秒では何も出ない")
    }

    func testPopScaleCurve() {
        XCTAssertEqual(TextAnimMath.popScale(rel: 0, duration: 1), 0.6, accuracy: 1e-9)
        XCTAssertEqual(TextAnimMath.popScale(rel: 0.6, duration: 1), 1.1, accuracy: 1e-9)
        XCTAssertEqual(TextAnimMath.popScale(rel: 1, duration: 1), 1, accuracy: 1e-9)
        XCTAssertEqual(TextAnimMath.popScale(rel: 5, duration: 1), 1)
        var prev = 0.0
        for i in 0...60 { let s = TextAnimMath.popScale(rel: Double(i) / 100, duration: 1); XCTAssertGreaterThanOrEqual(s, prev - 1e-12); prev = s }
        for i in 60...100 { let s = TextAnimMath.popScale(rel: Double(i) / 100, duration: 1); XCTAssertLessThanOrEqual(s, prev + 1e-12); prev = s }
        XCTAssertEqual(TextAnimMath.popScale(rel: 0.3, duration: 0.5), TextAnimMath.popScale(rel: 0.6, duration: 1), accuracy: 1e-12, "時間に比例")
    }

    func testPopRendersSmallerThenNormal() throws {
        let c = textClip("HHH", size: 80, anim: TextAnim(kind: "pop", duration: 1))
        let start = try XCTUnwrap(try render(c, t: 0.0).bounds(where: isWhiteish))
        let end = try XCTUnwrap(try render(c, t: 1.5).bounds(where: isWhiteish))
        XCTAssertEqual(Double(start.maxX - start.minX) / Double(end.maxX - end.minX), 0.6, accuracy: 0.05)
        XCTAssertEqual(try render(c, t: 1.5).d, try render(textClip("HHH", size: 80)).d)
    }

    func testShakeIsDeterministicAndDecays() throws {
        let a = TextAnimMath.shakeOffset(rel: 0.2, duration: 1, amplitude: 10), b = TextAnimMath.shakeOffset(rel: 0.2, duration: 1, amplitude: 10)
        XCTAssertEqual(a.dx, b.dx); XCTAssertEqual(a.dy, b.dy)
        XCTAssertEqual(TextAnimMath.shakeOffset(rel: 0.2, duration: 1, amplitude: 10).dx, TextAnimMath.shakeOffset(rel: 0.2 + 0.001, duration: 1, amplitude: 10).dx, "同じ 1/30 秒の刻みは同じずれ")
        var seen = Set<Double>()
        for i in 0..<20 { seen.insert(TextAnimMath.shakeOffset(rel: Double(i) / 30 * 0.9, duration: 1, amplitude: 10).dx) }
        XCTAssertGreaterThan(seen.count, 10, "刻みごとに違うずれ")
        for i in 0..<30 { let o = TextAnimMath.shakeOffset(rel: Double(i) / 30, duration: 1, amplitude: 10); XCTAssertLessThanOrEqual(abs(o.dx), 10 * (1 - Double(i) / 30) + 1e-9) }
        XCTAssertEqual(TextAnimMath.shakeOffset(rel: 1, duration: 1, amplitude: 10).dx, 0)
        XCTAssertEqual(TextAnimMath.shakeOffset(rel: -1, duration: 1, amplitude: 10).dx, 0)
        // 描画: 同じ時刻なら同じ絵、別の刻みなら絵が違う、終わったら止まる
        let c = textClip("HHH", size: 80, anim: TextAnim(kind: "shake", duration: 1))
        XCTAssertEqual(try render(c, t: 0.1).d, try render(c, t: 0.1).d)
        XCTAssertNotEqual(try render(c, t: 0.1).d, try render(c, t: 0.2).d)
        XCTAssertEqual(try render(c, t: 1.5).d, try render(textClip("HHH", size: 80)).d)
    }

    func testUnknownAnimKindDrawsNothingSpecial() throws {
        let c = textClip("HHH", size: 80, anim: TextAnim(kind: "wiggle2000", duration: 1))
        XCTAssertEqual(try render(c, t: 0.3).d, try render(textClip("HHH", size: 80)).d)
    }

    // MARK: ファイル

    func project(_ clip: Clip) -> Project {
        var p = Project(); p.tracks = [Track(name: "L1")]; p.tracks[0].clips = [clip]; return p
    }

    func testNothingWrittenWhenUnset() throws {
        let s = String(decoding: try project(textClip("a")).encoded(), as: UTF8.self)
        XCTAssertFalse(s.contains("textStyle")); XCTAssertFalse(s.contains("textAnim"))
    }

    /// 古いファイルは、読んで書いても 1 バイトも変わらず、新しい項目が増えない。
    func testOldFixturesGainNoTextKeysAndStayByteIdentical() throws {
        for n in ["rich", "electron-made", "keyframes", "transitions", "effects", "speed", "audiofx", "subtitles", "timeline"] {
            let url = try XCTUnwrap(Bundle.module.url(forResource: n, withExtension: "ymproj", subdirectory: "Fixtures"))
            let once = try Project.load(from: url).encoded()
            let s = String(decoding: once, as: UTF8.self)
            XCTAssertFalse(s.contains("textStyle"), n); XCTAssertFalse(s.contains("textAnim"), n)
            XCTAssertEqual(try Project.decode(from: once).encoded(), once, n)
        }
        for n in ["rich", "electron-made"] {
            let url = try XCTUnwrap(Bundle.module.url(forResource: n, withExtension: "ymproj", subdirectory: "Fixtures"))
            let golden = try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "golden-\(n)", withExtension: "json", subdirectory: "Fixtures")))
            XCTAssertEqual(try Project.load(from: url).encoded(), golden, n)
        }
    }

    func testRoundTripAndOnlySetFieldsAreWritten() throws {
        var st = TextStyle(); st.shadow = .init(color: "#112233", dx: 2, dy: 3, blur: 4, opacity: 0.5); st.align = "left"; st.italic = true
        let c = textClip("a", style: st, anim: TextAnim(kind: "pop", duration: 0.8))
        let data = try project(c).encoded()
        let back = try Project.decode(from: data)
        XCTAssertEqual(back.tracks[0].clips[0].textStyle, st)
        XCTAssertEqual(back.tracks[0].clips[0].textAnim, TextAnim(kind: "pop", duration: 0.8))
        XCTAssertEqual(try back.encoded(), data)
        let s = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(s.contains("\"shadow\"")); XCTAssertFalse(s.contains("\"box\"")); XCTAssertFalse(s.contains("\"gradient\"")); XCTAssertFalse(s.contains("letterSpacing"))
    }

    func testUnknownKeysAndGarbageAreKept() throws {
        let json = #"""
        {"version":1,"width":640,"height":360,"fps":30,"tracks":[{"name":"L1","clips":[
          {"id":"a","type":"text","start":0,"duration":2,"text":"x","textStyle":{"align":"right","futureThing":{"k":[1,2]},"shadow":"broken"},"textAnim":{"kind":"zoom9","duration":2,"curve":"bounce"}},
          {"id":"b","type":"text","start":0,"duration":2,"text":"y","textStyle":"oops","textAnim":[1,2]}]}]}
        """#
        let p = try Project.decode(from: Data(json.utf8))
        let a = p.tracks[0].clips[0]
        XCTAssertEqual(a.textStyle?.align, "right")
        XCTAssertEqual(a.textAnim?.kind, "zoom9"); XCTAssertNil(a.textAnim?.known)
        XCTAssertNil(p.tracks[0].clips[1].textStyle)
        let out = String(decoding: try p.encoded(), as: UTF8.self)
        for k in ["futureThing", "broken", "bounce", "zoom9", "oops"] { XCTAssertTrue(out.contains(k), k) }
        XCTAssertEqual(try Project.decode(from: Data(out.utf8)).encoded(), try p.encoded())
    }

    func testOutOfRangeValuesAreClamped() throws {
        let json = ##"{"shadow":{"dx":9999,"opacity":7,"color":"zzz"},"box":{"paddingX":-5,"cornerRadius":1e9},"lineHeight":50,"letterSpacing":-1e9,"align":"diagonal"}"##
        let s = try JSONDecoder().decode(TextStyle.self, from: Data(json.utf8)).normalized
        XCTAssertEqual(s.shadow?.dx, 200); XCTAssertEqual(s.shadow?.opacity, 1); XCTAssertEqual(s.shadow?.color, "#000000")
        XCTAssertEqual(s.box?.paddingX, 0); XCTAssertEqual(s.box?.cornerRadius, 400)
        XCTAssertEqual(s.lineHeight, 3); XCTAssertEqual(s.letterSpacing, -50); XCTAssertNil(s.align)
    }

    func testEditingNormalizesAndSkipsNoChange() {
        var c = textClip("a")
        XCTAssertFalse(TextStyleEditing.update(&c) { _ in })
        XCTAssertNil(c.textStyle)
        XCTAssertTrue(TextStyleEditing.update(&c) { $0.italic = true })
        XCTAssertFalse(TextStyleEditing.update(&c) { $0.italic = true }, "同じ値は変更なし")
        XCTAssertTrue(TextStyleEditing.update(&c) { $0.italic = nil })
        XCTAssertNil(c.textStyle, "空になったら項目ごと消える")
        var img = Clip(); img.type = .image
        XCTAssertFalse(TextStyleEditing.update(&img) { $0.italic = true })
        XCTAssertTrue(TextStyleEditing.setAnim(&c, kind: .pop, duration: 99))
        XCTAssertEqual(c.textAnim?.duration, 30)
        XCTAssertFalse(TextStyleEditing.setAnim(&c, kind: .pop, duration: 30))
        XCTAssertTrue(TextStyleEditing.setAnim(&c, kind: .none))
        XCTAssertNil(c.textAnim)
    }

    // MARK: 保存したスタイル

    func testBuiltinsAreSixAndWellFormed() {
        let b = TextStyleLibrary.builtins
        XCTAssertEqual(b.map(\.name), ["標準", "ゆっくり風", "ニュース帯", "見出し", "吹き出し風", "注意"])
        XCTAssertEqual(Set(b.map(\.id)).count, 6)
        XCTAssertTrue(b.allSatisfy(\.isBuiltin))
        XCTAssertNil(b[0].look.style)
        XCTAssertNotNil(b[1].look.style?.shadow); XCTAssertNotNil(b[2].look.style?.box); XCTAssertNotNil(b[3].look.style?.gradient)
        XCTAssertNotNil(b[4].look.bubble, "吹き出し風は吹き出しを使う(B-2)"); XCTAssertEqual(b[5].look.style?.bold, true)
        for s in b { XCTAssertEqual(s.look.style?.normalized, s.look.style) }
    }

    func testStoreRoundTripAndGarbageFallback() throws {
        let suite = "mc-textstyle-\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { d.removePersistentDomain(forName: suite) }
        XCTAssertEqual(TextStyleLibrary.loadUser(from: d), [])
        var list: [SavedTextStyle] = []
        var st = TextStyle(); st.shadow = .init()
        let id = try XCTUnwrap(TextStyleLibrary.add(&list, name: "  自分の  \n スタイル ", look: TextLook(color: "#123456", outline: nil, font: "X", style: st)))
        XCTAssertEqual(list[0].name, "自分の    スタイル")
        TextStyleLibrary.saveUser(list, to: d)
        XCTAssertEqual(TextStyleLibrary.loadUser(from: d), list)
        XCTAssertEqual(TextStyleLibrary.find(id, user: list)?.look.color, "#123456")
        // 壊れたデータ
        for bad in [Data("not json".utf8), Data("{}".utf8), Data("[1,2,3]".utf8), Data([0xff, 0x00, 0xfe])] {
            d.set(bad, forKey: TextStyleLibrary.defaultsKey)
            XCTAssertEqual(TextStyleLibrary.loadUser(from: d), [], "\(bad)")
        }
        d.set("a string", forKey: TextStyleLibrary.defaultsKey)
        XCTAssertEqual(TextStyleLibrary.loadUser(from: d), [])
        // 一部だけ壊れていれば、読めるものは残る。組み込みと同じ id と重複 id は捨てる
        let mixed = ##"[{"id":"user.1","name":"ok","look":{"color":"#fff"}},{"id":5},{"id":"builtin.standard","name":"偽物","look":{}},{"id":"user.1","name":"重複","look":{}},{"id":"user.2","name":"","look":{"style":{"shadow":{"dx":1e9}}}}]"##
        d.set(Data(mixed.utf8), forKey: TextStyleLibrary.defaultsKey)
        let l = TextStyleLibrary.loadUser(from: d)
        XCTAssertEqual(l.map(\.id), ["user.1", "user.2"])
        XCTAssertEqual(l[1].name, "スタイル")
        XCTAssertEqual(l[1].look.style?.shadow?.dx, 200)
    }

    func testRenameDeleteAndLimits() {
        var list: [SavedTextStyle] = []
        XCTAssertNil(TextStyleLibrary.add(&list, name: "   ", look: TextLook()))
        let a = TextStyleLibrary.add(&list, name: "A", look: TextLook())!
        XCTAssertTrue(TextStyleLibrary.rename(&list, id: a, to: "B"))
        XCTAssertFalse(TextStyleLibrary.rename(&list, id: a, to: "B"))
        XCTAssertFalse(TextStyleLibrary.rename(&list, id: a, to: " "))
        XCTAssertFalse(TextStyleLibrary.rename(&list, id: "nope", to: "C"))
        XCTAssertEqual(list[0].name, "B")
        XCTAssertEqual(TextStyleLibrary.sanitizedName(String(repeating: "あ", count: 100))?.count, 40)
        XCTAssertTrue(TextStyleLibrary.delete(&list, id: a))
        XCTAssertFalse(TextStyleLibrary.delete(&list, id: a))
        XCTAssertTrue(list.isEmpty)
    }

    func testApplyLookIsOneChangeAndResetsToStandard() {
        var c = textClip("a", style: { var s = TextStyle(); s.italic = true; return s }())
        c.color = "#00ff00"; c.outline = "#111111"; c.font = "Menlo"; c.fontSize = 77
        let news = TextStyleLibrary.builtins[2].look
        XCTAssertTrue(news.apply(to: &c))
        XCTAssertEqual(c.color, "#ffffff"); XCTAssertEqual(c.outline, "#0d2a6b"); XCTAssertNotNil(c.textStyle?.box); XCTAssertNil(c.textStyle?.italic)
        XCTAssertEqual(c.font, "Menlo", "書体の指定が無い見た目は書体を変えない")
        XCTAssertEqual(c.fontSize, 77, "大きさは変えない")
        XCTAssertFalse(news.apply(to: &c), "同じ見た目をもう一度当てても変更なし")
        XCTAssertTrue(TextStyleLibrary.builtins[0].look.apply(to: &c))
        XCTAssertNil(c.color); XCTAssertNil(c.outline); XCTAssertNil(c.textStyle)
        var img = Clip(); img.type = .image
        XCTAssertFalse(news.apply(to: &img))
        XCTAssertEqual(TextLook(of: c), TextLook(color: nil, outline: nil, font: "Menlo", style: nil))
    }
}
