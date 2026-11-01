import XCTest
import CoreGraphics
import Foundation
@testable import MovieCutCore

/// 吹き出し(B-2): 項目の読み書き・形の幾何・描画のピクセル確認・1080p の時間。
final class BubbleTests: XCTestCase {
    // MARK: ヘルパー

    private struct Px {
        let w: Int, h: Int
        let d: [UInt8]
        func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let i = (y * w + x) * 4
            return (Int(d[i]), Int(d[i + 1]), Int(d[i + 2]))
        }
    }

    private func render(_ p: Project) throws -> Px {
        let img = try XCTUnwrap(Renderer(project: p, assets: RenderAssets()).renderImage(t: 0.5))
        var d = [UInt8](repeating: 0, count: img.width * img.height * 4)
        let c = try XCTUnwrap(CGContext(data: &d, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        c.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return Px(w: img.width, h: img.height, d: d)
    }

    private func project(w: Int = 400, h: Int = 200, clips: [Clip], characters: [Character] = []) -> Project {
        var p = Project()
        p.width = w; p.height = h; p.bg = "#000000"
        var tr = Track(name: "L1"); tr.clips = clips
        p.tracks = [tr]
        p.characters = characters
        return p
    }

    /// 0 秒から 2 秒の文字クリップ。吹き出しは任意で付ける。
    private func bubbleText(_ s: String = "あ", bubble: Bubble?, x: Double = 0.5, y: Double = 0.4, size: Double = 40) -> Clip {
        var c = Clip(); c.type = .text; c.start = 0; c.duration = 2; c.text = s; c.fontSize = size; c.x = x; c.y = y
        c.color = "#ff0000"; c.bubble = bubble
        return c
    }

    // MARK: 項目の読み書き

    func testBubbleIsOmittedWhenNotSet() throws {
        let s = String(decoding: try JSONEncoder().encode(bubbleText(bubble: nil)), as: UTF8.self)
        XCTAssertFalse(s.contains("bubble"), "未設定ならファイルに書かない")
    }

    func testBubbleRoundTripsAndKeepsUnknownKeys() throws {
        var b = Bubble(shape: "cloud", fill: "#fff8e1", stroke: "#333333", strokeWidth: 6, tail: true, tailX: 0.2, tailY: 0.8, tailChar: "c1", tailDX: 0.1, tailDY: -0.3)
        b = b.normalized
        let data = try JSONEncoder().encode(bubbleText(bubble: b))
        let back = try JSONDecoder().decode(Clip.self, from: data)
        XCTAssertEqual(back.bubble, b)
        // 壊れた形・色は既定に直す(読めないものを落とさない)
        let weird = Data(##"{"shape":"star","fill":"nope","stroke":"#000","strokeWidth":999,"tailX":"x"}"##.utf8)
        let w = try JSONDecoder().decode(Bubble.self, from: weird)
        XCTAssertEqual(w.shape, "rounded"); XCTAssertEqual(w.fill, Bubble.defaultFill); XCTAssertEqual(w.stroke, "#000")
        XCTAssertEqual(w.strokeWidth, 60); XCTAssertEqual(w.tailX, 0.5)
    }

    func testBubbleInOldFileStaysAsTypedAndNotWrittenBack() throws {
        // 古いファイル(吹き出しなし)は、読んで書き戻しても吹き出しの項目を増やさない
        let old = Data(#"{"id":"a","type":"text","start":0,"duration":2,"text":"x"}"#.utf8)
        let c = try JSONDecoder().decode(Clip.self, from: old)
        XCTAssertNil(c.bubble)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(c), as: UTF8.self).contains("bubble"))
    }

    // MARK: 形

    func testShapesContainTheCentreAndStayInsideTheBox() {
        let c = CGPoint(x: 200, y: 100), size = CGSize(width: 160, height: 80)
        let box = CGRect(x: 120, y: 60, width: 160, height: 80).insetBy(dx: -0.5, dy: -0.5)
        for shape in Bubble.shapes {
            let p = BubbleGeometry.path(shape: shape, center: c, size: size, tail: nil)
            XCTAssertTrue(p.contains(c), shape)
            XCTAssertTrue(box.contains(p.boundingBox), "\(shape): 尾なしは箱の中")
            XCTAssertFalse(p.contains(CGPoint(x: 0, y: 0)), shape)
        }
    }

    func testRectCornersAreFilledButRoundedCornersAreNot() {
        let c = CGPoint(x: 200, y: 100), size = CGSize(width: 160, height: 80)
        let corner = CGPoint(x: 121, y: 61)   // 箱の角のすぐ内側
        XCTAssertTrue(BubbleGeometry.path(shape: "rect", center: c, size: size, tail: nil).contains(corner))
        XCTAssertFalse(BubbleGeometry.path(shape: "rounded", center: c, size: size, tail: nil).contains(corner), "丸角は角を欠く")
    }

    func testTailReachesTowardTheTargetOnTheFacingSide() {
        let c = CGPoint(x: 200, y: 100), size = CGSize(width: 160, height: 80)
        // 下の目標 → 尾は下へ伸びる
        let below = CGPoint(x: 200, y: 190)
        let pb = BubbleGeometry.path(shape: "rounded", center: c, size: size, tail: below)
        XCTAssertTrue(pb.contains(CGPoint(x: 200, y: 175)), "尾の中")
        XCTAssertGreaterThanOrEqual(pb.boundingBox.maxY, 189.9)
        // 右の目標 → 尾は右へ
        let right = CGPoint(x: 330, y: 100)
        let pr = BubbleGeometry.path(shape: "rect", center: c, size: size, tail: right)
        XCTAssertTrue(pr.contains(CGPoint(x: 310, y: 100)))
        XCTAssertGreaterThanOrEqual(pr.boundingBox.maxX, 329.9)
        // 尾なし(nil)なら目標に届かない
        XCTAssertLessThan(BubbleGeometry.path(shape: "rect", center: c, size: size, tail: nil).boundingBox.maxY, 141)
    }

    func testCloudHasBumpsOutsideTheInnerRectangle() {
        let c = CGPoint(x: 200, y: 100), size = CGSize(width: 160, height: 80)
        let p = BubbleGeometry.path(shape: "cloud", center: c, size: size, tail: nil)
        // 雲は外周に丸いこぶがあり、四角の角より内側で欠けたところがある
        let r = 80.0 * 0.22
        XCTAssertFalse(p.contains(CGPoint(x: 120 + 0.5, y: 60 + 0.5)), "角は雲にならない")
        XCTAssertTrue(p.contains(CGPoint(x: 120 + r * 0.5, y: 100)), "左の縁のこぶの内側")
    }

    func testTargetFromCharacterUsesItsPositionAndOffset() {
        var ch = Character(); ch.id = "c1"; ch.x = 0.25; ch.y = 0.5
        var b = Bubble(); b.tailChar = "c1"; b.tailDX = 0.1; b.tailDY = -0.2
        let p = BubbleTarget.point(b, characters: [ch], width: 400, height: 200)
        XCTAssertEqual(p.x, (0.25 + 0.1) * 400, accuracy: 1e-9)
        XCTAssertEqual(p.y, (0.5 - 0.2) * 200, accuracy: 1e-9)
        // キャラが無いときは点の指定に戻る
        b.tailChar = "none"; b.tailX = 0.8; b.tailY = 0.9
        XCTAssertEqual(BubbleTarget.point(b, characters: [ch], width: 400, height: 200), CGPoint(x: 320, y: 180))
    }

    // MARK: 描画(ピクセル)

    func testTailTipIsPaintedAndOutsideStaysBackground() throws {
        // 白い吹き出し・尾の先 (200,190)。尾の中は白、遠い所は背景の黒
        var b = Bubble(); b.fill = "#ffffff"; b.stroke = "#000000"; b.strokeWidth = 4; b.tail = true; b.tailX = 0.5; b.tailY = 0.95
        let px = try render(project(clips: [bubbleText(bubble: b)]))
        XCTAssertEqual(px.rgb(200, 170).0, 255, "尾の中は白(塗り)")
        XCTAssertEqual(px.rgb(200, 170).1, 255)
        XCTAssertEqual(px.rgb(200, 170).2, 255)
        XCTAssertEqual(px.rgb(5, 5).0, 0, "遠くは背景")
        XCTAssertEqual(px.rgb(395, 195).0, 0)
        XCTAssertEqual(px.rgb(200, 199).0, 0, "尾の先より外は背景")
        // 本体の左の縁の少し内側も白
        XCTAssertGreaterThan(px.rgb(160, 80).0, 200, "本体の内側は白")
    }

    func testTailOffWhenDisabled() throws {
        var b = Bubble(); b.fill = "#ffffff"; b.strokeWidth = 0; b.tail = false; b.tailY = 0.95
        let px = try render(project(clips: [bubbleText(bubble: b)]))
        XCTAssertEqual(px.rgb(200, 170).0, 0, "尾なしなら下の点まで白くならない")
    }

    func testStrokeIsDrawnOutsideTheFill() throws {
        // 縁の色(緑)は本体の外に出て、内側は塗り(白)のまま
        var b = Bubble(); b.fill = "#ffffff"; b.stroke = "#00ff00"; b.strokeWidth = 6; b.tail = false
        let px = try render(project(clips: [bubbleText(bubble: b, y: 0.5)]))
        // 本体の左の縁は x=200-w/2 あたり。その外側 2 px は緑、内側は白
        let edge = (0..<px.w).first { x in px.rgb(x, 100).0 > 128 && px.rgb(x, 100).1 > 128 } ?? 0
        XCTAssertGreaterThan(edge, 0)
        XCTAssertGreaterThan(px.rgb(edge + 3, 100).0, 200, "縁の内側は白")
        let outside = (0..<edge).reversed().first { x in px.rgb(x, 100).1 > 200 && px.rgb(x, 100).0 < 50 } ?? -1
        XCTAssertGreaterThan(outside, 0, "縁の緑が外側に見える")
    }

    func testBubbleIsBehindTheText() throws {
        // 文字(赤)は吹き出し(白)の上に出る。文字の真ん中は赤
        var b = Bubble(); b.fill = "#ffffff"; b.strokeWidth = 0; b.tail = false
        let px = try render(project(clips: [bubbleText(bubble: b, y: 0.5, size: 60)]))
        var reds = 0
        for y in 0..<px.h { for x in 0..<px.w where px.rgb(x, y).0 > 200 && px.rgb(x, y).1 < 80 { reds += 1 } }
        XCTAssertGreaterThan(reds, 100, "文字は見える")
    }

    func testNoBubbleRendersAsBefore() throws {
        // 吹き出しなしの描画は、吹き出しの項目を付けない従来のクリップと同じピクセル
        let a = try render(project(clips: [bubbleText(bubble: nil)]))
        var c = bubbleText(bubble: nil); c.bubble = nil
        let b = try render(project(clips: [c]))
        XCTAssertEqual(a.d, b.d)
        XCTAssertEqual(a.rgb(200, 100).0, 0, "吹き出しがなければ白くならない")
    }

    // MARK: 時間(1080p)

    func testBubbleCostAt1080p() throws {
        // 1920×1080 の 1 コマ。吹き出しあり・なしの平均(環境差があるので上限だけ確かめ、数字は出力に残す)
        func time(_ bubble: Bubble?) throws -> Double {
            let p = project(w: 1920, h: 1080, clips: [bubbleText("こんにちは、ゆっくりです", bubble: bubble, x: 0.5, y: 0.8, size: 64)])
            let r = Renderer(project: p, assets: RenderAssets())
            _ = r.renderImage(t: 0.5)
            let n = 20
            let t0 = CFAbsoluteTimeGetCurrent()
            for _ in 0..<n { _ = r.renderImage(t: 0.5) }
            return (CFAbsoluteTimeGetCurrent() - t0) / Double(n) * 1000
        }
        var bb = Bubble(); bb.shape = "cloud"; bb.tailY = 0.5
        let without = try time(nil)
        let with = try time(bb)
        print("BUBBLE_BENCH 1080p ms/frame without=\(String(format: "%.2f", without)) with=\(String(format: "%.2f", with))")
        XCTAssertLessThan(with, max(50, without * 4), "吹き出しで極端に遅くならない")
    }
}
