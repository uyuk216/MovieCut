import XCTest
import CoreGraphics
@testable import MovieCutCore

/// オプティカルフロー補間: 既知の動きでの中間のコマの位置、Vision のフローの向き、場面の切り替え、キャッシュ、ファイル、描画経路、速度。
final class OpticalFlowTests: XCTestCase {
    /// 暗い背景(模様つき)に明るい四角を (x, y) に置いた w×h の画像。背景の模様は、フローが求めやすいようにする。
    func scene(w: Int, h: Int, squareX: Int, squareY: Int = 0, size: Int = 40) -> CGImage {
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        let sy = squareY == 0 ? (h - size) / 2 : squareY
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let o = (y * w + x) * 4
                let tex = UInt8(30 + ((x / 4 + y / 4) % 2) * 10)        // 薄い市松
                var v = tex
                if x >= squareX && x < squareX + size && y >= sy && y < sy + size { v = 230 }
                px[o] = v; px[o + 1] = v; px[o + 2] = v; px[o + 3] = 255
            }
        }
        let ctx = px.withUnsafeMutableBytes { CGContext(data: $0.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info)! }
        return ctx.makeImage()!
    }

    /// 明るい四角(輝度 > 150)の左端の x(行は中央)
    func squareLeft(_ img: CGImage) -> Int? {
        let w = img.width, h = img.height
        guard let bm = OpticalFlowInterpolator.bitmap(of: img, width: w, height: h) else { return nil }
        let y = h / 2
        for x in 0..<w where bm.bytes[(y * w + x) * 4 + 1] > 150 { return x }
        return nil
    }

    /// 画素 (x, y) の緑(輝度の代わり)
    func green(_ img: CGImage, _ x: Int, _ y: Int) -> Int {
        let bm = OpticalFlowInterpolator.bitmap(of: img, width: img.width, height: img.height)!
        return Int(bm.bytes[(y * img.width + x) * 4 + 1])
    }

    /// 滑らかなノイズ(16 画素の格子を双一次補間)を右へ `shiftX` だけずらした画像。模様のある「実写の代わり」。
    func noise(w: Int, h: Int, shiftX: Double, seed: UInt64 = 7) -> CGImage {
        var rng = seed
        func rnd() -> Double { rng = rng &* 6364136223846793005 &+ 1442695040888963407; return Double((rng >> 33) & 0xFFFF) / 65535 }
        let cell = 16
        let gw = w / cell + 3, gh = h / cell + 3
        let grid = (0..<(gw * gh)).map { _ in rnd() }
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let fx = (Double(x) - shiftX) / Double(cell) + 1, fy = Double(y) / Double(cell) + 1
            let x0 = Int(floor(fx)), y0 = Int(floor(fy)); let tx = fx - Double(x0), ty = fy - Double(y0)
            func g(_ a: Int, _ b: Int) -> Double { grid[min(max(b, 0), gh - 1) * gw + min(max(a, 0), gw - 1)] }
            let v = (g(x0, y0) * (1 - tx) + g(x0 + 1, y0) * tx) * (1 - ty) + (g(x0, y0 + 1) * (1 - tx) + g(x0 + 1, y0 + 1) * tx) * ty
            let o = (y * w + x) * 4; let b = UInt8(40 + v * 180)
            px[o] = b; px[o + 1] = b; px[o + 2] = b; px[o + 3] = 255
        } }
        let ctx = px.withUnsafeMutableBytes { CGContext(data: $0.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)! }
        return ctx.makeImage()!
    }

    /// 2 枚の平均絶対誤差(緑のチャンネル、中央付近だけ。端はずらしで出る隙間があるので除く)
    func mae(_ a: CGImage, _ b: CGImage, margin: Int = 24) -> Double {
        let ba = OpticalFlowInterpolator.bitmap(of: a, width: a.width, height: a.height)!, bb = OpticalFlowInterpolator.bitmap(of: b, width: a.width, height: a.height)!
        var sum = 0, n = 0
        for y in margin..<(a.height - margin) { for x in margin..<(a.width - margin) {
            sum += abs(Int(ba.bytes[(y * a.width + x) * 4 + 1]) - Int(bb.bytes[(y * a.width + x) * 4 + 1])); n += 1
        } }
        return Double(sum) / Double(n)
    }

    // MARK: 既知の動きでのワープ

    func testKnownFlowPlacesTheSquareAtTheInterpolatedPosition() throws {
        let a = scene(w: 320, h: 180, squareX: 100), b = scene(w: 320, h: 180, squareX: 140)
        let f = FlowField.constant(width: 320, height: 180, dx: 40, dy: 0)
        for (w, expect) in [(0.25, 110), (0.5, 120), (0.75, 130)] {
            let m = try XCTUnwrap(OpticalFlowInterpolator.interpolate(a, b, weight: w, flow: f))
            XCTAssertEqual(m.width, 320); XCTAssertEqual(m.height, 180)
            XCTAssertEqual(try XCTUnwrap(squareLeft(m)), expect, accuracy: 2, "w=\(w)")
            XCTAssertGreaterThan(green(m, expect + 20, 90), 220, "四角の中は明るいまま(二重にならない)")
        }
    }

    func testFlowInterpolationHasNoDoubleImageUnlikeBlend() throws {
        let a = scene(w: 320, h: 180, squareX: 100), b = scene(w: 320, h: 180, squareX: 140)
        let flow = try XCTUnwrap(OpticalFlowInterpolator.interpolate(a, b, weight: 0.5, flow: .constant(width: 320, height: 180, dx: 40, dy: 0)))
        let blend = try XCTUnwrap(FrameBlend.mix(a, b, weight: 0.5))
        // A の四角があった場所(x = 105)は、フローでは背景(暗い)、ブレンドでは半分の明るさ(残像)
        XCTAssertLessThan(green(flow, 105, 90), 60)
        XCTAssertGreaterThan(green(blend, 105, 90), 100)
        XCTAssertLessThan(green(flow, 175, 90), 60, "B の四角の端の外側も、フローでは背景")
        XCTAssertGreaterThan(green(blend, 175, 90), 100)
    }

    func testFlowGridSmallerThanTheImageIsScaledUp() throws {
        let a = scene(w: 320, h: 180, squareX: 100), b = scene(w: 320, h: 180, squareX: 140)
        // 半分の大きさのグリッドで、動きは 20(= 元の画素で 40)
        let m = try XCTUnwrap(OpticalFlowInterpolator.interpolate(a, b, weight: 0.5, flow: .constant(width: 160, height: 90, dx: 20, dy: 0)))
        XCTAssertEqual(try XCTUnwrap(squareLeft(m)), 120, accuracy: 2)
    }

    func testVerticalAndNegativeMotion() throws {
        let a = scene(w: 320, h: 180, squareX: 140, squareY: 50), b = scene(w: 320, h: 180, squareX: 100, squareY: 90)
        let m = try XCTUnwrap(OpticalFlowInterpolator.interpolate(a, b, weight: 0.5, flow: .constant(width: 320, height: 180, dx: -40, dy: 40)))
        XCTAssertEqual(try XCTUnwrap(squareLeft(m)), 120, accuracy: 2)
        XCTAssertGreaterThan(green(m, 140, 90), 220, "四角の中央(120+20, 70+20)")
        XCTAssertLessThan(green(m, 140, 130), 60, "その下は背景")
    }

    func testEndpointsAndMismatchedSizes() throws {
        let a = scene(w: 64, h: 36, squareX: 10, size: 8), b = scene(w: 64, h: 36, squareX: 20, size: 8)
        let f = FlowField.constant(width: 64, height: 36, dx: 10, dy: 0)
        XCTAssertTrue(try XCTUnwrap(OpticalFlowInterpolator.interpolate(a, b, weight: 0, flow: f)) === a)
        XCTAssertTrue(try XCTUnwrap(OpticalFlowInterpolator.interpolate(a, b, weight: 1, flow: f)) === b)
        XCTAssertTrue(try XCTUnwrap(OpticalFlowInterpolator.interpolate(a, b, weight: -2, flow: f)) === a)
        let other = scene(w: 32, h: 18, squareX: 4, size: 4)
        XCTAssertNil(OpticalFlowInterpolator.interpolate(a, other, weight: 0.5, flow: f))
        XCTAssertNil(OpticalFlowInterpolator.interpolate(a, b, weight: 0.5, flow: FlowField(width: 0, height: 0, data: [])))
        let tiny = FlowField.constant(width: 1, height: 1, dx: 3, dy: 0)
        XCTAssertNotNil(OpticalFlowInterpolator.interpolate(a, b, weight: 0.5, flow: tiny), "1×1 のグリッドでも落ちない")
    }

    func testFlowSampleIsBilinearAndClamped() {
        var f = FlowField.constant(width: 4, height: 2, dx: 0, dy: 0)
        f.data[2 * 1] = 10          // (x=1, y=0) の dx
        XCTAssertEqual(f.sample(1, 0).0, 10, accuracy: 1e-5)
        XCTAssertEqual(f.sample(0.5, 0).0, 5, accuracy: 1e-5)
        XCTAssertEqual(f.sample(1, 0.5).0, 5, accuracy: 1e-5)
        XCTAssertEqual(f.sample(-9, -9).0, 0, accuracy: 1e-5, "範囲の外は端の値")
        XCTAssertEqual(f.sample(99, 99).0, 0, accuracy: 1e-5)
    }

    // MARK: Vision のフロー

    func testVisionFlowPointsFromAToBAndRefinementRecoversMostOfTheMotion() throws {
        let a = noise(w: 640, h: 360, shiftX: 0), b = noise(w: 640, h: 360, shiftX: 16)
        let one = try XCTUnwrap(OpticalFlowInterpolator.flow(from: a, to: b, passes: 1), "Vision がフローを返さない")
        let full = try XCTUnwrap(OpticalFlowInterpolator.flow(from: a, to: b))
        XCTAssertEqual(full.width, 320, "縮小グリッド(長辺 320)")
        func mean(_ f: FlowField) -> (Double, Double) {
            var sx = 0.0, sy = 0.0, n = 0.0
            for y in stride(from: 30, to: f.height - 30, by: 6) { for x in stride(from: 40, to: f.width - 40, by: 6) {
                let s = f.sample(Float(x), Float(y)); sx += Double(s.0); sy += Double(s.1); n += 1 } }
            return (sx / n, sy / n)
        }
        let trueDx = 16.0 * Double(full.width) / 640      // グリッドでの動き = 8
        let (d1, _) = mean(one), (d3, y3) = mean(full)
        print("[OpticalFlow] true dx \(trueDx) grid px; vision 1 pass \(String(format: "%.2f", d1)); refined \(String(format: "%.2f", d3)), dy \(String(format: "%.2f", y3))")
        XCTAssertGreaterThan(d1, 0, "右へ動けば正の dx(A→B の向き)")
        XCTAssertGreaterThan(d3, d1, "繰り返しで、足りなかった動きが戻る")
        XCTAssertGreaterThan(d3, trueDx * 0.8)
        XCTAssertLessThan(d3, trueDx * 1.15)
        XCTAssertLessThan(abs(y3), 0.6, "縦には動いていない")
    }

    func testVisionFlowInterpolationBeatsBlendOnTexturedMotion() throws {
        let a = noise(w: 320, h: 180, shiftX: 0), b = noise(w: 320, h: 180, shiftX: 12), truth = noise(w: 320, h: 180, shiftX: 6)
        let f = try XCTUnwrap(OpticalFlowInterpolator.flow(from: a, to: b))
        let flow = try XCTUnwrap(OpticalFlowInterpolator.interpolate(a, b, weight: 0.5, flow: f))
        let blend = try XCTUnwrap(FrameBlend.mix(a, b, weight: 0.5))
        let ef = mae(flow, truth), eb = mae(blend, truth)
        print("[OpticalFlow] MAE vs true midpoint: flow \(String(format: "%.2f", ef)) blend \(String(format: "%.2f", eb))")
        XCTAssertLessThan(ef, eb * 0.6, "動きに沿った中間のコマは、重ね合わせよりずっと本物に近い")
    }

    // MARK: 入口(キャッシュ・場面の切り替え・失敗)

    func testFrameUsesTheCacheOncePerPair() throws {
        let a = noise(w: 320, h: 180, shiftX: 0), b = noise(w: 320, h: 180, shiftX: 8)
        let cache = FlowCache(capacity: 2)
        for w in [0.2, 0.4, 0.6, 0.8] { XCTAssertNotNil(OpticalFlowInterpolator.frame(a, b, weight: w, key: "k1", cache: cache)) }
        XCTAssertEqual(cache.computeCount, 1, "同じコマの組は、フローを 1 回だけ求める")
        XCTAssertNotNil(OpticalFlowInterpolator.frame(a, b, weight: 0.5, key: "k2", cache: cache))
        XCTAssertNotNil(OpticalFlowInterpolator.frame(a, b, weight: 0.5, key: "k3", cache: cache))
        XCTAssertEqual(cache.count, 2, "容量を超えたら古いものから捨てる")
        XCTAssertEqual(cache.computeCount, 3)
        XCTAssertNotNil(OpticalFlowInterpolator.frame(a, b, weight: 0.5, key: "k1", cache: cache))
        XCTAssertEqual(cache.computeCount, 4, "捨てられた組は求め直す")
    }

    func testSceneCutHoldsTheNearerFrameInsteadOfSmearing() throws {
        let a = scene(w: 320, h: 180, squareX: 100)            // 暗い場面
        let bright = noise(w: 320, h: 180, shiftX: 0)
        // 輝度がまるで違う場面へ(平均 40 → 平均 130 前後)
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        let ctx = CGContext(data: nil, width: 320, height: 180, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info)!
        ctx.setFillColor(gray: 0.9, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
        let white = ctx.makeImage()!
        _ = bright
        let cache = FlowCache()
        XCTAssertTrue(try XCTUnwrap(OpticalFlowInterpolator.frame(a, white, weight: 0.3, key: "cut", cache: cache)) === a)
        XCTAssertTrue(try XCTUnwrap(OpticalFlowInterpolator.frame(a, white, weight: 0.7, key: "cut", cache: cache)) === white)
        XCTAssertEqual(cache.computeCount, 1, "切り替わりの判定もキャッシュされる")
    }

    func testFrameFailsToNilWhenSizesDiffer() {
        let a = scene(w: 64, h: 36, squareX: 4, size: 8), b = scene(w: 32, h: 18, squareX: 2, size: 4)
        XCTAssertNil(OpticalFlowInterpolator.frame(a, b, weight: 0.5, key: "x", cache: FlowCache()))
        XCTAssertTrue(OpticalFlowInterpolator.frame(a, b, weight: 0, key: "x", cache: FlowCache()) === a)
        XCTAssertTrue(OpticalFlowInterpolator.frame(a, b, weight: 1, key: "x", cache: FlowCache()) === b)
    }

    // MARK: 速さ

    func testCostAt1080p() throws {
        let a = noise(w: 1920, h: 1080, shiftX: 0), b = noise(w: 1920, h: 1080, shiftX: 12)
        let t0 = CFAbsoluteTimeGetCurrent()
        let f = try XCTUnwrap(OpticalFlowInterpolator.flow(from: a, to: b))
        let tFlow = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        _ = OpticalFlowInterpolator.interpolate(a, b, weight: 0.5, flow: f)
        let n = 3
        let t1 = CFAbsoluteTimeGetCurrent()
        for _ in 0..<n { XCTAssertNotNil(OpticalFlowInterpolator.interpolate(a, b, weight: 0.5, flow: f)) }
        let tWarp = (CFAbsoluteTimeGetCurrent() - t1) * 1000 / Double(n)
        let t2 = CFAbsoluteTimeGetCurrent()
        for _ in 0..<n { _ = FrameBlend.mix(a, b, weight: 0.5) }
        let tBlend = (CFAbsoluteTimeGetCurrent() - t2) * 1000 / Double(n)
        print("[OpticalFlow] 1920x1080: flow (320 grid, \(OpticalFlowInterpolator.refinePasses) passes) \(String(format: "%.0f", tFlow)) ms/pair (cached per pair), warp+blend \(String(format: "%.1f", tWarp)) ms/frame, FrameBlend \(String(format: "%.1f", tBlend)) ms/frame")
    }
}

// MARK: - ファイル・描画経路・書き出し

import AVFoundation

extension OpticalFlowTests {
    var tmp: URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("opticalflow-tests-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// 模様が毎コマ 3 画素ずつ右へ動く動画(30fps・320×180・H.264)。
    func makeMovingVideo(frames: Int = 12, perFrame: Double = 3, fps: Int32 = 30) throws -> URL {
        let url = tmp.appendingPathComponent("moving-\(UUID().uuidString).mp4")
        let w = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000, AVVideoMaxKeyFrameIntervalKey: 6],
        ])
        let ad = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180])
        w.add(input)
        XCTAssertTrue(w.startWriting())
        w.startSession(atSourceTime: .zero)
        for i in 0..<frames {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, ad.pixelBufferPool!, &pb)
            let buf = try XCTUnwrap(pb)
            let img = noise(w: 320, h: 180, shiftX: perFrame * Double(i))
            let bm = try XCTUnwrap(OpticalFlowInterpolator.bitmap(of: img, width: 320, height: 180))
            CVPixelBufferLockBaseAddress(buf, [])
            let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
            let bpr = CVPixelBufferGetBytesPerRow(buf)
            for y in 0..<180 { for x in 0..<320 {
                let o = y * bpr + x * 4, s = (y * 320 + x) * 4
                base[o] = bm.bytes[s]; base[o + 1] = bm.bytes[s + 1]; base[o + 2] = bm.bytes[s + 2]; base[o + 3] = 255
            } }
            CVPixelBufferUnlockBaseAddress(buf, [])
            XCTAssertTrue(ad.append(buf, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps)))
        }
        input.markAsFinished()
        let done = expectation(description: "write")
        w.finishWriting { done.fulfill() }
        wait(for: [done], timeout: 30)
        XCTAssertEqual(w.status, .completed)
        return url
    }

    /// 速度 0.5 の動画クリップ 1 つのプロジェクト(320×180・30fps)。`mode` で補間の方式。
    func slowProject(_ url: URL, mode: FrameInterpolation) -> Project {
        var c = Clip(); c.id = "v"; c.type = .video; c.src = url.path; c.start = 0; c.duration = 0.7; c.offset = 0; c.srcDuration = 0.4; c.speed = 0.5
        c.setFrameInterpolation(mode)
        var p = Project(); p.width = 320; p.height = 180; p.fps = 30; p.bg = "#000000"; p.characters = []
        var t = Track(name: "L1"); t.clips = [c]; p.tracks = [t]
        return p
    }

    // MARK: ファイル

    func testFileFormatWritesFrameFlowOnlyWhenTrue() throws {
        var c = Clip(); c.id = "v"; c.type = .video; c.src = "/tmp/a.mp4"; c.start = 0; c.duration = 1
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        let plain = String(decoding: try enc.encode(c), as: UTF8.self)
        XCTAssertFalse(plain.contains("frameFlow"))
        c.frameFlow = false
        XCTAssertEqual(String(decoding: try enc.encode(c), as: UTF8.self), plain, "false は書かない")
        c.frameFlow = true
        let s = String(decoding: try enc.encode(c), as: UTF8.self)
        XCTAssertTrue(s.contains("\"frameFlow\":true"))
        let back = try JSONDecoder().decode(Clip.self, from: Data(s.utf8))
        XCTAssertEqual(back.frameFlow, true)
        XCTAssertEqual(String(decoding: try enc.encode(back), as: UTF8.self), s, "往復でバイト一致")
        XCTAssertNil(back.extra["frameFlow"], "未知のキーとしては残らない")
    }

    func testOldFilesAreUntouchedByTheNewKey() throws {
        let files = (Bundle.module.urls(forResourcesWithExtension: "ymproj", subdirectory: "Fixtures") ?? [])
            + (Bundle.module.urls(forResourcesWithExtension: "json", subdirectory: "Fixtures") ?? [])
        XCTAssertFalse(files.isEmpty)
        for f in files where f.lastPathComponent != "golden-electron-made.json" || true {
            guard let p = try? Project.load(from: f) else { continue }       // プロジェクトでない JSON は飛ばす
            let once = try p.encoded()
            XCTAssertFalse(String(decoding: once, as: UTF8.self).contains("frameFlow"), f.lastPathComponent)
            XCTAssertEqual(try Project.decode(from: once).encoded(), once, "\(f.lastPathComponent): 書き直しても変わらない")
        }
    }

    func testInterpolationModeIsExclusiveAndFlowWins() {
        var c = Clip(); c.type = .video
        XCTAssertEqual(c.frameInterpolation, .none)
        c.setFrameInterpolation(.blend)
        XCTAssertEqual(c.frameBlend, true); XCTAssertNil(c.frameFlow)
        XCTAssertEqual(c.frameInterpolation, .blend)
        c.setFrameInterpolation(.flow)
        XCTAssertNil(c.frameBlend); XCTAssertEqual(c.frameFlow, true)
        XCTAssertEqual(c.frameInterpolation, .flow)
        c.frameBlend = true
        XCTAssertEqual(c.frameInterpolation, .flow, "両方あれば、フローが優先")
        c.setFrameInterpolation(.none)
        XCTAssertNil(c.frameBlend); XCTAssertNil(c.frameFlow)
        XCTAssertEqual(FrameInterpolation.allCases.map(\.label).count, 3)
    }

    func testFlowOnlyForSlowForwardVideoLikeBlend() {
        var c = Clip(); c.id = "v"; c.type = .video; c.src = "/tmp/none.mp4"; c.start = 0; c.duration = 2; c.speed = 0.5
        c.frameFlow = true
        XCTAssertTrue(ClipTiming.blendsFrames(c, atClipTime: 1)); XCTAssertTrue(c.opticalFlowOn)
        c.reverse = true
        XCTAssertFalse(ClipTiming.blendsFrames(c, atClipTime: 1)); XCTAssertFalse(c.opticalFlowOn)
        c.reverse = nil; c.speed = 2
        XCTAssertFalse(ClipTiming.blendsFrames(c, atClipTime: 1))
        c.speed = 0.5; c.freeze = true
        XCTAssertFalse(ClipTiming.blendsFrames(c, atClipTime: 1))
        var blend = Clip(); blend.type = .video; blend.speed = 0.5; blend.frameBlend = true
        XCTAssertTrue(blend.frameBlendOn); XCTAssertFalse(blend.opticalFlowOn, "ブレンドだけならフローは使わない")
    }

    // MARK: 描画(プレビューと同じ経路)

    func testRendererUsesOpticalFlowAndBeatsBlendOnMovingFootage() throws {
        let url = try makeMovingVideo()
        // 本物の中間のコマ: 同じ動きを 2 倍の細かさ(60fps・毎コマ 1.5 画素)で撮った動画の 5 コマ目 = 30fps の 2.5 コマ目。同じ H.264 を通すので色のずれも揃う
        let fine = try makeMovingVideo(frames: 24, perFrame: 1.5, fps: 60)
        let truth = try XCTUnwrap(RenderAssets().videoFrame(path: fine.path, time: 5.0 / 60, reverse: false, exact: true))
        let t = 5.0 / 30                                       // 出力 5/30 秒 = 速度 0.5 で素材 2.5/30 秒(2 コマ目と 3 コマ目のちょうど真ん中)
        let assetsF = RenderAssets(), assetsB = RenderAssets()
        let flow = try XCTUnwrap(Renderer(project: slowProject(url, mode: .flow), assets: assetsF).renderImage(t: t))
        let blend = try XCTUnwrap(Renderer(project: slowProject(url, mode: .blend), assets: assetsB).renderImage(t: t))
        let ef = mae(flow, truth), eb = mae(blend, truth)
        print("[OpticalFlow] renderer MAE vs real midpoint frame: flow \(String(format: "%.2f", ef)) blend \(String(format: "%.2f", eb))")
        XCTAssertLessThan(ef, eb * 0.7, "描画経路でも、動きに沿った補間のほうが本物に近い")
        XCTAssertEqual(assetsF.flowCache.computeCount, 1)
        XCTAssertEqual(assetsB.flowCache.computeCount, 0, "ブレンドではフローを求めない")
    }

    func testSameFramePairReusesTheFlowAcrossOutputFrames() throws {
        let url = try makeMovingVideo()
        let assets = RenderAssets()
        let r = Renderer(project: slowProject(url, mode: .flow), assets: assets)
        // 出力 4/30・5/30・6/30 秒(素材 2 コマ目〜3 コマ目の間 w = 0, 0.25 → 0.5 ...)。素材 2→3 コマの組は 4/30 以外の 5/30 だけ
        _ = r.renderImage(t: 4.0 / 30)       // 素材ちょうど 2 コマ目(補間なし)
        XCTAssertEqual(assets.flowCache.computeCount, 0, "w = 0 では求めない")
        _ = r.renderImage(t: 5.0 / 30)       // 2 と 3 の間
        _ = r.renderImage(t: 5.0 / 30 + 0.01)
        XCTAssertEqual(assets.flowCache.computeCount, 1, "同じ組は 1 回だけ")
        _ = r.renderImage(t: 7.0 / 30)       // 3 と 4 の間
        XCTAssertEqual(assets.flowCache.computeCount, 2)
    }

    func testFlowFallsBackToBlendWhenFlowCannotBeMade() throws {
        // フローを求められない状況(縮小できない 1 画素の画像)でも、描画は止まらずブレンドになる
        let a = scene(w: 1, h: 1, squareX: 0, size: 1), b = scene(w: 1, h: 1, squareX: 0, size: 1)
        let r = OpticalFlowInterpolator.frame(a, b, weight: 0.5, key: "tiny", cache: FlowCache())
        // 8×8 に引き伸ばしたフローが作れれば画像、作れなければ nil のどちらか。nil のときは Renderer がブレンドへ戻す
        if let r { XCTAssertEqual(r.width, 1) }
        XCTAssertNotNil(FrameBlend.mix(a, b, weight: 0.5))
    }

    // MARK: 書き出し

    func testExportedFramesMatchThePreviewPath() async throws {
        let url = try makeMovingVideo()
        var p = slowProject(url, mode: .flow)
        p.tracks[0].clips[0].duration = 0.4
        let out = tmp.appendingPathComponent("flow-export-\(UUID().uuidString).mp4")
        try await Exporter(project: p, assets: RenderAssets()).export(to: out)
        let asset = AVURLAsset(url: out)
        let track = try XCTUnwrap(asset.tracks(withMediaType: .video).first)
        let rd = try AVAssetReader(asset: asset)
        let o = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        rd.add(o); XCTAssertTrue(rd.startReading())
        var frames: [CGImage] = []
        while let sb = o.copyNextSampleBuffer(), let pb = CMSampleBufferGetImageBuffer(sb) {
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb), bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)!
            if let img = ctx.makeImage() { frames.append(img) }
            CVPixelBufferUnlockBaseAddress(pb, .readOnly)
        }
        XCTAssertGreaterThanOrEqual(frames.count, 12, "0.4 秒 × 30fps")
        let r = Renderer(project: p, assets: RenderAssets())
        // 補間コマ(奇数コマ)を、描画経路の同じ時刻と比べる(H.264 の圧縮ぶんの差だけ)
        for i in [1, 3, 5] {
            let preview = try XCTUnwrap(r.renderImage(t: Double(i) / 30))
            XCTAssertLessThan(mae(frames[i], preview), 4.0, "コマ \(i)")
        }
    }
}

