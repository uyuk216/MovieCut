import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import MovieCutCore

/// カメラ(W3-02 / 監査 #54): 既定値での描画完全一致、変換の画素検証、キーフレーム補間、保存往復。
final class CameraTests: XCTestCase {

    // MARK: 保存

    func testDefaultProjectHasNoCameraKey() throws {
        let p = Project()
        let json = String(data: try p.encoded(), encoding: .utf8)!
        XCTAssertFalse(json.contains("\"camera\""), "カメラ未設定のプロジェクトには camera キーを書かない")
        let back = try Project.decode(from: p.encoded())
        XCTAssertNil(back.camera)
        XCTAssertEqual(back, p)
    }

    func testExplicitDefaultCameraIsNotWritten() throws {
        var p = Project()
        p.camera = CameraSettings()
        XCTAssertTrue(p.camera!.isDefault)
        let json = String(data: try p.encoded(), encoding: .utf8)!
        XCTAssertFalse(json.contains("\"camera\""), "既定値のカメラは書かない(従来ファイルと一致)")
    }

    func testCameraRoundTrips() throws {
        var p = Project()
        var cam = CameraSettings()
        cam.x = 0.4; cam.y = 0.6; cam.targetX = 0.3; cam.targetY = 0.7; cam.orbit = 25; cam.fov = 45
        cam.keyframes["x"] = [Keyframe(t: 0, v: 0.4), Keyframe(t: 2, v: 0.8, ease: .easeInOut)]
        cam.keyframes["fov"] = [Keyframe(t: 0, v: 45), Keyframe(t: 2, v: 30)]
        p.camera = cam
        let data = try p.encoded()
        XCTAssertTrue(String(data: data, encoding: .utf8)!.contains("\"camera\""))
        let back = try Project.decode(from: data)
        XCTAssertEqual(back.camera, cam)
        XCTAssertEqual(back, p)
    }

    func testUnknownCameraKeysSurvive() throws {
        var p = Project()
        var cam = CameraSettings(); cam.orbit = 10
        p.camera = cam
        var root = try JSONSerialization.jsonObject(with: p.encoded()) as! [String: Any]
        var camObj = root["camera"] as! [String: Any]
        camObj["futureCamKey"] = "keep-me"
        root["camera"] = camObj
        let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        let back = try Project.decode(from: data)
        let saved = String(data: try back.encoded(), encoding: .utf8)!
        XCTAssertTrue(saved.contains("futureCamKey"), "知らないカメラのキーは保持して書き戻す")
        XCTAssertEqual(back.camera?.orbit, 10)
    }

    // MARK: 値の解決・補間

    func testStateInterpolatesKeyframes() {
        var cam = CameraSettings()
        cam.keyframes["x"] = [Keyframe(t: 0, v: 0.5), Keyframe(t: 2, v: 0.9)]
        cam.keyframes["orbit"] = [Keyframe(t: 0, v: 0), Keyframe(t: 2, v: 90)]
        XCTAssertEqual(cam.state(at: 1).x, 0.7, accuracy: 1e-9)
        XCTAssertEqual(cam.state(at: 1).orbit, 45, accuracy: 1e-9)
        XCTAssertEqual(cam.state(at: -1).x, 0.5, accuracy: 1e-9, "最初のキーより前は端の値")
        XCTAssertEqual(cam.state(at: 5).x, 0.9, accuracy: 1e-9, "最後のキーより後は端の値")
        XCTAssertEqual(cam.state(at: 1).y, 0.5, accuracy: 1e-9, "キーの無い項目は静的な値")
    }

    func testZoomFromFov() {
        XCTAssertEqual(CameraSettings.zoom(forFov: 60), 1, accuracy: 1e-9)
        XCTAssertEqual(CameraSettings.zoom(forFov: 30), 2.1547, accuracy: 1e-3, "視野角が半分ほどで約 2.15 倍")
        XCTAssertEqual(CameraSettings.zoom(forFov: 120), 0.3333, accuracy: 1e-3)
        XCTAssertTrue(CameraState(x: 0.5, y: 0.5, targetX: 0.5, targetY: 0.5, orbit: 0, fov: 60).isIdentity)
        XCTAssertTrue(CameraState(x: 0.5, y: 0.5, targetX: 0.2, targetY: 0.2, orbit: 0, fov: 60).isIdentity,
                      "回転も拡大も無ければ注目点は絵に影響しない")
    }

    func testTransformMath() {
        let W = 200.0, H = 100.0
        let id = CameraState(x: 0.5, y: 0.5, targetX: 0.5, targetY: 0.5, orbit: 0, fov: 60)
        for p in [CGPoint(x: 0, y: 0), CGPoint(x: 200, y: 100), CGPoint(x: 37, y: 71)] {
            let q = CameraMath.map(p, state: id, width: W, height: H)
            XCTAssertEqual(Double(q.x), Double(p.x), accuracy: 1e-9)
            XCTAssertEqual(Double(q.y), Double(p.y), accuracy: 1e-9)
        }
        // パン: カメラ位置(50,50)が画面中央(100,50)に来る
        let pan = CameraState(x: 0.25, y: 0.5, targetX: 0.5, targetY: 0.5, orbit: 0, fov: 60)
        var q = CameraMath.map(CGPoint(x: 50, y: 50), state: pan, width: W, height: H)
        XCTAssertEqual(Double(q.x), 100, accuracy: 1e-9); XCTAssertEqual(Double(q.y), 50, accuracy: 1e-9)
        q = CameraMath.map(CGPoint(x: 0, y: 0), state: pan, width: W, height: H)
        XCTAssertEqual(Double(q.x), 50, accuracy: 1e-9); XCTAssertEqual(Double(q.y), 0, accuracy: 1e-9)
        // 回り込み 180°(注目点=中央): 点は中央に対して点対称へ
        let rot = CameraState(x: 0.5, y: 0.5, targetX: 0.5, targetY: 0.5, orbit: 180, fov: 60)
        q = CameraMath.map(CGPoint(x: 0, y: 0), state: rot, width: W, height: H)
        XCTAssertEqual(Double(q.x), 200, accuracy: 1e-6); XCTAssertEqual(Double(q.y), 100, accuracy: 1e-6)
        // 注目点が軸: 注目点そのものは回転しても動かない(カメラ位置=注目点のとき)
        let pivot = CameraState(x: 0.25, y: 0.5, targetX: 0.25, targetY: 0.5, orbit: 90, fov: 60)
        q = CameraMath.map(CGPoint(x: 50, y: 50), state: pivot, width: W, height: H)
        XCTAssertEqual(Double(q.x), 100, accuracy: 1e-6, "注目点は画面中央に来て、回転では動かない")
        XCTAssertEqual(Double(q.y), 50, accuracy: 1e-6)
        // unmap は map の逆
        let st = CameraState(x: 0.4, y: 0.6, targetX: 0.3, targetY: 0.4, orbit: 33, fov: 40)
        let p0 = CGPoint(x: 123, y: 45)
        let back = CameraMath.unmap(CameraMath.map(p0, state: st, width: W, height: H), state: st, width: W, height: H)
        XCTAssertEqual(Double(back.x), 123, accuracy: 1e-6); XCTAssertEqual(Double(back.y), 45, accuracy: 1e-6)
    }

    // MARK: 描画(画素)

    /// 左半分が赤・右半分が青の PNG(200×100、キャンバスと同寸)。
    func halvesPNG() throws -> String {
        let c = CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        c.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)); c.fill(CGRect(x: 100, y: 0, width: 100, height: 100))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("camera-halves-\(UUID().uuidString).png")
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, c.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url.path
    }

    struct Pixels { let w: Int; let h: Int; let d: [UInt8] }

    func pixels(_ img: CGImage) -> Pixels {
        var d = [UInt8](repeating: 0, count: img.width * img.height * 4)
        let c = CGContext(data: &d, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return Pixels(w: img.width, h: img.height, d: d)
    }

    /// (x, y) の画素が赤寄りか青寄りか(上下対称な絵なので行の向きは問わない)。
    func isRed(_ p: Pixels, _ x: Int, _ y: Int = 50) -> Bool {
        let i = (y * p.w + x) * 4
        return p.d[i] > 128 && p.d[i + 2] < 128
    }

    func project(camera: CameraSettings?) throws -> Project {
        var img = Clip(); img.type = .image; img.src = try halvesPNG(); img.start = 0; img.duration = 4
        var p = Project(); p.width = 200; p.height = 100; p.fps = 30
        var tr = Track(); tr.clips = [img]; p.tracks = [tr]
        p.camera = camera
        return p
    }

    func render(_ p: Project, _ t: Double) throws -> Pixels {
        pixels(try XCTUnwrap(Renderer(project: p, assets: RenderAssets()).renderImage(t: t)))
    }

    func testDefaultCameraRenderIsPixelIdentical() throws {
        let plain = try render(project(camera: nil), 0.5)
        let explicit = try render(project(camera: CameraSettings()), 0.5)
        XCTAssertEqual(plain.d, explicit.d, "既定値のカメラは描画を 1 画素も変えない")
        // キーフレームで既定値に戻る時刻も一致する
        var cam = CameraSettings()
        cam.keyframes["x"] = [Keyframe(t: 0, v: 0.5), Keyframe(t: 2, v: 0.9)]
        let keyed = try render(project(camera: cam), 0)
        XCTAssertEqual(plain.d, keyed.d, "t=0 で既定値のキーフレームも一致")
    }

    func testCameraPanAndOrbitChangePixels() throws {
        let base = try render(project(camera: nil), 0.5)
        XCTAssertTrue(isRed(base, 60)); XCTAssertFalse(isRed(base, 140))

        // パン(カメラ位置 0.25): 画面は右へ 50px ずれる → 画面 x=140 は元の x=90(赤)
        var pan = CameraSettings(); pan.x = 0.25
        let panned = try render(project(camera: pan), 0.5)
        XCTAssertTrue(isRed(panned, 140), "パンで赤い領域が右へ広がる")
        XCTAssertTrue(isRed(panned, 60))

        // 回り込み 180°: 左右が入れ替わる
        var rot = CameraSettings(); rot.orbit = 180
        let rotated = try render(project(camera: rot), 0.5)
        XCTAssertFalse(isRed(rotated, 60), "180° 回転で左は青になる")
        XCTAssertTrue(isRed(rotated, 140))

        // ズーム(視野角を狭く): 注目点=カメラ位置(左寄り)を軸に約 2 倍 → 画面は赤い領域だけになる
        var zoom = CameraSettings(); zoom.x = 0.25; zoom.targetX = 0.25; zoom.fov = 32.2
        let zoomed = try render(project(camera: zoom), 0.5)
        XCTAssertTrue(isRed(zoomed, 140), "ズームで境界が画面外へ出て、右側も赤になる")
        XCTAssertTrue(isRed(zoomed, 10))
        XCTAssertNotEqual(base.d, zoomed.d, "ズームで絵は変わる")
    }

    func testCameraKeyframeMovesRenderOverTime() throws {
        var cam = CameraSettings()
        cam.keyframes["x"] = [Keyframe(t: 0, v: 0.5), Keyframe(t: 2, v: 0.25)]
        let p = try project(camera: cam)
        let early = try render(p, 0)
        let late = try render(p, 2)
        XCTAssertTrue(isRed(early, 60)); XCTAssertFalse(isRed(early, 140))
        XCTAssertTrue(isRed(late, 140), "キーフレームでカメラが動くと描画も動く")
    }
}


// MARK: - バグ確認 第2部 C17: カメラの未知項目の往復

final class CameraUnknownKeysRoundTripTests: XCTestCase {
    func testUnknownKeyframeParamSurvivesRoundTrip() throws {
        let json = #"{"x":0.6,"keyframes":{"futureZoom":[{"t":0,"v":2}]}}"#
        let cam = try JSONDecoder().decode(CameraSettings.self, from: Data(json.utf8))
        let out = String(decoding: try JSONEncoder().encode(cam), as: UTF8.self)
        XCTAssertTrue(out.contains("futureZoom"), "未知のキーフレーム項目が往復で消えない: \(out)")
    }
    func testExtraOnlyCameraIsNotDefault() throws {
        let json = #"{"futureSetting":123}"#
        let cam = try JSONDecoder().decode(CameraSettings.self, from: Data(json.utf8))
        XCTAssertFalse(cam.isDefault, "未知項目だけでも、既定とは扱わない(保存で丸ごと消えるため)")
        let out = String(decoding: try JSONEncoder().encode(cam), as: UTF8.self)
        XCTAssertTrue(out.contains("futureSetting"))
    }
}
