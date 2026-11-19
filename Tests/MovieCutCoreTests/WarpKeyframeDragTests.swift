import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import MovieCutCore

/// メッシュ/パペット変形 R2-5: キーフレーム(補間・イージング・保存・分割・キー管理)と
/// プレビュードラッグ相当のモデル操作(WarpDrag / WarpEditing のキー対応書き込み)、identity 不変。
final class WarpKeyframeDragTests: XCTestCase {

    private func imageClip(duration: Double = 4) -> Clip {
        var c = Clip()
        c.id = "c"; c.type = .image; c.start = 0; c.duration = duration
        return c
    }

    private func meshedClip() -> Clip {
        var c = imageClip()
        c.meshWarp = MeshWarp(cols: 3, rows: 3)
        return c
    }

    // MARK: 項目名

    func testWarpKeyMakeParseRoundTrip() {
        XCTAssertEqual(WarpKey.mesh(4, .x), "mesh.4.x")
        XCTAssertEqual(WarpKey.pin(0, .y), "pin.0.y")
        XCTAssertEqual(WarpKey.parse("mesh.4.x")?.kind, .mesh(4))
        XCTAssertEqual(WarpKey.parse("mesh.4.x")?.axis, .x)
        XCTAssertEqual(WarpKey.parse("pin.31.y")?.kind, .pin(31))
        XCTAssertNil(WarpKey.parse("x"))
        XCTAssertNil(WarpKey.parse("fx.0.amount"))
        XCTAssertNil(WarpKey.parse("mesh.-1.x"))
        XCTAssertNil(WarpKey.parse("mesh.1.z"))
        XCTAssertNil(WarpKey.parse("mesh.1"))
        XCTAssertTrue(WarpKey.isWarpKey("pin.2.x"))
        XCTAssertFalse(WarpKey.isWarpKey("scale"))
    }

    func testAnimationKeysIncludeWarpOnlyWhenWarpPresent() {
        let plain = imageClip()
        XCTAssertFalse(Animation.keys(for: plain).contains { WarpKey.isWarpKey($0) }, "変形なしでは従来の一覧のまま")
        var c = meshedClip()
        let ks = Animation.keys(for: c)
        XCTAssertTrue(ks.contains("mesh.0.x")); XCTAssertTrue(ks.contains("mesh.8.y"))
        XCTAssertEqual(ks.filter { WarpKey.isWarpKey($0) }.count, 18)
        _ = WarpEditing.addPin(&c, hx: 0.5, hy: 0.5)
        XCTAssertTrue(Animation.keys(for: c).contains("pin.0.x"))
        // 動画でも音量が最後のまま(既存テストの前提を壊さない)
        var v = imageClip(); v.type = .video; v.meshWarp = MeshWarp()
        XCTAssertEqual(Animation.keys(for: v).last, "volume")
        XCTAssertTrue(Animation.keys(for: v).contains("mesh.4.y"))
        // 範囲と名前
        XCTAssertEqual(Animation.range(of: "mesh.4.x", type: .image), MeshWarp.positionRange)
        XCTAssertEqual(Animation.clamp("pin.0.y", 99, type: .image), MeshWarp.positionRange.upperBound)
        XCTAssertTrue(Animation.label(of: "mesh.4.x").contains("メッシュ点5"))
        XCTAssertTrue(Animation.label(of: "pin.0.y").contains("ピン1"))
    }

    // MARK: 補間とイージング

    func testMeshKeyframeInterpolation() {
        var c = meshedClip()
        c.keyframes["mesh.4.x"] = [Keyframe(t: 0, v: 0.5), Keyframe(t: 2, v: 0.9)]
        XCTAssertEqual(c.meshWarp(at: 1)?.points[4].x ?? -1, 0.7, accuracy: 1e-9, "線形補間で中点")
        XCTAssertEqual(c.meshWarp(at: 0)?.points[4].x ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertEqual(c.meshWarp(at: 3)?.points[4].x ?? -1, 0.9, accuracy: 1e-9, "最後のキーの後は端の値")
        XCTAssertEqual(c.meshWarp(at: 1)?.points[4].y ?? -1, 0.5, accuracy: 1e-9, "キーが無い座標は静的な値")
        XCTAssertEqual(c.meshWarp?.points[4].x ?? -1, 0.5, accuracy: 1e-9, "静的な値は変わらない")
        XCTAssertFalse(c.hasActiveWarp(at: 0), "キーの値が元の位置の時刻は identity")
        XCTAssertTrue(c.hasActiveWarp(at: 1))
        // 変位場にも補間が届く
        XCTAssertEqual(c.warpDisplacement(u: 0.5, v: 0.5, at: 1).x, 0.2, accuracy: 1e-9)
        XCTAssertEqual(c.warpDisplacement(u: 0.5, v: 0.5, at: 0).x, 0, accuracy: 1e-9)
    }

    func testMeshKeyframeEasingHoldAndEaseInOut() {
        var c = meshedClip()
        c.keyframes["mesh.4.x"] = [Keyframe(t: 0, v: 0.5, ease: .hold), Keyframe(t: 2, v: 0.9)]
        XCTAssertEqual(c.meshWarp(at: 1)?.points[4].x ?? -1, 0.5, accuracy: 1e-9, "hold は次のキーまで値を保つ")
        XCTAssertEqual(c.meshWarp(at: 2)?.points[4].x ?? -1, 0.9, accuracy: 1e-9)
        c.keyframes["mesh.4.x"] = [Keyframe(t: 0, v: 0.5, ease: .easeInOut), Keyframe(t: 2, v: 0.9)]
        XCTAssertEqual(c.meshWarp(at: 1)?.points[4].x ?? -1, 0.7, accuracy: 1e-9, "easeInOut の中点は 0.5")
        let early = c.meshWarp(at: 0.5)?.points[4].x ?? -1
        XCTAssertGreaterThan(early, 0.5); XCTAssertLessThan(early, 0.6, "easeInOut は始まりが緩やか")
    }

    func testPuppetPinKeyframeInterpolation() {
        var c = imageClip()
        c.puppetWarp = PuppetWarp(pins: [PuppetPin(hx: 0.5, hy: 0.5)], radius: 0.6)
        c.keyframes["pin.0.y"] = [Keyframe(t: 0, v: 0.5), Keyframe(t: 2, v: 0.9)]
        let mid = c.puppetWarp(at: 1)
        XCTAssertEqual(mid?.pins[0].y ?? -1, 0.7, accuracy: 1e-9)
        XCTAssertEqual(mid?.displacement(u: 0.5, v: 0.5).y ?? -1, 0.2, accuracy: 1e-9, "ピンの元の位置では補間後の変位")
        XCTAssertFalse(c.hasActiveWarp(at: 0))
        XCTAssertTrue(c.hasActiveWarp(at: 1))
        // 固定ピンはキーに関係なく動かない
        var f = imageClip()
        f.puppetWarp = PuppetWarp(pins: [PuppetPin(hx: 0.5, hy: 0.5, fixed: true)])
        f.keyframes["pin.0.x"] = [Keyframe(t: 0, v: 0.1), Keyframe(t: 2, v: 0.9)]
        XCTAssertEqual(f.puppetWarp(at: 1)?.pins[0].x ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertFalse(f.hasActiveWarp(at: 1))
    }

    // MARK: キーが無い・identity の不変

    func testNoKeyframesResolvedEqualsStatic() {
        var c = meshedClip()
        c.meshWarp?.points[4] = WarpPoint(x: 0.8, y: 0.4)
        _ = WarpEditing.addPin(&c, hx: 0.3, hy: 0.3)
        _ = WarpEditing.movePin(&c, index: 0, x: 0.3, y: 0.6)
        for t in [0.0, 1.0, 3.9] {
            XCTAssertEqual(c.warpResolved(at: t), c, "キーが無ければ複製は自分自身")
            XCTAssertEqual(c.meshWarp(at: t), c.meshWarp)
            XCTAssertEqual(c.puppetWarp(at: t), c.puppetWarp)
            XCTAssertEqual(c.hasActiveWarp(at: t), c.hasActiveWarp)
            XCTAssertEqual(c.warpMaxDisplacement(at: t), c.warpMaxDisplacement)
        }
        // キーがあっても全て元の位置なら、その時刻は描画スキップ(identity)のまま
        var idc = meshedClip()
        idc.keyframes["mesh.4.x"] = [Keyframe(t: 0, v: 0.5), Keyframe(t: 2, v: 0.5)]
        XCTAssertFalse(idc.hasActiveWarp(at: 1))
        let ctx = CGContext(data: nil, width: 20, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let img = ctx.makeImage()!
        XCTAssertNil(WarpRenderer.warp(img, clip: idc.warpResolved(at: 1), bounds: CGRect(x: 0, y: 0, width: 20, height: 20)),
                     "identity に評価される時刻は WarpRenderer が nil(従来経路)")
    }

    // MARK: 保存往復

    func testWarpKeyframeRoundTrip() throws {
        var c = meshedClip()
        c.keyframes["mesh.4.x"] = [Keyframe(t: 0, v: 0.5, ease: .easeInOut), Keyframe(t: 2, v: 0.9)]
        c.keyframes["pin.0.y"] = []
        _ = WarpEditing.addPin(&c, hx: 0.25, hy: 0.75)
        c.keyframes["pin.0.y"] = [Keyframe(t: 1, v: 0.8)]
        let data = try JSONEncoder().encode(c)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertTrue(json.contains("mesh.4.x"), "変形キーは既存の keyframes に載る")
        let back = try JSONDecoder().decode(Clip.self, from: data)
        XCTAssertEqual(back, c)
        XCTAssertEqual(back.keyframes["mesh.4.x"]?.count, 2)
        // キーが無い変形クリップは keyframes を書かない(従来と同一)
        let plain = meshedClip()
        let j2 = String(data: try JSONEncoder().encode(plain), encoding: .utf8)!
        XCTAssertFalse(j2.contains("keyframes"))
        XCTAssertTrue(j2.contains("meshWarp"))
    }

    // MARK: キーの付け外し・書き込み

    func testToggleWarpKeyframeBakesStaticOnLastRemoval() {
        var c = meshedClip()
        let tol = KeyframeEditing.tolerance(fps: 30)
        XCTAssertTrue(KeyframeEditing.toggle(&c, key: "mesh.4.x", at: 1, tolerance: tol))
        XCTAssertEqual(c.keyframes["mesh.4.x"]?.count, 1)
        XCTAssertEqual(c.keyframes["mesh.4.x"]?.first?.v ?? -1, 0.5, accuracy: 1e-9, "いまの値でキーを足す")
        KeyframeEditing.setValue(&c, key: "mesh.4.x", 0.9, at: 1, tolerance: tol)
        XCTAssertEqual(c.meshWarp(at: 1)?.points[4].x ?? -1, 0.9, accuracy: 1e-9)
        XCTAssertEqual(c.meshWarp?.points[4].x ?? -1, 0.5, accuracy: 1e-9, "静的な値はまだ元の位置")
        XCTAssertTrue(KeyframeEditing.toggle(&c, key: "mesh.4.x", at: 1, tolerance: tol))
        XCTAssertNil(c.keyframes["mesh.4.x"], "最後のキーを消すと項目は消える")
        XCTAssertEqual(c.meshWarp?.points[4].x ?? -1, 0.9, accuracy: 1e-9, "消したキーの値が静的な値へ焼き込まれる")
    }

    func testKeyedSettersRoutePerAxis() {
        var c = meshedClip()
        let tol = KeyframeEditing.tolerance(fps: 30)
        // キーが無ければ静的な値を書く(従来どおり)
        XCTAssertTrue(WarpEditing.setMeshPointKeyed(&c, index: 4, x: 0.7, y: 0.6, at: 1, tolerance: tol))
        XCTAssertEqual(c.meshWarp?.points[4].x ?? -1, 0.7, accuracy: 1e-9)
        XCTAssertTrue(c.keyframes.isEmpty)
        // x だけキーを付けると、x はキーへ・y は静的な値へ
        c.keyframes["mesh.4.x"] = [Keyframe(t: 0, v: 0.7), Keyframe(t: 3, v: 0.7)]
        XCTAssertTrue(WarpEditing.setMeshPointKeyed(&c, index: 4, x: 0.9, y: 0.4, at: 1, tolerance: tol))
        XCTAssertEqual(c.meshWarp?.points[4].x ?? -1, 0.7, accuracy: 1e-9, "キーがある座標は静的な値を動かさない")
        XCTAssertEqual(c.meshWarp(at: 1)?.points[4].x ?? -1, 0.9, accuracy: 1e-9, "再生ヘッドにキーが足される")
        XCTAssertEqual(c.meshWarp?.points[4].y ?? -1, 0.4, accuracy: 1e-9)
        // ピンも同じ
        var p = imageClip()
        _ = WarpEditing.addPin(&p, hx: 0.5, hy: 0.5)
        p.keyframes["pin.0.y"] = [Keyframe(t: 0, v: 0.5), Keyframe(t: 3, v: 0.5)]
        XCTAssertTrue(WarpEditing.movePinKeyed(&p, index: 0, x: 0.6, y: 0.9, at: 1, tolerance: tol))
        XCTAssertEqual(p.puppetWarp?.pins[0].x ?? -1, 0.6, accuracy: 1e-9)
        XCTAssertEqual(p.puppetWarp?.pins[0].y ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertEqual(p.puppetWarp(at: 1)?.pins[0].y ?? -1, 0.9, accuracy: 1e-9)
    }

    func testStaticValueAccessorsForWarpKeys() {
        var c = meshedClip()
        c.meshWarp?.points[4] = WarpPoint(x: 0.8, y: 0.4)
        XCTAssertEqual(c.staticValue(of: "mesh.4.x"), 0.8)
        XCTAssertEqual(c.staticValue(of: "mesh.4.y"), 0.4)
        c.setStaticValue(0.2, of: "mesh.4.y")
        XCTAssertEqual(c.meshWarp?.points[4].y ?? -1, 0.2, accuracy: 1e-9)
        XCTAssertEqual(c.staticValue(of: "mesh.99.x"), 0, "範囲外は 0")
        c.setStaticValue(0.9, of: "mesh.99.x")   // 範囲外は無視(落ちない)
        // フリーズフレーム: 変形キーもその時刻の値で焼き込まれる
        c.keyframes["mesh.4.x"] = [Keyframe(t: 0, v: 0.8), Keyframe(t: 2, v: 0.4)]
        let f = SpeedEditing.makeFreezeClip(from: c, at: 1, fps: 30)
        XCTAssertTrue(f.keyframes.isEmpty)
        XCTAssertEqual(f.meshWarp?.points[4].x ?? -1, 0.6, accuracy: 1e-9)
    }

    // MARK: 構造変更とキーの追従

    func testKeyMaintenanceOnStructureChanges() {
        var c = imageClip()
        _ = WarpEditing.ensureMesh(&c)
        _ = WarpEditing.addPin(&c, hx: 0.2, hy: 0.2)
        _ = WarpEditing.addPin(&c, hx: 0.5, hy: 0.5)
        _ = WarpEditing.addPin(&c, hx: 0.8, hy: 0.8)
        c.keyframes["mesh.4.x"] = [Keyframe(t: 0, v: 0.5)]
        c.keyframes["pin.0.x"] = [Keyframe(t: 0, v: 0.2)]
        c.keyframes["pin.2.y"] = [Keyframe(t: 1, v: 0.9)]
        // ピンを消すと、後ろのピンのキーが詰まる
        XCTAssertTrue(WarpEditing.removePin(&c, index: 0))
        XCTAssertNil(c.keyframes["pin.0.x"])
        XCTAssertEqual(c.keyframes["pin.1.y"]?.first?.v ?? -1, 0.9, accuracy: 1e-9, "pin.2 のキーが pin.1 へ")
        // 固定にすると、そのピンのキーは外れる
        c.keyframes["pin.1.x"] = [Keyframe(t: 0, v: 0.8)]
        XCTAssertTrue(WarpEditing.setPinFixed(&c, index: 1, true))
        XCTAssertNil(c.keyframes["pin.1.x"]); XCTAssertNil(c.keyframes["pin.1.y"])
        // 格子を変えるとメッシュのキーだけ外れる(ピンのキーは残る)
        c.keyframes["pin.0.x"] = [Keyframe(t: 0, v: 0.2)]
        XCTAssertTrue(WarpEditing.setMeshGrid(&c, cols: 4, rows: 4))
        XCTAssertNil(c.keyframes["mesh.4.x"])
        XCTAssertNotNil(c.keyframes["pin.0.x"])
        // 変形を外すと、その変形のキーも外れる
        XCTAssertTrue(WarpEditing.clearMesh(&c))
        XCTAssertTrue(WarpEditing.clearPuppet(&c))
        XCTAssertTrue(c.keyframes.isEmpty)
        // 点のリセットは、その点のキーも外す
        var r = meshedClip()
        r.keyframes["mesh.4.x"] = [Keyframe(t: 0, v: 0.9)]
        XCTAssertTrue(WarpEditing.resetMeshPoint(&r, index: 4))
        XCTAssertNil(r.keyframes["mesh.4.x"])
        XCTAssertFalse(r.hasActiveWarp(at: 0))
    }

    func testSplitKeepsWarpValuesContinuous() throws {
        var c = meshedClip()
        c.keyframes["mesh.4.x"] = [Keyframe(t: 0, v: 0.5), Keyframe(t: 3, v: 0.8)]
        let parts = try XCTUnwrap(ClipEditing.split(c, at: 1.5))
        for t in [0.0, 0.7, 1.49] {
            XCTAssertEqual(parts.left.meshWarp(at: t)?.points[4].x ?? -1,
                           c.meshWarp(at: t)?.points[4].x ?? -2, accuracy: 1e-9)
        }
        for t in [0.0, 0.8, 1.5] {
            XCTAssertEqual(parts.right.meshWarp(at: t)?.points[4].x ?? -1,
                           c.meshWarp(at: t + 1.5)?.points[4].x ?? -2, accuracy: 1e-9)
        }
    }

    // MARK: ドラッグ相当の計算

    func testWarpDragGeometryRoundTrip() {
        let box = TransformBox(center: CGPoint(x: 500, y: 400), width: 400, height: 300, rotation: 0)
        XCTAssertEqual(WarpDrag.canvasPoint(WarpPoint(x: 0.5, y: 0.5), box: box), CGPoint(x: 500, y: 400))
        XCTAssertEqual(WarpDrag.canvasPoint(WarpPoint(x: 1, y: 1), box: box), CGPoint(x: 700, y: 550))
        let back = WarpDrag.warpPoint(canvas: CGPoint(x: 700, y: 550), box: box)
        XCTAssertEqual(back.x, 1, accuracy: 1e-9); XCTAssertEqual(back.y, 1, accuracy: 1e-9)
        // 回転 90 度(時計回り): 右端(1, 0.5)は中心の真下へ
        let rot = TransformBox(center: CGPoint(x: 500, y: 400), width: 400, height: 300, rotation: 90)
        let rp = WarpDrag.canvasPoint(WarpPoint(x: 1, y: 0.5), box: rot)
        XCTAssertEqual(rp.x, 500, accuracy: 1e-9); XCTAssertEqual(rp.y, 600, accuracy: 1e-9)
        let rback = WarpDrag.warpPoint(canvas: rp, box: rot)
        XCTAssertEqual(rback.x, 1, accuracy: 1e-9); XCTAssertEqual(rback.y, 0.5, accuracy: 1e-9)
    }

    func testWarpDragHitTestAndApply() {
        var c = meshedClip()
        _ = WarpEditing.addPin(&c, hx: 0.25, hy: 0.25)
        _ = WarpEditing.addPin(&c, hx: 0.75, hy: 0.75, fixed: true)
        let box = TransformBox(center: CGPoint(x: 500, y: 400), width: 400, height: 300, rotation: 0)
        let handles = c.warpHandles(at: 0)
        XCTAssertEqual(handles.count, 9 + 2)
        let center = WarpDrag.canvasPoint(WarpPoint(x: 0.5, y: 0.5), box: box)
        XCTAssertEqual(WarpDrag.hitTest(center, handles: handles, box: box, radius: 12)?.kind, .mesh(4))
        let pinPos = WarpDrag.canvasPoint(WarpPoint(x: 0.25, y: 0.25), box: box)
        XCTAssertEqual(WarpDrag.hitTest(pinPos, handles: handles, box: box, radius: 12)?.kind, .pin(0))
        let fixedPos = WarpDrag.canvasPoint(WarpPoint(x: 0.75, y: 0.75), box: box)
        XCTAssertNil(WarpDrag.hitTest(fixedPos, handles: handles, box: box, radius: 12), "固定ピンには当たらない")
        XCTAssertNil(WarpDrag.hitTest(CGPoint(x: 0, y: 0), handles: handles, box: box, radius: 12))
        // ドラッグ: 中央の点を (0.75, 0.5) の場所へ
        let target = WarpDrag.canvasPoint(WarpPoint(x: 0.75, y: 0.5), box: box)
        let moved = WarpDrag.apply(.mesh(4), to: c, at: 0, tolerance: 0.01, canvas: target, box: box)
        XCTAssertEqual(moved.meshWarp?.points[4].x ?? -1, 0.75, accuracy: 1e-9)
        XCTAssertEqual(moved.meshWarp?.points[4].y ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertTrue(moved.keyframes.isEmpty, "キーが無ければ静的な値を書く")
        // キーがある点のドラッグは、キーへ書く
        var k = meshedClip()
        k.keyframes["mesh.4.x"] = [Keyframe(t: 0, v: 0.5), Keyframe(t: 3, v: 0.5)]
        k.keyframes["mesh.4.y"] = [Keyframe(t: 0, v: 0.5), Keyframe(t: 3, v: 0.5)]
        let dragged = WarpDrag.apply(.mesh(4), to: k, at: 1, tolerance: 0.01, canvas: target, box: box)
        XCTAssertEqual(dragged.meshWarp?.points[4].x ?? -1, 0.5, accuracy: 1e-9, "静的な値は動かない")
        XCTAssertEqual(dragged.meshWarp(at: 1)?.points[4].x ?? -1, 0.75, accuracy: 1e-9)
        // 範囲外へ引っ張っても、位置の範囲で抑えられる
        let far = WarpDrag.apply(.mesh(4), to: c, at: 0, tolerance: 0.01, canvas: CGPoint(x: 10000, y: 400), box: box)
        XCTAssertEqual(far.meshWarp?.points[4].x ?? -1, MeshWarp.positionRange.upperBound, accuracy: 1e-9)
    }

    // MARK: 描画(画素・時間で変わる)

    private func twoColorImage(dir: String) throws -> String {
        let path = dir + "/two.png"
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 50, y: 0, width: 50, height: 100))   // 左下原点の ctx では右半分 → 画面でも右半分が青
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try XCTUnwrap(ctx.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return path
    }

    private func renderPixels(_ configure: (inout Clip) -> Void, src: String, at t: Double) throws -> (Int, Int) -> [Int] {
        var p = Project.new()
        p.width = 200; p.height = 200
        p.bg = "#00ff00"
        var c = Clip()
        c.id = "img"; c.type = .image; c.start = 0; c.duration = 4; c.src = src
        configure(&c)
        p.tracks[0].clips = [c]
        let img = try XCTUnwrap(Renderer(project: p, assets: RenderAssets()).renderImage(t: t))
        var d = [UInt8](repeating: 0, count: img.width * img.height * 4)
        let g = CGContext(data: &d, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        g.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return { x, y in let i = (y * img.width + x) * 4; return [Int(d[i]), Int(d[i + 1]), Int(d[i + 2])] }
    }

    func testAnimatedMeshMovesBoundaryOverTime() throws {
        let dir = NSTemporaryDirectory() + "warpkf-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let src = try twoColorImage(dir: dir)
        let configure: (inout Clip) -> Void = { c in
            c.meshWarp = MeshWarp(cols: 3, rows: 3)
            // 中央の点: t=0 は元の位置(0.5)、t=2 で 0.75 へ(静的な値は元の位置のまま)
            c.keyframes["mesh.4.x"] = [Keyframe(t: 0, v: 0.5), Keyframe(t: 2, v: 0.75)]
        }
        let early = try renderPixels(configure, src: src, at: 0)
        XCTAssertGreaterThan(early(110, 100)[2], 200, "t=0 は identity: 境界は x=100 のままなので青")
        let late = try renderPixels(configure, src: src, at: 2.5)
        XCTAssertGreaterThan(late(110, 100)[0], 200, "t=2 以後は中央が右へ寄り、境界も右へ動いて赤")
        // キーの値が identity の時刻の描画は、変形なしと完全一致
        let plain = try renderPixels({ _ in }, src: src, at: 0)
        for (x, y) in [(10, 10), (60, 100), (150, 100), (199, 199)] {
            XCTAssertEqual(early(x, y), plain(x, y), "identity の時刻は画素が完全一致 (\(x),\(y))")
        }
    }
}
