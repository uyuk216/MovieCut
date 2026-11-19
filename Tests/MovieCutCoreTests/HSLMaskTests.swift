import XCTest
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import MovieCutCore

/// HSL マスク(色域で切り分けるマスク)の画素・保存・描画テスト。
/// 形マスク(`ClipMaskTests`)と同じ作法で、実画素を見て確かめる。
final class HSLMaskTests: XCTestCase {
    private let W = 200.0, H = 200.0

    /// 赤(色相 0°)中心の選択。
    private var redSel: HSLSelection {
        HSLSelection(hueCenter: 0, hueWidth: 60, hueFeather: 40, satMin: 0.3, satMax: 1, satFeather: 0.1,
                     lumMin: 0.2, lumMax: 0.8, lumFeather: 0.1)
    }
    private var redMask: HSLMask { HSLMask(selection: redSel) }

    /// 左半分が赤・右半分が青の画像に HSL マスクをかけたあとの画素(RGBA・0〜255)。左上原点の (x, y)。
    private func masked(_ m: HSLMask) -> (Int, Int) -> [Int] {
        let rect = CGRect(x: 0, y: 0, width: W, height: H)
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: W / 2, height: H))
        let blue = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: CGRect(x: W / 2, y: 0, width: W / 2, height: H))
        let img = red.composited(over: blue)
        let out = HSLMaskRenderer.apply(img, source: img, mask: m)
        let cg = EffectPipeline.makeImage(out, from: rect)!
        var d = [UInt8](repeating: 0, count: 200 * 200 * 4)
        let c = CGContext(data: &d, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 800,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(cg, in: rect)
        return { x, y in let i = (y * 200 + x) * 4; return [Int(d[i]), Int(d[i + 1]), Int(d[i + 2]), Int(d[i + 3])] }
    }

    // MARK: 画素(選択の内と外)

    func testSelectedColorKeepsAndOtherClears() {
        let px = masked(redMask)
        XCTAssertEqual(px(50, 100)[3], 255, "選択した赤は残る")
        XCTAssertEqual(px(50, 100)[0], 255, "残った所は元の色")
        XCTAssertEqual(px(150, 100)[3], 0, "選択外の青は透明")
    }

    func testInvertKeepsOutsideAndClearsInside() {
        let px = masked(HSLMask(selection: redSel, invert: true))
        XCTAssertEqual(px(50, 100)[3], 0, "反転すると赤が透明")
        XCTAssertEqual(px(150, 100)[3], 255, "反転すると青が残る")
        XCTAssertEqual(px(150, 100)[2], 255)
    }

    func testFullRangeSelectionKeepsEverything() {
        // 既定の選択(色相は中心 0・幅 90 なので赤以外は落ちる)ではなく、全域を選ぶ選択では全部残る
        let all = HSLMask(selection: HSLSelection(hueWidth: 360, satMin: 0, satMax: 1, satFeather: 0, lumMin: 0, lumMax: 1, lumFeather: 0))
        let px = masked(all)
        XCTAssertEqual(px(50, 100)[3], 255)
        XCTAssertEqual(px(150, 100)[3], 255)
    }

    func testMaskImageMatchesSelectionWeight() {
        // マスク画像の白さが選択の重みと一致する(赤=1、青=0)
        let rect = CGRect(x: 0, y: 0, width: 16, height: 16)
        func maskPixel(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> Int {
            let img = CIImage(color: CIColor(red: r, green: g, blue: b)).cropped(to: rect)
            let out = HSLMaskRenderer.maskImage(from: img, mask: redMask)
            let cg = EffectPipeline.makeImage(out, from: rect)!
            var d = [UInt8](repeating: 0, count: 16 * 16 * 4)
            let c = CGContext(data: &d, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            c.draw(cg, in: rect)
            return Int(d[(8 * 16 + 8) * 4])
        }
        XCTAssertEqual(maskPixel(1, 0, 0), 255, accuracy: 2)
        XCTAssertEqual(maskPixel(0, 0, 1), 0, accuracy: 2)
    }

    func testKeepWeightHonorsInvert() {
        XCTAssertEqual(redMask.keepWeight(r: 1, g: 0, b: 0), 1, accuracy: 1e-12)
        XCTAssertEqual(redMask.keepWeight(r: 0, g: 0, b: 1), 0, accuracy: 1e-12)
        let inv = HSLMask(selection: redSel, invert: true)
        XCTAssertEqual(inv.keepWeight(r: 1, g: 0, b: 0), 0, accuracy: 1e-12)
        XCTAssertEqual(inv.keepWeight(r: 0, g: 0, b: 1), 1, accuracy: 1e-12)
    }

    // MARK: プレビュー(純粋計算)

    func testPreviewGrayOutside() {
        // 重み 1(中)は元の色、重み 0(外)はグレー(赤の輝度 ≒ 0.2126)
        let inside = HSLMaskRenderer.previewed(r: 1, g: 0, b: 0, weight: 1, mode: .grayOutside)
        XCTAssertEqual(inside.r, 1, accuracy: 1e-12); XCTAssertEqual(inside.g, 0, accuracy: 1e-12)
        let outside = HSLMaskRenderer.previewed(r: 1, g: 0, b: 0, weight: 0, mode: .grayOutside)
        XCTAssertEqual(outside.r, 0.2126, accuracy: 1e-9)
        XCTAssertEqual(outside.r, outside.g, accuracy: 1e-12, "外は無彩色")
        XCTAssertEqual(outside.g, outside.b, accuracy: 1e-12)
        let half = HSLMaskRenderer.previewed(r: 1, g: 0, b: 0, weight: 0.5, mode: .grayOutside)
        XCTAssertEqual(half.r, (1 + 0.2126) / 2, accuracy: 1e-9, "中間は混ざる")
    }

    func testPreviewTintInside() {
        let inside = HSLMaskRenderer.previewed(r: 0.2, g: 0.4, b: 0.6, weight: 1, mode: .tintInside)
        XCTAssertEqual(inside.r, 1, accuracy: 1e-12); XCTAssertEqual(inside.g, 0, accuracy: 1e-12); XCTAssertEqual(inside.b, 1, accuracy: 1e-12)
        let outside = HSLMaskRenderer.previewed(r: 0.2, g: 0.4, b: 0.6, weight: 0, mode: .tintInside)
        XCTAssertEqual(outside.r, 0.2, accuracy: 1e-12); XCTAssertEqual(outside.g, 0.4, accuracy: 1e-12); XCTAssertEqual(outside.b, 0.6, accuracy: 1e-12)
    }

    func testPreviewOffIsIdentity() {
        let v = HSLMaskRenderer.previewed(r: 0.3, g: 0.5, b: 0.7, weight: 0.25, mode: .off)
        XCTAssertEqual(v.r, 0.3); XCTAssertEqual(v.g, 0.5); XCTAssertEqual(v.b, 0.7)
    }

    func testPreviewImageKeepsAlphaAndTintsInside() {
        // プレビュー表示は透明度を変えない(切り抜きではなく確認表示)
        let rect = CGRect(x: 0, y: 0, width: 16, height: 16)
        let img = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: rect)
        var m = redMask; m.preview = .tintInside
        let out = HSLMaskRenderer.previewImage(img, source: img, mask: m)
        let cg = EffectPipeline.makeImage(out, from: rect)!
        var d = [UInt8](repeating: 0, count: 16 * 16 * 4)
        let c = CGContext(data: &d, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(cg, in: rect)
        let i = (8 * 16 + 8) * 4
        XCTAssertEqual(Int(d[i + 3]), 255, "アルファは不変")
        XCTAssertEqual(Int(d[i]), 255)
        XCTAssertEqual(Int(d[i + 2]), 255, "選択の中はマゼンタ寄りになる")
        // オフなら入力そのものが返る
        let off = HSLMaskRenderer.previewImage(img, source: img, mask: redMask)
        XCTAssertEqual(off.extent, img.extent)
    }

    // MARK: 保存/復元

    func testFileWritesOnlyNonDefaultFields() throws {
        var c = Clip()
        c.type = .image
        XCTAssertFalse(String(data: try JSONEncoder().encode(c), encoding: .utf8)!.contains("\"hslMask\""), "マスクが無いクリップは書かない")
        c.hslMask = HSLMask()
        let json = String(data: try JSONEncoder().encode(c), encoding: .utf8)!
        XCTAssertTrue(json.contains("\"hslMask\""))
        XCTAssertFalse(json.contains("hueCenter"), "既定値の項目は書かない")
        XCTAssertFalse(json.contains("invert"), "反転が無いときは書かない")
        XCTAssertFalse(json.contains("preview"), "プレビューがオフのときは書かない")
        let back = try JSONDecoder().decode(Clip.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(back.hslMask, HSLMask())
    }

    func testRoundTripPreservesSelectionInvertAndPreview() throws {
        var c = Clip()
        c.type = .image
        c.hslMask = HSLMask(selection: HSLSelection(hueCenter: 200, hueWidth: 40, hueFeather: 10, satMin: 0.2, satMax: 0.9,
                                                    satFeather: 0.05, lumMin: 0.1, lumMax: 0.7, lumFeather: 0.02),
                            invert: true, preview: .grayOutside)
        let back = try JSONDecoder().decode(Clip.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(back.hslMask, c.hslMask)
    }

    func testUnknownKeysArePreserved() throws {
        let json = #"{"id":"x","type":"image","start":0,"duration":1,"hslMask":{"hueCenter":10,"futureField":42}}"#
        let c = try JSONDecoder().decode(Clip.self, from: Data(json.utf8))
        XCTAssertEqual(c.hslMask?.selection.hueCenter, 10)
        let out = String(data: try JSONEncoder().encode(c), encoding: .utf8)!
        XCTAssertTrue(out.contains("futureField"), "知らないキーは書き戻す")
    }

    // MARK: 描画(Renderer)

    func testRendererHSLMaskPixels() throws {
        // キャンバス大きさを固定して割合で確かめる
        let dir = NSTemporaryDirectory() + "hslmask2-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/half.png"
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 40, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 20, height: 40))
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 20, y: 0, width: 20, height: 40))
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try XCTUnwrap(ctx.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))

        func render(_ c: Clip) throws -> (Double, Double) -> [Int] {
            var p = Project.new()
            p.bg = "#00ff00"
            p.tracks[0].clips = [c]
            let img = try XCTUnwrap(Renderer(project: p, assets: RenderAssets()).renderImage(t: 0.5))
            var d = [UInt8](repeating: 0, count: img.width * img.height * 4)
            let g = CGContext(data: &d, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            g.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
            return { fx, fy in
                let i = (Int(fy * Double(img.height)) * img.width + Int(fx * Double(img.width))) * 4
                return [Int(d[i]), Int(d[i + 1]), Int(d[i + 2])]
            }
        }
        func clip(_ m: HSLMask?, shape: ClipMask? = nil) -> Clip {
            var c = Clip()
            c.id = "img"; c.type = .image; c.start = 0; c.duration = 2; c.src = path
            c.hslMask = m; c.mask = shape
            return c
        }

        // HSL マスク: 赤は残り、青の所は背景の緑が見える
        let px = try render(clip(redMask))
        XCTAssertGreaterThan(px(0.25, 0.5)[0], 200, "赤は残る")
        XCTAssertLessThan(px(0.25, 0.5)[2], 60)
        XCTAssertGreaterThan(px(0.75, 0.5)[1], 200, "青の所は背景の緑")
        XCTAssertLessThan(px(0.75, 0.5)[2], 60)

        // 形マスクとの併用: 右半分だけを残す形マスクと重ねると、赤も青も消えて全部背景になる
        // (左=赤は形マスクの外、右=青は HSL の外。積で残る所が無い)
        let both = try render(clip(redMask, shape: ClipMask(x: 0.5, y: 0, w: 0.5, h: 1)))
        XCTAssertGreaterThan(both(0.25, 0.5)[1], 200, "形マスクの外は背景")
        XCTAssertGreaterThan(both(0.75, 0.5)[1], 200, "HSL の外は背景")

        // マスク無しは従来どおり(赤と青がそのまま)
        let plain = try render(clip(nil))
        XCTAssertGreaterThan(plain(0.25, 0.5)[0], 200)
        XCTAssertGreaterThan(plain(0.75, 0.5)[2], 200)
    }
}
