import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import MovieCutCore

/// カメラ×複合クリップの回帰テスト(バッチO統合ブロッカー修正)。
///
/// ブロッカーの内容: `Renderer.render` はカメラ変換を最終段で 1 回適用するが、
/// フレーム経路の複合クリップは `compoundRenderer` がカメラを含むプロジェクト全体を
/// コピーして子の `renderImage` を呼ぶため、子側でもカメラがもう 1 回かかっていた
/// (しかも子側ではカメラキーフレームが親時刻ではなく子時刻で評価される)。
/// 全面複合の高速経路(`drawFrame` 直接描画)では二重適用が起きないため、
/// 同じ複合クリップでも経路によって絵が変わっていた。
/// 修正: 子 Renderer 用プロジェクトでは `camera` を落とす(カメラは親の最終段でのみ 1 回)。
///
/// 実測例の再現: 200×100、左赤/右青、カメラパン x=0.25。
/// 単独適用の正解は境界 100 → 150。二重適用だと境界が画面外へ飛ぶ。
final class CameraCompoundTests: XCTestCase {

    // MARK: 共通(CameraTests と同じ流儀)

    /// 左半分が赤・右半分が青の PNG(200×100、キャンバスと同寸)。
    func halvesPNG() throws -> String {
        let c = CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        c.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)); c.fill(CGRect(x: 100, y: 0, width: 100, height: 100))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("camera-compound-halves-\(UUID().uuidString).png")
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

    func isRed(_ p: Pixels, _ x: Int, _ y: Int = 50) -> Bool {
        let i = (y * p.w + x) * 4
        return p.d[i] > 128 && p.d[i + 2] < 128
    }

    func isBlue(_ p: Pixels, _ x: Int, _ y: Int = 50) -> Bool {
        let i = (y * p.w + x) * 4
        return p.d[i + 2] > 128 && p.d[i] < 128
    }

    /// 中央の行(y=50)で、赤から青へ切り替わる境界の x(最初の青画素)。青が無ければ nil。
    func boundaryX(_ p: Pixels) -> Int? {
        for x in 0..<p.w where isBlue(p, x) { return x }
        return nil
    }

    func halvesImageClip(src: String, start: Double = 0, duration: Double = 10) -> Clip {
        var img = Clip(); img.id = "inner"; img.type = .image; img.src = src
        img.start = start; img.duration = duration
        return img
    }

    /// 左赤/右青の画像を直接置いたプロジェクト(単独適用の正解)。
    func plainProject(src: String, camera: CameraSettings?) -> Project {
        var p = Project(); p.width = 200; p.height = 100; p.fps = 30; p.bg = "#000000"
        var tr = Track(); tr.clips = [halvesImageClip(src: src)]; p.tracks = [tr]
        p.camera = camera
        return p
    }

    /// 左赤/右青の画像を複合クリップに包んだプロジェクト。
    /// `compoundScale == 1` のとき高速経路(drawFrame 直接描画)、それ以外はフレーム経路(compoundFrame)を通る。
    func compoundProject(src: String, camera: CameraSettings?, compoundScale: Double?, compoundStart: Double = 0) -> Project {
        var comp = Clip(); comp.id = "comp"; comp.type = .compound
        comp.start = compoundStart; comp.duration = 10
        comp.scale = compoundScale
        var inner = Track(); inner.clips = [halvesImageClip(src: src)]
        comp.tracks = [inner]
        var p = Project(); p.width = 200; p.height = 100; p.fps = 30; p.bg = "#000000"
        var tr = Track(); tr.clips = [comp]; p.tracks = [tr]
        p.camera = camera
        return p
    }


    /// 左赤/右青の画像をシーン定義に入れ、シーンフレーム経由で参照するプロジェクト。
    /// `sceneScale == 1` のとき高速経路(drawFrame 直接描画)、それ以外はフレーム経路(sceneFrame)を通る。
    func sceneProject(src: String, camera: CameraSettings?, sceneScale: Double?, sceneStart: Double = 0) -> Project {
        var scene = SceneDefinition(); scene.name = "導入"
        var inner = Track(); inner.clips = [halvesImageClip(src: src)]
        scene.tracks = [inner]
        var sc = Clip(); sc.id = "sceneclip"; sc.type = .scene; sc.sceneId = scene.id
        sc.start = sceneStart; sc.duration = 10
        sc.scale = sceneScale
        var p = Project(); p.width = 200; p.height = 100; p.fps = 30; p.bg = "#000000"
        p.scenes = [scene]
        var tr = Track(); tr.clips = [sc]; p.tracks = [tr]
        p.camera = camera
        return p
    }

    /// 2 枚の画素の最大の差(チャンネルごと)。配列そのものを XCTAssertEqual に渡すと
    /// 失敗時に全画素がログへ出るので、差の最大値だけを比べる。
    func maxDiff(_ a: Pixels, _ b: Pixels) -> Int {
        var m = 0
        for i in 0..<min(a.d.count, b.d.count) { m = max(m, abs(Int(a.d[i]) - Int(b.d[i]))) }
        return m
    }

    /// 画素の分類(0=その他/背景、1=赤、2=青)。境界の 1 列だけ補間で混色になり得る
    /// フレーム経路(scale=0.999 の再サンプリング)でも、色の割り当ては経路で変わらないことを見る。
    func classMap(_ p: Pixels) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: p.w * p.h)
        for i in 0..<(p.w * p.h) {
            if isRed(p, i % p.w, i / p.w) { out[i] = 1 }
            else if isBlue(p, i % p.w, i / p.w) { out[i] = 2 }
        }
        return out
    }

    /// 分類が違う画素の数(配列同士を直接比べないのは maxDiff と同じ理由)。
    func classMismatchCount(_ a: Pixels, _ b: Pixels) -> Int {
        let x = classMap(a), y = classMap(b)
        var n = 0
        for i in 0..<min(x.count, y.count) where x[i] != y[i] { n += 1 }
        return n
    }

    func render(_ p: Project, _ t: Double) throws -> Pixels {
        pixels(try XCTUnwrap(Renderer(project: p, assets: RenderAssets()).renderImage(t: t)))
    }

    /// 境界が正解(150)で、代表点の色が単独適用と一致すること。
    func assertCorrectPan(_ px: Pixels, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(boundaryX(px), 150, "\(label): カメラ単独適用の正解は境界 150", file: file, line: line)
        XCTAssertTrue(isRed(px, 60), "\(label): x=60 は赤(元の x=10)", file: file, line: line)
        XCTAssertTrue(isRed(px, 140), "\(label): x=140 は赤(元の x=90)", file: file, line: line)
        XCTAssertFalse(isRed(px, 160), "\(label): x=160 は赤でない", file: file, line: line)
        XCTAssertTrue(isBlue(px, 160), "\(label): x=160 は青(元の x=110)", file: file, line: line)
        XCTAssertTrue(isBlue(px, 190), "\(label): x=190 は青", file: file, line: line)
        XCTAssertFalse(isRed(px, 20) || isBlue(px, 20), "\(label): x=20 は背景(絵が右へ 50px ずれた外側)", file: file, line: line)
    }

    // MARK: 回帰テスト

    /// カメラ有効+複合クリップで、高速経路(scale=1.0)とフレーム経路(scale=0.999)が
    /// 同じ絵になり、単独適用の正解(境界 150)とも一致する。
    func testCameraCompoundFastAndFramePathsAgreeAndMatchSingleApplication() throws {
        let src = try halvesPNG()
        var pan = CameraSettings(); pan.x = 0.25

        let plain = try render(plainProject(src: src, camera: pan), 0.5)
        assertCorrectPan(plain, "単独(複合なし)")

        // 高速経路: 全面・等倍の複合は drawFrame で直接描かれる
        let fast = try render(compoundProject(src: src, camera: pan, compoundScale: nil), 0.5)
        assertCorrectPan(fast, "複合・高速経路")
        XCTAssertEqual(maxDiff(fast, plain), 0, "高速経路は単独適用と画素一致する")

        // フレーム経路: scale=0.999 で全面条件を外し、compoundFrame(子の renderImage)を通す。
        // 0.999 倍は中心(境界の真下)基準なので正解の境界位置は変わらない。
        // 修正前はここでカメラが二重にかかり、境界が画面外(x≈200)へ飛んでいた。
        let frame = try render(compoundProject(src: src, camera: pan, compoundScale: 0.999), 0.5)
        assertCorrectPan(frame, "複合・フレーム経路")
        XCTAssertEqual(classMismatchCount(frame, fast), 0, "フレーム経路は高速経路と画素の色割り当てが一致する(経路で絵が変わらない)")
    }

    /// カメラキーフレーム+開始時刻がずれた複合クリップでも、カメラは親時刻で 1 回だけ評価される。
    /// 修正前は子側が子時刻(t − start)でカメラを評価して二重にかけていた。
    func testCameraKeyframeCompoundEvaluatesCameraOnceAtParentTime() throws {
        let src = try halvesPNG()
        var cam = CameraSettings()
        cam.keyframes["x"] = [Keyframe(t: 0, v: 0.5), Keyframe(t: 2, v: 0.25)]

        // 親時刻 t=2 ではカメラ x=0.25 → 境界 150 が正解
        let plain = try render(plainProject(src: src, camera: cam), 2)
        assertCorrectPan(plain, "単独(キーフレーム)")

        // 複合の開始が 1 秒ずれているので、子時刻は 1 秒(=カメラ x=0.375)。
        // 子側でカメラを評価すると余分に +25px ずれて境界が 175〜画面外になる。
        let fast = try render(compoundProject(src: src, camera: cam, compoundScale: nil, compoundStart: 1), 2)
        assertCorrectPan(fast, "複合・高速経路(キーフレーム)")
        XCTAssertEqual(maxDiff(fast, plain), 0, "高速経路は単独適用と画素一致する")

        let frame = try render(compoundProject(src: src, camera: cam, compoundScale: 0.999, compoundStart: 1), 2)
        assertCorrectPan(frame, "複合・フレーム経路(キーフレーム)")
        XCTAssertEqual(classMismatchCount(frame, fast), 0, "フレーム経路は高速経路と画素の色割り当てが一致する")
    }

    /// カメラ未設定の複合は従来どおり(両経路とも画素一致・境界 100 のまま)。
    func testNoCameraCompoundPathsUnchanged() throws {
        let src = try halvesPNG()
        let plain = try render(plainProject(src: src, camera: nil), 0.5)
        let fast = try render(compoundProject(src: src, camera: nil, compoundScale: nil), 0.5)
        let frame = try render(compoundProject(src: src, camera: nil, compoundScale: 0.999), 0.5)
        XCTAssertEqual(boundaryX(plain), 100)
        XCTAssertEqual(maxDiff(fast, plain), 0, "カメラ未設定の高速経路は従来と完全一致")
        XCTAssertEqual(classMismatchCount(frame, fast), 0, "カメラ未設定でも両経路は一致する")
    }

    // MARK: シーン版回帰テスト(統合時の追加修正: sceneRenderer も compoundRenderer と同じ作法)

    /// カメラ有効+シーンクリップで、高速経路(scale=1.0)とフレーム経路(scale=0.999)が
    /// 同じ絵になり、単独適用の正解(境界 150)とも一致する。
    /// 修正前は sceneFrame 経由で子側でもカメラがかかり、二重適用になっていた。
    func testCameraSceneFastAndFramePathsAgreeAndMatchSingleApplication() throws {
        let src = try halvesPNG()
        var pan = CameraSettings(); pan.x = 0.25

        let plain = try render(plainProject(src: src, camera: pan), 0.5)
        assertCorrectPan(plain, "単独(シーンなし)")

        let fast = try render(sceneProject(src: src, camera: pan, sceneScale: nil), 0.5)
        assertCorrectPan(fast, "シーン・高速経路")
        XCTAssertEqual(maxDiff(fast, plain), 0, "高速経路は単独適用と画素一致する")

        let frame = try render(sceneProject(src: src, camera: pan, sceneScale: 0.999), 0.5)
        assertCorrectPan(frame, "シーン・フレーム経路")
        XCTAssertEqual(classMismatchCount(frame, fast), 0, "フレーム経路は高速経路と画素の色割り当てが一致する(経路で絵が変わらない)")
    }

    /// カメラキーフレーム+開始時刻がずれたシーンクリップでも、カメラは親時刻で 1 回だけ評価される。
    func testCameraKeyframeSceneEvaluatesCameraOnceAtParentTime() throws {
        let src = try halvesPNG()
        var cam = CameraSettings()
        cam.keyframes["x"] = [Keyframe(t: 0, v: 0.5), Keyframe(t: 2, v: 0.25)]

        let plain = try render(plainProject(src: src, camera: cam), 2)
        assertCorrectPan(plain, "単独(キーフレーム・シーン)")

        let fast = try render(sceneProject(src: src, camera: cam, sceneScale: nil, sceneStart: 1), 2)
        assertCorrectPan(fast, "シーン・高速経路(キーフレーム)")
        XCTAssertEqual(maxDiff(fast, plain), 0, "高速経路は単独適用と画素一致する")

        let frame = try render(sceneProject(src: src, camera: cam, sceneScale: 0.999, sceneStart: 1), 2)
        assertCorrectPan(frame, "シーン・フレーム経路(キーフレーム)")
        XCTAssertEqual(classMismatchCount(frame, fast), 0, "フレーム経路は高速経路と画素の色割り当てが一致する")
    }

    /// カメラ未設定のシーンは従来どおり(両経路とも画素一致・境界 100 のまま)。
    func testNoCameraScenePathsUnchanged() throws {
        let src = try halvesPNG()
        let plain = try render(plainProject(src: src, camera: nil), 0.5)
        let fast = try render(sceneProject(src: src, camera: nil, sceneScale: nil), 0.5)
        let frame = try render(sceneProject(src: src, camera: nil, sceneScale: 0.999), 0.5)
        XCTAssertEqual(boundaryX(plain), 100)
        XCTAssertEqual(maxDiff(fast, plain), 0, "カメラ未設定の高速経路は従来と完全一致")
        XCTAssertEqual(classMismatchCount(frame, fast), 0, "カメラ未設定でも両経路は一致する")
    }
}
