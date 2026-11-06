import XCTest
import CoreGraphics
@testable import MovieCutCore

/// 白い部分の重心の x・y(左上原点)。白は R > 128 の画素。
func centroidOf(_ img: CGImage) -> (x: Double, y: Double)? {
    let w = img.width, h = img.height
    var d = [UInt8](repeating: 0, count: w * h * 4)
    guard let c = CGContext(data: &d, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    c.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    var sx = 0.0, sy = 0.0, n = 0.0
    for y in 0..<h { for x in 0..<w where d[(y * w + x) * 4] > 128 { sx += Double(x); sy += Double(y); n += 1 } }
    guard n > 0 else { return nil }
    return (sx / n, sy / n)
}

/// 偽の推定器: 白い重心の差をそのまま「中身の動き」として返す(本物の Vision の代わり)。
struct CentroidEstimator: MotionEstimating {
    func displacement(from prev: CGImage, to next: CGImage) -> CGVector? {
        guard let a = centroidOf(prev), let b = centroidOf(next) else { return nil }
        return CGVector(dx: b.x - a.x, dy: b.y - a.y)
    }
}

/// 手ぶれ補正: 平滑化(純粋な関数)、補正の平行移動(画素で確認)、解析(偽の推定器で軌跡を与える)、キャッシュ、
/// 本物の Vision 推定器の符号、ファイルの書き方。解析の中身は合成画像で確かめる(実際の手ぶれ映像はこの環境で試していない)。
final class StabilizerTests: XCTestCase {

    // MARK: 合成画像

    /// 黒地に白い四角(x0..x0+size, y0..y0+size)。
    func square(x0: Int, y0: Int, size: Int = 24, w: Int = 320, h: Int = 120) -> CGImage {
        let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        c.fill(CGRect(x: 0, y: 0, width: w, height: h))
        c.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        // CG は左下原点。x0,y0 は左上原点の左上座標なので、y は反転する
        c.fill(CGRect(x: x0, y: h - y0 - size, width: size, height: size))
        return c.makeImage()!
    }

    /// 一様な乱数の模様(ブロックごとの灰色)。Vision が特徴点を拾える絵。種は固定。
    func noiseImage(w: Int, h: Int, seed: UInt64) -> CGImage {
        var state = seed
        let block = 8
        let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        var by = 0
        while by < h {
            var bx = 0
            while bx < w {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                let v = CGFloat((state >> 33) & 0xff) / 255
                c.setFillColor(CGColor(srgbRed: v, green: v * 0.8, blue: 1 - v, alpha: 1))
                c.fill(CGRect(x: bx, y: by, width: block, height: block))
                bx += block
            }
            by += block
        }
        return c.makeImage()!
    }

    /// 同じ絵を (dx, dy) だけ動かす(左上原点・下向き正)。はみ出した所は黒。
    func shifted(_ img: CGImage, dx: Int, dy: Int) -> CGImage {
        let w = img.width, h = img.height
        let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        c.fill(CGRect(x: 0, y: 0, width: w, height: h))
        c.draw(img, in: CGRect(x: dx, y: -dy, width: w, height: h))
        return c.makeImage()!
    }

    func variance(_ xs: [Double]) -> Double {
        let m = xs.reduce(0, +) / Double(xs.count)
        return xs.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(xs.count)
    }

    // MARK: 平滑化

    /// 揺れ(高い周波数)を載せた軌跡は、移動平均で分散が小さくなる。
    func testSmoothingReducesJitterVariance() {
        let pan = (0..<200).map { 0.3 * Double($0) }                  // ゆっくりした pan
        let jitter = (0..<200).map { pan[$0] + ($0 % 2 == 0 ? 6.0 : -6.0) }
        let s = MotionSmoothing.smooth(jitter, radius: 4)
        // 揺れを除いた残り(軌跡 − 平滑化)の分散は、揺れそのものより小さいはず
        let rawResidual = zip(jitter, pan).map { $0 - $1 }
        let smoothResidual = zip(s, pan).map { $0 - $1 }
        XCTAssertLessThan(variance(smoothResidual.dropFirst(10).dropLast(10).map { $0 }), variance(rawResidual.dropFirst(10).dropLast(10).map { $0 }) * 0.1)
    }

    /// 直線の pan は、内側では平滑化しても変わらない(ゆっくりした動きは残す)。
    func testSmoothingKeepsLinearRamp() {
        let ramp = (0..<100).map { 2.0 * Double($0) }
        let s = MotionSmoothing.smooth(ramp, radius: 5)
        for i in 5..<95 { XCTAssertEqual(s[i], ramp[i], accuracy: 1e-9) }
        XCTAssertEqual(MotionSmoothing.smooth(ramp, radius: 0), ramp)
    }

    // MARK: 補正の平行移動(画素)

    /// 右へ 20 px ずれた四角を、補正 (−20, 0) で元の位置へ戻す(拡大 1 のとき)。
    func testWarpMovesSquareBackToPlace() throws {
        let img = square(x0: 120, y0: 40)
        let out = try XCTUnwrap(Stabilizer.warp(img, dx: -20, dy: 0, zoom: 1))
        let c = try XCTUnwrap(centroidOf(out))
        XCTAssertEqual(c.x, 132 - 20, accuracy: 1.0)   // 四角の中心は x0 + 12 = 132 → 112
        XCTAssertEqual(c.y, 52, accuracy: 1.0)
    }

    /// 下向き正の dy: 補正 dy = −10 は、四角を上へ 10 px 動かす(画面の上が 0)。
    func testWarpVerticalSignIsDownward() throws {
        let img = square(x0: 100, y0: 40)
        let out = try XCTUnwrap(Stabilizer.warp(img, dx: 0, dy: -10, zoom: 1))
        let c = try XCTUnwrap(centroidOf(out))
        XCTAssertEqual(c.y, 52 - 10, accuracy: 1.0)
    }

    // MARK: 解析(偽の推定器)

    /// 交互に ±8 px 揺れるカメラ: 補正後の四角の位置は、ほぼ一定になる(揺れが消える)。
    func testAnalysisRemovesAlternatingJitter() throws {
        let n = 60
        let jitter = (0..<n).map { $0 % 2 == 0 ? 8.0 : -8.0 }
        func frame(_ k: Int) -> CGImage { square(x0: 100 + Int(jitter[k]), y0: 48) }
        let duration = Double(n) / Stabilizer.sampleRate
        let st = try XCTUnwrap(Stabilizer.analyze(duration: duration, strength: 1, frame: { r in
            frame(min(n - 1, Int((r * Stabilizer.sampleRate).rounded())))
        }, estimator: CentroidEstimator()))
        var raw: [Double] = [], corrected: [Double] = []
        for k in 5..<(n - 5) {
            let r = Double(k) / Stabilizer.sampleRate
            let c = st.correction(atClipTime: r)
            let out = try XCTUnwrap(Stabilizer.warp(frame(k), dx: c.dx, dy: c.dy, zoom: st.zoom))
            raw.append(try XCTUnwrap(centroidOf(frame(k))).x)
            corrected.append(try XCTUnwrap(centroidOf(out)).x)
        }
        XCTAssertLessThan(variance(corrected), variance(raw) * 0.05, "補正後の分散が 5% 未満になる")
        XCTAssertGreaterThan(st.zoom, 1, "縁を隠すための拡大が入る")
    }

    /// 静止したカメラの中で 1 コマだけ 20 px 右へずれた四角は、補正で周りの位置へ戻る(再センター)。
    func testSingleShiftedFrameIsRecentred() throws {
        let n = 40, spike = 20
        func frame(_ k: Int) -> CGImage { square(x0: k == spike ? 120 : 100, y0: 48) }
        let st = try XCTUnwrap(Stabilizer.analyze(duration: Double(n) / Stabilizer.sampleRate, strength: 1, frame: { r in
            frame(min(n - 1, Int((r * Stabilizer.sampleRate).rounded())))
        }, estimator: CentroidEstimator()))
        let rSpike = Double(spike) / Stabilizer.sampleRate
        let c = st.correction(atClipTime: rSpike)
        let fixed = try XCTUnwrap(Stabilizer.warp(frame(spike), dx: c.dx, dy: c.dy, zoom: st.zoom))
        let neighbour = try XCTUnwrap(Stabilizer.warp(frame(spike - 5), dx: st.correction(atClipTime: Double(spike - 5) / Stabilizer.sampleRate).dx,
                                                      dy: st.correction(atClipTime: Double(spike - 5) / Stabilizer.sampleRate).dy, zoom: st.zoom))
        let before = try XCTUnwrap(centroidOf(frame(spike))).x
        let after = try XCTUnwrap(centroidOf(fixed)).x
        let ref = try XCTUnwrap(centroidOf(neighbour)).x
        XCTAssertEqual(before - (try XCTUnwrap(centroidOf(frame(spike - 5))).x), 20, accuracy: 1.5, "補正前は周りより 20 px ずれている")
        XCTAssertEqual(after, ref, accuracy: 2.0, "補正後は周りの位置へ戻る(2 px 以内)")
    }

    /// 強さ 0 の補正量はすべて 0(拡大も 1)。
    func testZeroStrengthDoesNothing() throws {
        let n = 30
        let st = try XCTUnwrap(Stabilizer.analyze(duration: 1, strength: 0, frame: { r in
            self.square(x0: 100 + Int(r * 10) % 2 * 8, y0: 48)
        }, estimator: CentroidEstimator()))
        XCTAssertEqual(st.zoom, 1)
        XCTAssertTrue(st.dx.allSatisfy { $0 == 0 } && st.dy.allSatisfy { $0 == 0 }, "\(n)")
    }

    /// コマが 1 枚も取れなければ解析しない。
    func testNoFramesGivesNil() {
        XCTAssertNil(Stabilizer.analyze(duration: 1, strength: 1, frame: { _ in nil }, estimator: CentroidEstimator()))
    }

    // MARK: 本物の推定器(Vision)

    /// 絵を (+8, +4) 動かすと、推定はおよそ (+8, +4)(左上原点・下向き正)。符号を確かめる。
    func testVisionEstimatorReportsContentDisplacement() throws {
        let a = noiseImage(w: 240, h: 160, seed: 7)
        let b = shifted(a, dx: 8, dy: 4)
        let d = try XCTUnwrap(VisionMotionEstimator().displacement(from: a, to: b))
        XCTAssertEqual(d.dx, 8, accuracy: 1.5)
        XCTAssertEqual(d.dy, 4, accuracy: 1.5)
    }

    /// 1920×1080 の 2 コマの推定にかかる時間(縮小 480 px を含む)。数字は報告用。
    func testVisionEstimatorTiming() throws {
        let a = noiseImage(w: 1920, h: 1080, seed: 3)
        let b = shifted(a, dx: 12, dy: -6)
        let est = VisionMotionEstimator()
        _ = est.displacement(from: a, to: b)            // 初回の読み込みを除く
        let runs = 10
        let t0 = CFAbsoluteTimeGetCurrent()
        var last: CGVector?
        for _ in 0..<runs { last = est.displacement(from: a, to: b) }
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000 / Double(runs)
        print("[StabilizerTests] Vision 推定 1920x1080 の 1 組: \(String(format: "%.2f", ms)) ms(平均 \(runs) 回), 結果 \(String(describing: last))")
        XCTAssertNotNil(last)
        // 補正の描き直し(1920x1080 の 1 コマ)の時間
        let t1 = CFAbsoluteTimeGetCurrent()
        for _ in 0..<runs { _ = Stabilizer.warp(a, dx: 3.5, dy: -2, zoom: 1.05) }
        let wms = (CFAbsoluteTimeGetCurrent() - t1) * 1000 / Double(runs)
        print("[StabilizerTests] 補正の描き直し 1920x1080 の 1 コマ: \(String(format: "%.2f", wms)) ms(平均 \(runs) 回)")
    }

    // MARK: キャッシュ

    func testCacheBuildsOncePerKey() {
        let cache = StabilizationCache()
        var builds = 0
        let make = { () -> Stabilization? in
            builds += 1
            return Stabilization(step: 1 / 30, dx: [0], dy: [0], zoom: 1)
        }
        _ = cache.value(key: "a", build: make)
        _ = cache.value(key: "a", build: make)
        _ = cache.value(key: "b", build: make)
        XCTAssertEqual(builds, 2)
        XCTAssertEqual(cache.count, 2)
    }

    // MARK: ファイルと編集

    func testClipStabilizeIsOnlyWrittenWhenOn() throws {
        var c = Clip(); c.type = .video; c.src = "/tmp/x.mov"
        let off = String(data: try JSONEncoder().encode(c), encoding: .utf8)!
        XCTAssertFalse(off.contains("stabilize"), "既定(オフ)は書かない")

        XCTAssertTrue(StabilizeEditing.toggle(&c))
        XCTAssertEqual(c.stabilizeStrength, StabilizeEditing.defaultStrength)
        let on = try JSONEncoder().encode(c)
        XCTAssertTrue(String(data: on, encoding: .utf8)!.contains("\"stabilize\":0.8"))
        let back = try JSONDecoder().decode(Clip.self, from: on)
        XCTAssertEqual(back.stabilize, 0.8)

        XCTAssertTrue(StabilizeEditing.toggle(&c))
        XCTAssertNil(c.stabilize, "オフに戻すとキーごと消える")
    }

    func testStabilizeSupportsVideoOnly() {
        var v = Clip(); v.type = .video; v.src = "/tmp/x.mov"
        var i = Clip(); i.type = .image; i.src = "/tmp/x.png"
        XCTAssertTrue(StabilizeEditing.supports(v))
        XCTAssertFalse(StabilizeEditing.supports(i))
        var probe = i
        _ = probe
    }

    func testOutOfRangeStabilizeIsClampedOnRead() throws {
        let c = try JSONDecoder().decode(Clip.self, from: Data(#"{"type":"video","src":"/a.mov","stabilize":3}"#.utf8))
        XCTAssertEqual(c.stabilizeStrength, 1)
        let zero = try JSONDecoder().decode(Clip.self, from: Data(#"{"type":"video","src":"/a.mov","stabilize":0}"#.utf8))
        XCTAssertNil(zero.stabilize)
    }

    /// 強さの設定: 0〜1 に丸める。0 は「オフ」(キーごと消える = ファイルに書かない)。
    func testSetStrengthClampsAndZeroIsOff() {
        var c = Clip(); c.type = .video; c.src = "/tmp/x.mov"
        XCTAssertTrue(StabilizeEditing.setStrength(&c, 0.5))
        XCTAssertEqual(c.stabilizeStrength, 0.5)
        XCTAssertFalse(StabilizeEditing.setStrength(&c, 0.5), "同じ値なら変わらない")
        XCTAssertTrue(StabilizeEditing.setStrength(&c, 7))
        XCTAssertEqual(c.stabilizeStrength, 1)
        XCTAssertTrue(StabilizeEditing.setStrength(&c, -2) == true)
        XCTAssertNil(c.stabilize, "0 以下はオフ")
        XCTAssertFalse(StabilizeEditing.setStrength(&c, .nan), "NaN はオフ扱いで、もともとオフなら変わらない")
    }

    /// プレビュー用の遅延解析: 解析が無ければ nil を返して背景で作り、終わったら onReady が呼ばれて値が取れる。
    /// 解析できなかった鍵は、描くたびに解析し直さない。
    func testLazyValueReturnsNilThenCachedAfterReady() throws {
        let cache = StabilizationCache()
        let ready = expectation(description: "onReady")
        var builds = 0
        let make = { () -> Stabilization? in builds += 1; return Stabilization(step: 1 / 30, dx: [0], dy: [0], zoom: 1) }
        XCTAssertNil(cache.lazyValue(key: "k", build: make, onReady: { ready.fulfill() }))
        wait(for: [ready], timeout: 5)
        XCTAssertEqual(cache.lazyValue(key: "k", build: make, onReady: nil)?.zoom, 1)
        XCTAssertEqual(builds, 1, "同じ鍵は一度だけ解析する")
    }

    func testLazyValueDoesNotRetryFailedAnalysis() throws {
        let cache = StabilizationCache()
        let done = expectation(description: "failed build finished")
        var builds = 0
        let fail = { () -> Stabilization? in builds += 1; return nil }
        XCTAssertNil(cache.lazyValue(key: "bad", build: fail, onReady: { done.fulfill() }))
        wait(for: [done], timeout: 5)
        XCTAssertNil(cache.lazyValue(key: "bad", build: fail, onReady: nil))
        XCTAssertNil(cache.lazyValue(key: "bad", build: fail, onReady: nil))
        XCTAssertEqual(builds, 1)
    }
}

/// 相似変換(回転・ズーム)の手ぶれ補正: 合成の回転・拡大フレーム列で、Vision の推定が角度 0.5°・拡大 1% 以内で合うかを確かめる。
final class StabilizerSimilarityTests: XCTestCase {
    let base = StabilizerTests()

    /// 絵を中心まわりに、見た目の時計回りに `deg` 度、`scale` 倍して、(dx, dy) 動かす(左上原点・下向き正)。はみ出しは黒。
    func transformed(_ img: CGImage, deg: Double, scale: Double, dx: Double = 0, dy: Double = 0) -> CGImage {
        let w = img.width, h = img.height
        let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        c.fill(CGRect(x: 0, y: 0, width: w, height: h))
        c.translateBy(x: Double(w) / 2 + dx, y: Double(h) / 2 - dy)
        c.rotate(by: -deg * .pi / 180)
        c.scaleBy(x: scale, y: scale)
        c.draw(img, in: CGRect(x: -Double(w) / 2, y: -Double(h) / 2, width: Double(w), height: Double(h)))
        return c.makeImage()!
    }

    func testFitRecoversKnownSimilarity() throws {
        let truth = SimilarityMotion(angle: 0.1, scale: 1.05, dx: 3, dy: -2)
        let pts = [CGPoint(x: -50, y: -30), CGPoint(x: 60, y: -20), CGPoint(x: 10, y: 40), CGPoint(x: -20, y: 25)]
        let q = pts.map { p in
            CGPoint(x: truth.scale * (cos(truth.angle) * p.x - sin(truth.angle) * p.y) + truth.dx,
                    y: truth.scale * (sin(truth.angle) * p.x + cos(truth.angle) * p.y) + truth.dy)
        }
        let f = try XCTUnwrap(SimilarityMotion.fit(from: pts, to: q))
        XCTAssertEqual(f.angle, 0.1, accuracy: 1e-9); XCTAssertEqual(f.scale, 1.05, accuracy: 1e-9)
        XCTAssertEqual(f.dx, 3, accuracy: 1e-9); XCTAssertEqual(f.dy, -2, accuracy: 1e-9)
        let inv = f.inverse
        XCTAssertEqual(inv.angle, -0.1, accuracy: 1e-9); XCTAssertEqual(inv.scale, 1 / 1.05, accuracy: 1e-9)
        XCTAssertNil(SimilarityMotion.fit(from: [CGPoint(x: 1, y: 1)], to: [CGPoint(x: 1, y: 1)]))
    }

    /// 回転だけ・拡大だけ・両方(と少しの平行移動): 推定の角度は 0.5° 以内、拡大は 1% 以内。符号は「見た目の時計回りが正」。
    func testVisionRecoversRotationAndScale() throws {
        let a = base.noiseImage(w: 480, h: 320, seed: 11)
        for (deg, sc) in [(2.0, 1.0), (-1.5, 1.0), (0.0, 1.03), (0.0, 0.97), (2.0, 1.04), (-3.0, 0.98)] {
            let b = transformed(a, deg: deg, scale: sc)
            let m = try XCTUnwrap(VisionMotionEstimator().similarity(from: a, to: b), "\(deg) \(sc)")
            XCTAssertEqual(m.angle * 180 / .pi, deg, accuracy: 0.5, "角度 \(deg) \(sc)")
            XCTAssertEqual(m.scale, sc, accuracy: 0.01, "拡大 \(deg) \(sc)")
        }
        let b = transformed(a, deg: 1.0, scale: 1.0, dx: 8, dy: -5)
        let m = try XCTUnwrap(VisionMotionEstimator().similarity(from: a, to: b))
        XCTAssertEqual(m.dx, 8, accuracy: 2.0); XCTAssertEqual(m.dy, -5, accuracy: 2.0)
    }

    /// 揺れる回転・ズームの列を解析して補正すると、補正後の推定(基準フレームとの角度・拡大)の分散が大きく減る。
    func testAnalysisRemovesRotationAndZoomJitter() throws {
        let n = 24
        let a = base.noiseImage(w: 360, h: 240, seed: 5)
        let degs = (0..<n).map { $0 % 2 == 0 ? 2.0 : -2.0 }
        let scs = (0..<n).map { $0 % 2 == 0 ? 1.03 : 0.97 }
        let frames = (0..<n).map { transformed(a, deg: degs[$0], scale: scs[$0]) }
        let st = try XCTUnwrap(Stabilizer.analyze(duration: Double(n - 1) / Stabilizer.sampleRate, strength: 1, frame: { r in
            frames[min(n - 1, Int((r * Stabilizer.sampleRate).rounded()))]
        }, estimator: VisionMotionEstimator(), rotationZoom: true))
        XCTAssertFalse(st.rot.isEmpty)
        XCTAssertGreaterThan(st.zoom, 1, "縁を隠す拡大")
        var rawA: [Double] = [], fixA: [Double] = [], rawS: [Double] = [], fixS: [Double] = []
        for k in 4..<(n - 4) {
            let c = st.similarityCorrection(atClipTime: Double(k) / Stabilizer.sampleRate)
            let out = try XCTUnwrap(Stabilizer.warp(frames[k], dx: c.dx, dy: c.dy, zoom: 1, angle: c.angle, scale: c.scale))
            rawA.append(degs[k]); rawS.append(scs[k])
            let m = try XCTUnwrap(VisionMotionEstimator().similarity(from: a, to: out))
            fixA.append(m.angle * 180 / .pi); fixS.append(m.scale)
        }
        XCTAssertLessThan(base.variance(fixA), base.variance(rawA) * 0.25)
        XCTAssertLessThan(base.variance(fixS), base.variance(rawS) * 0.25)
    }

    func testRequiredZoomCoversBordersAndMatchesTranslationOnly() {
        // 平行移動だけなら従来の 1 / (1 − 2m)
        let z0 = Stabilizer.requiredZoom(width: 400, height: 200, dx: [20], dy: [0], angle: [0], logScale: [0])
        XCTAssertEqual(z0, 1 / (1 - 2 * 20 / 400.0), accuracy: 1e-9)
        // 回転があれば大きくなる
        let z1 = Stabilizer.requiredZoom(width: 400, height: 200, dx: [0], dy: [0], angle: [3 * .pi / 180], logScale: [0])
        XCTAssertGreaterThan(z1, 1.0)
        // 補正なしは 1
        XCTAssertEqual(Stabilizer.requiredZoom(width: 400, height: 200, dx: [0], dy: [0], angle: [0], logScale: [0]), 1, accuracy: 1e-12)
    }

    /// ファイル: 傾き補正は true のときだけ書く。旧ファイル(キー無し)は変わらない。補正オフで指定も消える。
    func testRollFlagIsOnlyWrittenWhenOn() throws {
        var c = Clip(); c.type = .video; c.duration = 3
        c.src = "/a.mp4"
        XCTAssertFalse(StabilizeEditing.setRotationZoom(&c, true), "補正オフのときは何もしない")
        StabilizeEditing.setStrength(&c, 0.8)
        let off = String(data: try JSONEncoder().encode(c), encoding: .utf8)!
        XCTAssertFalse(off.contains("stabilizeRoll"))
        XCTAssertTrue(StabilizeEditing.setRotationZoom(&c, true))
        let on = try JSONEncoder().encode(c)
        XCTAssertTrue(String(data: on, encoding: .utf8)!.contains("\"stabilizeRoll\":true"))
        let back = try JSONDecoder().decode(Clip.self, from: on)
        XCTAssertEqual(back.stabilizeRoll, true)
        XCTAssertNotEqual(c.stabilizeCacheKey(src: "/a.mp4"), { var d = c; d.stabilizeRoll = nil; return d.stabilizeCacheKey(src: "/a.mp4") }())
        StabilizeEditing.setStrength(&c, 0)
        XCTAssertNil(c.stabilizeRoll)
    }
}
