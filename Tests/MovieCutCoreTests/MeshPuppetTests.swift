import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import MovieCutCore

/// メッシュ変形(W3-04 #55)・パペット変形(W3-05 #56): 変位場の数学、保存往復、
/// 変形なしでの完全一致、変形の画素の方向性、極端な変位での破綻なし。
final class MeshPuppetTests: XCTestCase {

    // MARK: 変位場の数学

    func testMeshDisplacementAtVertexAndMidpoint() {
        var m = MeshWarp(cols: 3, rows: 3)
        // 中央(番号 4)を右へ 0.2・下へ 0.1
        m.points[4] = WarpPoint(x: 0.7, y: 0.6)
        let atCenter = m.displacement(u: 0.5, v: 0.5)
        XCTAssertEqual(atCenter.x, 0.2, accuracy: 1e-9)
        XCTAssertEqual(atCenter.y, 0.1, accuracy: 1e-9)
        // 角は元の位置のまま(変位 0)
        XCTAssertEqual(m.displacement(u: 0, v: 0).x, 0, accuracy: 1e-9)
        XCTAssertEqual(m.displacement(u: 1, v: 1).y, 0, accuracy: 1e-9)
        // 中央と角の中間は、双線形でちょうど半分
        XCTAssertEqual(m.displacement(u: 0.25, v: 0.5).x, 0.1, accuracy: 1e-9)
        XCTAssertFalse(m.isIdentity)
        XCTAssertTrue(MeshWarp().isIdentity)
    }

    func testPuppetDisplacementFollowsPinAndFadesOut() {
        let p = PuppetWarp(pins: [PuppetPin(hx: 0.5, hy: 0.5, x: 0.5, y: 0.8)], radius: 0.4)
        // ピンの元の位置では、ピンの変位そのもの
        let atPin = p.displacement(u: 0.5, v: 0.5)
        XCTAssertEqual(atPin.x, 0, accuracy: 1e-9)
        XCTAssertEqual(atPin.y, 0.3, accuracy: 1e-9)
        // 影響半径の外は 0
        XCTAssertEqual(p.displacement(u: 0.5, v: 0.05).y, 0, accuracy: 1e-9)
        // ピンが 1 本だけのときは、半径の内側は重み付き平均 = ピンの変位そのもの(重みは相対量)
        XCTAssertEqual(p.displacement(u: 0.5, v: 0.7).y, 0.3, accuracy: 1e-9)
        // 固定ピンを足すと、固定ピンへ近づくほど変位が弱まる(重みの奪い合い)
        let anchored = PuppetWarp(pins: [
            PuppetPin(hx: 0.5, hy: 0.5, x: 0.5, y: 0.8),
            PuppetPin(hx: 0.5, hy: 0.9, fixed: true),
        ], radius: 0.6)
        let nearFixed = anchored.displacement(u: 0.5, v: 0.85)
        XCTAssertGreaterThan(nearFixed.y, 0)
        XCTAssertLessThan(nearFixed.y, 0.15, "固定ピンの近くでは変位が大きく弱まる")
        XCTAssertFalse(p.isIdentity)
        XCTAssertTrue(PuppetWarp().isIdentity)
        XCTAssertTrue(PuppetWarp(pins: [PuppetPin(hx: 0.2, hy: 0.2)]).isIdentity)
    }

    func testFixedPinAnchorsField() {
        // 可動ピンと固定ピンが同じ場所: その点の変位は 0(固定が錨になる)
        let p = PuppetWarp(pins: [
            PuppetPin(hx: 0.5, hy: 0.5, x: 0.9, y: 0.5),
            PuppetPin(hx: 0.5, hy: 0.5, fixed: true),
        ], radius: 0.5)
        let d = p.displacement(u: 0.5, v: 0.5)
        XCTAssertEqual(d.x, 0.2, accuracy: 1e-9, "重みが等しいので変位は半分になる")
        // 固定ピンだけなら、どこも動かない
        let fixedOnly = PuppetWarp(pins: [PuppetPin(hx: 0.5, hy: 0.5, fixed: true)], radius: 0.9)
        XCTAssertTrue(fixedOnly.isIdentity)
        XCTAssertEqual(fixedOnly.displacement(u: 0.5, v: 0.5).x, 0, accuracy: 1e-9)
    }

    // MARK: 保存

    func testUnwarpedClipWritesNoWarpKeys() throws {
        var c = Clip()
        c.type = .image
        let json = String(data: try JSONEncoder().encode(c), encoding: .utf8)!
        XCTAssertFalse(json.contains("meshWarp"), "変形なしのクリップは従来と完全一致")
        XCTAssertFalse(json.contains("puppetWarp"))
        // 往復しても値が変わらず、変形キーは出てこない
        let back = try JSONDecoder().decode(Clip.self, from: Data(json.utf8))
        XCTAssertEqual(back, c)
        let again = String(data: try JSONEncoder().encode(back), encoding: .utf8)!
        XCTAssertFalse(again.contains("meshWarp"))
        XCTAssertFalse(again.contains("puppetWarp"))
    }

    func testWarpRoundTrip() throws {
        var c = Clip()
        c.type = .image
        var m = MeshWarp(cols: 4, rows: 2)
        m.points[3] = WarpPoint(x: 1.2, y: -0.1)
        c.meshWarp = m
        c.puppetWarp = PuppetWarp(pins: [
            PuppetPin(hx: 0.25, hy: 0.75, x: 0.4, y: 0.6),
            PuppetPin(hx: 0.8, hy: 0.2, fixed: true),
        ], radius: 0.5)
        let data = try JSONEncoder().encode(c)
        let back = try JSONDecoder().decode(Clip.self, from: data)
        XCTAssertEqual(back, c)
        XCTAssertEqual(back.meshWarp?.cols, 4)
        XCTAssertEqual(back.puppetWarp?.pins.count, 2)
        XCTAssertEqual(back.puppetWarp?.radius, 0.5)
        // 既定の半径は書かない
        var c2 = Clip(); c2.type = .image
        c2.puppetWarp = PuppetWarp(pins: [PuppetPin(hx: 0.5, hy: 0.5, x: 0.6, y: 0.5)])
        let j2 = String(data: try JSONEncoder().encode(c2), encoding: .utf8)!
        XCTAssertFalse(j2.contains("radius"), "既定の半径はファイルに書かない")
        XCTAssertTrue(j2.contains("puppetWarp"))
    }

    func testUnknownKeysInsideWarpArePreserved() throws {
        let json = #"{"id":"a","type":"image","start":0,"duration":1,"offset":0,"meshWarp":{"cols":3,"rows":3,"points":[{"x":0,"y":0},{"x":0.5,"y":0},{"x":1,"y":0},{"x":0,"y":0.5},{"x":0.6,"y":0.5},{"x":1,"y":0.5},{"x":0,"y":1},{"x":0.5,"y":1},{"x":1,"y":1}],"futureKey":7}}"#
        let c = try JSONDecoder().decode(Clip.self, from: Data(json.utf8))
        XCTAssertEqual(c.meshWarp?.points[4].x, 0.6)
        let out = String(data: try JSONEncoder().encode(c), encoding: .utf8)!
        XCTAssertTrue(out.contains("futureKey"), "知らないキーは捨てずに書き戻す")
    }

    func testBrokenWarpValueFallsBackToExtra() throws {
        let json = #"{"id":"a","type":"image","start":0,"duration":1,"offset":0,"meshWarp":"oops"}"#
        let c = try JSONDecoder().decode(Clip.self, from: Data(json.utf8))
        XCTAssertNil(c.meshWarp)
        let out = String(data: try JSONEncoder().encode(c), encoding: .utf8)!
        XCTAssertTrue(out.contains("oops"), "読めない変形は捨てずに書き戻す")
    }

    // MARK: 編集

    func testEditingGuardsAndGridResample() {
        var c = Clip(); c.type = .image
        XCTAssertFalse(WarpEditing.setMeshPoint(&c, index: 0, x: 0, y: 0), "メッシュが無いうちは動かせない")
        XCTAssertTrue(WarpEditing.ensureMesh(&c))
        XCTAssertFalse(WarpEditing.ensureMesh(&c), "二度目は変わらない")
        XCTAssertTrue(WarpEditing.setMeshPoint(&c, index: 4, x: 0.8, y: 0.5))
        XCTAssertTrue(c.hasActiveWarp)
        // 格子を細かくしても、中央付近の変位が引き継がれる
        XCTAssertTrue(WarpEditing.setMeshGrid(&c, cols: 5, rows: 5))
        let d = c.meshWarp!.displacement(u: 0.5, v: 0.5)
        XCTAssertEqual(d.x, 0.3, accuracy: 0.05)
        XCTAssertTrue(WarpEditing.clearMesh(&c))
        XCTAssertNil(c.meshWarp)
        XCTAssertFalse(c.hasActiveWarp)
        // パペット: 固定ピンは動かせない
        XCTAssertEqual(WarpEditing.addPin(&c, hx: 0.5, hy: 0.5, fixed: true), 0)
        XCTAssertFalse(WarpEditing.movePin(&c, index: 0, x: 0.9, y: 0.9))
        XCTAssertTrue(WarpEditing.setPinFixed(&c, index: 0, false))
        XCTAssertTrue(WarpEditing.movePin(&c, index: 0, x: 0.9, y: 0.9))
        XCTAssertTrue(c.hasActiveWarp)
        XCTAssertTrue(WarpEditing.removePin(&c, index: 0))
        XCTAssertTrue(WarpEditing.clearPuppet(&c))
        // 対象外の種類(音声)には付けられない
        var a = Clip(); a.type = .audio
        XCTAssertFalse(WarpEditing.ensureMesh(&a))
        XCTAssertNil(WarpEditing.addPin(&a, hx: 0.5, hy: 0.5))
    }

    // MARK: 描画(画素)

    /// 左半分が赤・右半分が青の 100×100 PNG を作って、そのパスを返す。
    private func twoColorImage(verticalSplit: Bool, dir: String) throws -> String {
        let path = dir + "/two.png"
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        // ctx は左下原点。画面(左上原点)で左赤・右青 / 上赤・下青になるよう塗る
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        if verticalSplit { ctx.fill(CGRect(x: 50, y: 0, width: 50, height: 100)) } else { ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 50)) }
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try XCTUnwrap(ctx.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return path
    }

    /// 200×200 のプロジェクトに画像クリップ 1 つを置いて描き、画素(RGB・左上原点)を読む。
    private func renderPixels(_ configure: (inout Clip) -> Void, src: String) throws -> (Int, Int) -> [Int] {
        var p = Project.new()
        p.width = 200; p.height = 200
        p.bg = "#00ff00"
        var c = Clip()
        c.id = "img"; c.type = .image; c.start = 0; c.duration = 2; c.src = src
        configure(&c)
        p.tracks[0].clips = [c]
        let img = try XCTUnwrap(Renderer(project: p, assets: RenderAssets()).renderImage(t: 0.5))
        XCTAssertEqual(img.width, 200); XCTAssertEqual(img.height, 200)
        var d = [UInt8](repeating: 0, count: img.width * img.height * 4)
        let g = CGContext(data: &d, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        g.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return { x, y in let i = (y * img.width + x) * 4; return [Int(d[i]), Int(d[i + 1]), Int(d[i + 2])] }
    }

    private func makeDir() throws -> String {
        let dir = NSTemporaryDirectory() + "meshpuppet-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    func testIdentityWarpRendersExactlyLikeNoWarp() throws {
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let src = try twoColorImage(verticalSplit: true, dir: dir)
        let plain = try renderPixels({ _ in }, src: src)
        let identity = try renderPixels({ c in
            c.meshWarp = MeshWarp()   // 全点が元の位置
            c.puppetWarp = PuppetWarp(pins: [PuppetPin(hx: 0.5, hy: 0.5)])  // 動かしていないピン
        }, src: src)
        for (x, y) in [(10, 10), (60, 100), (150, 100), (100, 30), (30, 170), (199, 199)] {
            XCTAssertEqual(identity(x, y), plain(x, y), "identity の変形は画素が完全一致するはず (\(x),\(y))")
        }
        XCTAssertGreaterThan(plain(60, 100)[0], 200, "左は赤")
        XCTAssertGreaterThan(plain(150, 100)[2], 200, "右は青")
    }

    func testMeshCenterMovedRightPullsBoundaryRight() throws {
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let src = try twoColorImage(verticalSplit: true, dir: dir)
        let px = try renderPixels({ c in
            var m = MeshWarp(cols: 3, rows: 3)
            m.points[4] = WarpPoint(x: 0.75, y: 0.5)   // 中央を右へ
            c.meshWarp = m
        }, src: src)
        // 境界(元は x=100)は中央付近で右へ寄る: x=110 はまだ赤、x=140 は青
        XCTAssertGreaterThan(px(110, 100)[0], 200, "境界が右へ動いたので赤が広がる")
        XCTAssertGreaterThan(px(140, 100)[2], 200)
        // 角のほうはほとんど動かない
        XCTAssertGreaterThan(px(60, 10)[0], 200)
        XCTAssertGreaterThan(px(150, 10)[2], 200)
    }

    func testPuppetPinDraggedDownPullsBoundaryDown() throws {
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let src = try twoColorImage(verticalSplit: false, dir: dir)   // 上赤・下青、境界は y=100
        let px = try renderPixels({ c in
            c.puppetWarp = PuppetWarp(pins: [PuppetPin(hx: 0.5, hy: 0.5, x: 0.5, y: 0.85)], radius: 0.6)
        }, src: src)
        // 中央付近では境界が下へ寄る: y=125 でも赤
        XCTAssertGreaterThan(px(100, 125)[0], 200, "ピンに引っ張られて赤が下へ広がる")
        XCTAssertGreaterThan(px(100, 185)[2], 200, "下のほうは青のまま")
        // 半径の外(左下の角)は動かない
        XCTAssertGreaterThan(px(8, 190)[2], 200, "半径の外は青のまま")
    }

    func testExtremeDisplacementDoesNotBreak() throws {
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let src = try twoColorImage(verticalSplit: true, dir: dir)
        let px = try renderPixels({ c in
            var m = MeshWarp(cols: 3, rows: 3)
            for i in m.points.indices { m.points[i] = WarpPoint(x: 2, y: -1) }   // 許す範囲の端まで全点
            c.meshWarp = m
            c.puppetWarp = PuppetWarp(pins: [PuppetPin(hx: 0.5, hy: 0.5, x: -1, y: 2)], radius: 1)
        }, src: src)
        // 描画が返り、どこかは元絵の色(赤か青)の画素になっている(全面が壊れた色にならない)
        var sawImageColor = false
        for x in stride(from: 0, to: 200, by: 10) {
            for y in stride(from: 0, to: 200, by: 10) {
                let p = px(x, y)
                if p[0] > 200 || p[2] > 200 { sawImageColor = true }
            }
        }
        XCTAssertTrue(sawImageColor)
        // WarpRenderer 単体でも、identity でない極端な場で画像が返る
        var c = Clip(); c.type = .image
        var m = MeshWarp(); m.points[4] = WarpPoint(x: 2, y: 2); c.meshWarp = m
        let baseCtx = try XCTUnwrap(CGContext(data: nil, width: 40, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let base = try XCTUnwrap(baseCtx.makeImage())
        let warped = WarpRenderer.warp(base, clip: c, bounds: CGRect(x: 0, y: 0, width: 40, height: 40))
        XCTAssertNotNil(warped)
        XCTAssertEqual(warped?.width, 40)
        // identity では warp は nil(描画経路をスキップする印)
        var plain = Clip(); plain.type = .image
        XCTAssertNil(WarpRenderer.warp(base, clip: plain, bounds: CGRect(x: 0, y: 0, width: 40, height: 40)))
    }
}
