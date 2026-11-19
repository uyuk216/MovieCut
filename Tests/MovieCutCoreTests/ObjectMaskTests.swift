import XCTest
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import MovieCutCore

/// オブジェクトマスク: モデルの保存/復元、伝播(矩形の補間・再検出の付け足し)、
/// クリック/矩形での対象選択、マスク画像の測定・切り抜き・PNG 往復、描画での効き方。
final class ObjectMaskTests: XCTestCase {

    // MARK: 画像の道具

    /// 幅 w・高さ h のグレースケール画像を作る。`white` は左上原点の矩形(その中を白く塗る)。
    private func grayImage(w: Int, h: Int, white: CGRect?) -> CGImage {
        var px = [UInt8](repeating: 0, count: w * h)
        if let r = white {
            for y in 0..<h { for x in 0..<w {
                let p = CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)
                if r.contains(p) { px[y * w + x] = 255 }
            } }
        }
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        // バッファの 1 行目が上端になるよう反転して描いた画像 = 表示どおりの画像にする
        let flipped = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        flipped.translateBy(x: 0, y: CGFloat(h)); flipped.scaleBy(x: 1, y: -1)
        flipped.draw(ctx.makeImage()!, in: CGRect(x: 0, y: 0, width: w, height: h))
        return flipped.makeImage()!
    }

    /// CGImage を RGBA バッファへ読み、左上原点 (x, y) の画素 [R,G,B,A] を返す関数を作る。
    private func sampler(_ cg: CGImage) -> (Int, Int) -> [Int] {
        let w = cg.width, h = cg.height
        var d = [UInt8](repeating: 0, count: w * h * 4)
        let c = CGContext(data: &d, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.translateBy(x: 0, y: CGFloat(h)); c.scaleBy(x: 1, y: -1)
        c.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return { x, y in let i = (y * w + x) * 4; return [Int(d[i]), Int(d[i + 1]), Int(d[i + 2]), Int(d[i + 3])] }
    }

    private func sampleMask(seed: String? = nil, feather: Double = 0, invert: Bool = false,
                            samples: [ObjectMaskSample]? = nil) -> ObjectMask {
        ObjectMask(sourceClipId: "src", seedTime: 0, seedRect: TrackRect(x: 0.25, y: 0.25, w: 0.5, h: 0.5),
                   seedMask: seed, feather: feather, invert: invert,
                   samples: samples ?? [ObjectMaskSample(t: 0, rect: TrackRect(x: 0.25, y: 0.25, w: 0.5, h: 0.5)),
                                        ObjectMaskSample(t: 2, rect: TrackRect(x: 0.25, y: 0.25, w: 0.5, h: 0.5))])
    }

    /// 200×200 の赤へオブジェクトマスクをかけたあとの画素(左上原点)。
    private func masked(_ om: ObjectMask, at t: Double = 0) -> (Int, Int) -> [Int] {
        let W = 200.0, H = 200.0
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: W, height: H))
        let out = ObjectMaskRenderer.apply(red, objectMask: om, at: t, canvasWidth: W, canvasHeight: H, originX: 0, originY: 0)
        let cg = EffectPipeline.makeImage(out, from: CGRect(x: 0, y: 0, width: W, height: H))!
        return sampler(cg)
    }

    // MARK: モデルの保存/復元

    func testRoundTripAndDefaultsOmitted() throws {
        let om = sampleMask(seed: "QUJD", feather: 0.25, invert: true)
        let data = try JSONEncoder().encode(om)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertTrue(json.contains("\"seedMask\""))
        let back = try JSONDecoder().decode(ObjectMask.self, from: data)
        XCTAssertEqual(back, om)

        let plain = sampleMask()
        let plainJson = String(data: try JSONEncoder().encode(plain), encoding: .utf8)!
        XCTAssertFalse(plainJson.contains("feather"), "羽根 0 は書かない")
        XCTAssertFalse(plainJson.contains("invert"), "反転なしは書かない")
        XCTAssertFalse(plainJson.contains("seedTime"), "種時刻 0 は書かない")
        XCTAssertFalse(plainJson.contains("seedMask"), "種マスクなしは書かない")
    }

    func testUnknownKeysArePreserved() throws {
        let json = #"{"sourceClipId":"s","seedRect":{"x":0.1,"y":0.1,"w":0.2,"h":0.2},"samples":[{"t":0,"rect":{"x":0.1,"y":0.1,"w":0.2,"h":0.2}}],"futureField":42}"#
        let om = try JSONDecoder().decode(ObjectMask.self, from: Data(json.utf8))
        XCTAssertEqual(om.extra["futureField"], .number(42))
        let out = String(data: try JSONEncoder().encode(om), encoding: .utf8)!
        XCTAssertTrue(out.contains("\"futureField\":42"), "知らないキーはそのまま書き戻す: \(out)")
    }

    func testNormalizedClampsAndSorts() {
        var om = sampleMask(feather: 7)
        om.samples = [ObjectMaskSample(t: 2, rect: TrackRect(x: 0, y: 0, w: 0.2, h: 0.2)),
                      ObjectMaskSample(t: -1, rect: TrackRect(x: 0, y: 0, w: 0.2, h: 0.2)),
                      ObjectMaskSample(t: 1, rect: TrackRect(x: 0, y: 0, w: 0.2, h: 0.2))]
        let n = om.normalized
        XCTAssertEqual(n.feather, 1, "羽根は 0〜1 に丸める")
        XCTAssertEqual(n.samples.map(\.t), [1, 2], "負の時刻は落とし、時刻順に並べる")
    }

    func testClipRoundTrip() throws {
        var c = Clip()
        c.type = .video
        XCTAssertFalse(String(data: try JSONEncoder().encode(c), encoding: .utf8)!.contains("\"objectMask\""),
                       "オブジェクトマスクが無いクリップは書かない")
        c.objectMask = sampleMask(seed: "QUJD")
        let back = try JSONDecoder().decode(Clip.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(back.objectMask, c.objectMask)

        // 有効サンプルが無いオブジェクトマスクは未設定として読む(tracking と同じ作法)
        var broken = Clip()
        broken.objectMask = ObjectMask(sourceClipId: "s", seedRect: TrackRect(x: 0, y: 0, w: 0.5, h: 0.5),
                                       samples: [ObjectMaskSample(t: 0, rect: nil)])
        let brokenBack = try JSONDecoder().decode(Clip.self, from: JSONEncoder().encode(broken))
        XCTAssertNil(brokenBack.objectMask)
    }

    // MARK: 伝播(補間・付け足し)

    func testRectInterpolationAndGap() {
        let om = ObjectMask(sourceClipId: "s", seedRect: TrackRect(x: 0.1, y: 0.1, w: 0.2, h: 0.2), samples: [
            ObjectMaskSample(t: 0, rect: TrackRect(x: 0.1, y: 0.1, w: 0.2, h: 0.2)),
            ObjectMaskSample(t: 1, rect: TrackRect(x: 0.3, y: 0.1, w: 0.2, h: 0.2)),
            ObjectMaskSample(t: 5, rect: TrackRect(x: 0.9, y: 0.1, w: 0.2, h: 0.2)),
        ])
        XCTAssertEqual(om.rect(at: 0.5)?.x ?? -1, 0.2, accuracy: 1e-9, "前後を線形補間")
        XCTAssertNil(om.rect(at: 3), "検出の間隔が広い中間は補間しない")
        XCTAssertEqual(om.rect(at: 4.6)?.x ?? -1, 0.9, accuracy: 1e-9, "近い検出は maxGap まで使う")
        XCTAssertNil(om.rect(at: 100))
    }

    func testBuildFromTrackAndAttachMask() {
        let track = ObjectTrack(sourceClipId: "src", startRect: TrackRect(x: 0.4, y: 0.4, w: 0.2, h: 0.2), samples: [
            TrackSample(t: 0, rect: TrackRect(x: 0.4, y: 0.4, w: 0.2, h: 0.2)),
            TrackSample(t: 0.1, rect: nil),
            TrackSample(t: 0.2, rect: TrackRect(x: 0.5, y: 0.4, w: 0.2, h: 0.2)),
        ])
        var om = ObjectMaskPropagation.build(sourceClipId: "src", seedTime: 0,
                                             seedRect: TrackRect(x: 0.4, y: 0.4, w: 0.2, h: 0.2),
                                             seedMaskBase64: "SEED", track: track)
        XCTAssertNotNil(om)
        XCTAssertEqual(om?.samples.count, 3, "見失いサンプルも列に残る(補間で扱う)")
        XCTAssertNil(om?.samples[1].rect)
        XCTAssertEqual(om?.maskBase64(at: 0.2), "SEED", "サンプルに輪郭が無ければ種マスク")
        XCTAssertTrue(ObjectMaskPropagation.attachMask("NEAR", at: 0.21, to: &om!))
        XCTAssertEqual(om?.maskBase64(at: 0.2), "NEAR", "近いサンプルの輪郭を優先")
        // maxGap(1 秒)より遠いサンプルの輪郭は使わず、種マスクに落ちる
        let sparse = ObjectMask(sourceClipId: "s", seedRect: TrackRect(x: 0, y: 0, w: 0.2, h: 0.2), seedMask: "SEED", samples: [
            ObjectMaskSample(t: 0, rect: TrackRect(x: 0, y: 0, w: 0.2, h: 0.2)),
            ObjectMaskSample(t: 5, rect: TrackRect(x: 0.5, y: 0, w: 0.2, h: 0.2), mask: "FAR"),
        ])
        XCTAssertEqual(sparse.maskBase64(at: 0), "SEED", "maxGap より遠いサンプル輪郭は使わない")
        XCTAssertEqual(sparse.maskBase64(at: 4.6), "FAR", "maxGap 以内なら近いサンプルの輪郭")

        let empty = ObjectTrack(sourceClipId: "s", startRect: TrackRect(x: 0, y: 0, w: 1, h: 1),
                                samples: [TrackSample(t: 0, rect: nil)])
        XCTAssertNil(ObjectMaskPropagation.build(sourceClipId: "s", seedTime: 0,
                                                 seedRect: TrackRect(x: 0, y: 0, w: 1, h: 1),
                                                 seedMaskBase64: nil, track: empty),
                     "有効な追跡が無ければ作らない")
    }

    // MARK: 対象の選択

    func testPickInstanceByPointAndRect() {
        let instances = [TrackRect(x: 0, y: 0, w: 0.6, h: 0.6),          // 大きな背景物
                         TrackRect(x: 0.4, y: 0.4, w: 0.2, h: 0.2),      // 狙った対象
                         TrackRect(x: 0.7, y: 0.05, w: 0.1, h: 0.1)]
        XCTAssertEqual(ObjectMaskPropagation.pickInstance(at: CGPoint(x: 0.5, y: 0.5), instances: instances), 1,
                       "点を含む一番小さいインスタンスを選ぶ")
        XCTAssertEqual(ObjectMaskPropagation.pickInstance(at: CGPoint(x: 0.73, y: 0.08), instances: instances), 2)
        XCTAssertEqual(ObjectMaskPropagation.pickInstance(at: CGPoint(x: 0.1, y: 0.65), instances: instances), 0,
                       "含むものが無ければ中心が一番近いもの")
        XCTAssertNil(ObjectMaskPropagation.pickInstance(at: CGPoint(x: 0.5, y: 0.5), instances: []))
        XCTAssertEqual(ObjectMaskPropagation.pickInstance(overlapping: TrackRect(x: 0.38, y: 0.38, w: 0.24, h: 0.24), instances: instances), 1,
                       "矩形指定では IoU が最大のもの(大きな背景物ではなく、枠に収まる対象)を選ぶ")
        XCTAssertNil(ObjectMaskPropagation.pickInstance(overlapping: TrackRect(x: 0.95, y: 0.95, w: 0.05, h: 0.05),
                                                        instances: [TrackRect(x: 0, y: 0, w: 0.2, h: 0.2)]))
    }

    // MARK: マスク画像

    func testBoundingRectUsesTopLeftOrigin() {
        // 左上のブロック(左上原点で x 10..<40, y 5..<25)
        let img = grayImage(w: 100, h: 100, white: CGRect(x: 10, y: 5, width: 30, height: 20))
        let r = ObjectMaskImage.boundingRect(ofMask: img)
        XCTAssertEqual(r?.x ?? -1, 0.10, accuracy: 0.011)
        XCTAssertEqual(r?.y ?? -1, 0.05, accuracy: 0.011)
        XCTAssertEqual(r?.w ?? -1, 0.30, accuracy: 0.011)
        XCTAssertEqual(r?.h ?? -1, 0.20, accuracy: 0.011)
        XCTAssertNil(ObjectMaskImage.boundingRect(ofMask: grayImage(w: 20, h: 20, white: nil)), "白が無ければ nil")
    }

    func testPNGRoundTripAndDownscale() throws {
        let img = grayImage(w: 100, h: 80, white: CGRect(x: 0, y: 0, width: 50, height: 80))
        let b64 = try XCTUnwrap(ObjectMaskImage.pngBase64(of: img))
        let back = try XCTUnwrap(ObjectMaskImage.image(fromBase64: b64))
        XCTAssertEqual(back.width, 100); XCTAssertEqual(back.height, 80)
        let r = ObjectMaskImage.boundingRect(ofMask: back)
        XCTAssertEqual(r?.w ?? -1, 0.5, accuracy: 0.02, "PNG 往復で輪郭の外接矩形が保たれる")

        let big = grayImage(w: 800, h: 400, white: CGRect(x: 0, y: 0, width: 800, height: 400))
        let small = ObjectMaskImage.downscaled(big, maxSide: 256)
        XCTAssertEqual(max(small.width, small.height), 256)
        XCTAssertEqual(small.height, 128, "縦横比を保つ")
        XCTAssertNil(ObjectMaskImage.image(fromBase64: "壊れた文字列"))
        XCTAssertNil(ObjectMaskImage.image(fromBase64: nil))
    }

    func testCropped() throws {
        let img = grayImage(w: 100, h: 100, white: CGRect(x: 0, y: 0, width: 100, height: 100))
        let c = try XCTUnwrap(ObjectMaskImage.cropped(img, toNormalized: TrackRect(x: 0.25, y: 0.25, w: 0.5, h: 0.5)))
        XCTAssertEqual(c.width, 50); XCTAssertEqual(c.height, 50)
        XCTAssertNil(ObjectMaskImage.cropped(img, toNormalized: TrackRect(x: 2, y: 2, w: 0.5, h: 0.5)), "画面の外は nil")
    }

    // MARK: 描画

    func testSeedMaskKeepsOnlyObjectSilhouette() throws {
        // 種マスクは外接矩形の中身: 左半分だけ白
        let seed = try XCTUnwrap(ObjectMaskImage.pngBase64(of: grayImage(w: 100, h: 100, white: CGRect(x: 0, y: 0, width: 50, height: 100))))
        let px = masked(sampleMask(seed: seed))
        XCTAssertEqual(px(60, 100)[3], 255, "矩形内の白い側は残る")
        XCTAssertEqual(px(140, 100)[3], 0, "矩形内でも輪郭の外(黒い側)は透明")
        XCTAssertEqual(px(10, 10)[3], 0, "矩形の外は透明")
    }

    func testSeedMaskVerticalOrientation() throws {
        // 種マスクの上半分だけ白 → キャンバスの上側が残る(上下が反転しないこと)
        let seed = try XCTUnwrap(ObjectMaskImage.pngBase64(of: grayImage(w: 100, h: 100, white: CGRect(x: 0, y: 0, width: 100, height: 50))))
        let px = masked(sampleMask(seed: seed))
        XCTAssertEqual(px(100, 60)[3], 255, "矩形の上半分は残る")
        XCTAssertEqual(px(100, 140)[3], 0, "矩形の下半分は透明")
    }

    func testEllipseFallbackInvertAndFeather() {
        // 輪郭なし → 楕円近似: 矩形の角は透明、中心は残る
        let px = masked(sampleMask())
        XCTAssertEqual(px(100, 100)[3], 255)
        XCTAssertEqual(px(55, 55)[3], 0, "矩形の中でも楕円の外の角は透明")

        let inv = masked(sampleMask(invert: true))
        XCTAssertEqual(inv(100, 100)[3], 0, "反転: 中は透明")
        XCTAssertEqual(inv(5, 5)[3], 255, "反転: 外は残る")

        let fea = masked(sampleMask(feather: 0.5))
        let row = (30...70).map { fea($0, 100)[3] }
        for i in 1..<row.count { XCTAssertGreaterThanOrEqual(row[i], row[i - 1], "羽根の境目は単調") }
        XCTAssertTrue(row.contains { $0 > 20 && $0 < 235 }, "中間の値がある")
    }

    func testMaskFollowsInterpolatedRect() {
        // t=0 で左、t=2 で右へ動く対象。中間では間を補間した位置にマスクがある
        let om = ObjectMask(sourceClipId: "s", seedRect: TrackRect(x: 0, y: 0.4, w: 0.2, h: 0.2), samples: [
            ObjectMaskSample(t: 0, rect: TrackRect(x: 0, y: 0.4, w: 0.2, h: 0.2)),
            ObjectMaskSample(t: 2, rect: TrackRect(x: 0.8, y: 0.4, w: 0.2, h: 0.2)),
        ])
        let px = masked(om, at: 1)
        XCTAssertEqual(px(100, 100)[3], 255, "中間時刻では中央にマスクがある")
        XCTAssertEqual(px(20, 100)[3], 0, "開始位置にはもう無い")
    }

    func testNoMaskWhenTargetLost() {
        let om = ObjectMask(sourceClipId: "s", seedRect: TrackRect(x: 0.25, y: 0.25, w: 0.5, h: 0.5),
                            samples: [ObjectMaskSample(t: 0, rect: TrackRect(x: 0.25, y: 0.25, w: 0.5, h: 0.5))])
        let px = masked(om, at: 30)
        XCTAssertEqual(px(5, 5)[3], 255, "見失った時刻(maxGap 超え)はマスクをかけない")
        XCTAssertEqual(px(100, 100)[3], 255)
    }

    /// 描画の入口: 動画・画像クリップにオブジェクトマスクをかけると、外は背景になる。
    func testRendererAppliesObjectMaskOnClip() throws {
        let dir = NSTemporaryDirectory() + "objmask-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/red.png"
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 40, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try XCTUnwrap(ctx.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))

        var p = Project.new()
        p.bg = "#0000ff"
        var c = Clip()
        c.id = "img"; c.type = .image; c.start = 0; c.duration = 2; c.src = path
        c.objectMask = sampleMask()
        p.tracks[0].clips = [c]
        let img = try XCTUnwrap(Renderer(project: p, assets: RenderAssets()).renderImage(t: 0.5))
        let px = sampler(img)
        func at(_ fx: Double, _ fy: Double) -> [Int] { px(Int(fx * Double(img.width)), Int(fy * Double(img.height))) }
        XCTAssertGreaterThan(at(0.5, 0.5)[0], 200, "対象の中は赤(残る)")
        XCTAssertGreaterThan(at(0.05, 0.05)[2], 200, "対象の外は背景の青")
        XCTAssertLessThan(at(0.05, 0.05)[0], 60)
    }
}
