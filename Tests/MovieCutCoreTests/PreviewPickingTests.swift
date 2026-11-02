import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import MovieCutCore

/// プレビュー上で重なったクリップを選ぶ(⌥ クリックの巡回): 当たり判定・手前から奥の並び・除外・巡回。
final class PreviewPickingTests: XCTestCase {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("picking-tests-\(UUID().uuidString)")
    override func setUpWithError() throws { try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    /// 100×100 の単色 PNG(キャンバスは 200×200 なので、拡大 1 で 200×200 に収まる)
    func png() throws -> String {
        let n = 100
        let c = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1); c.fill(CGRect(x: 0, y: 0, width: n, height: n))
        let url = tmp.appendingPathComponent("p.png")
        if !FileManager.default.fileExists(atPath: url.path) {
            let d = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(d, c.makeImage()!, nil)
            XCTAssertTrue(CGImageDestinationFinalize(d))
        }
        return url.path
    }

    func image(_ id: String, src: String, x: Double = 0.5, y: Double = 0.5, scale: Double, start: Double = 0, duration: Double = 4) -> Clip {
        var c = Clip(); c.id = id; c.type = .image; c.src = src; c.x = x; c.y = y; c.scale = scale; c.start = start; c.duration = duration
        return c
    }

    func project(_ layers: [[Clip]]) -> Project {
        var p = Project(); p.width = 200; p.height = 200; p.characters = []
        p.tracks = layers.enumerated().map { i, cs in var t = Track(name: "L\(i)"); t.clips = cs; return t }
        return p
    }

    func testHitsAreOrderedFrontToBackAndRespectTheBox() throws {
        let src = try png()
        // 大(200×200)・中(100×100)・小(50×50)。描画は配列の後ろほど手前 = レイヤー 2 が最前面
        let p = project([[image("big", src: src, scale: 1)], [image("mid", src: src, scale: 0.5)], [image("small", src: src, scale: 0.25)]])
        let a = RenderAssets()
        XCTAssertEqual(PreviewPicking.hits(in: p, at: CGPoint(x: 100, y: 100), time: 1, assets: a), ["small", "mid", "big"])
        XCTAssertEqual(PreviewPicking.hits(in: p, at: CGPoint(x: 140, y: 100), time: 1, assets: a), ["mid", "big"], "中の枠の内側")
        XCTAssertEqual(PreviewPicking.hits(in: p, at: CGPoint(x: 180, y: 100), time: 1, assets: a), ["big"])
        XCTAssertEqual(PreviewPicking.hits(in: p, at: CGPoint(x: 100, y: 100), time: 9, assets: a), [], "時間の外")
        XCTAssertEqual(PreviewPicking.hits(in: p, at: CGPoint(x: Double.nan, y: 1), time: 1, assets: a), [])
        XCTAssertEqual(PreviewPicking.hits(in: p, at: CGPoint(x: 400, y: 100), time: 1, assets: a), [], "キャンバスの外")
    }

    func testRotationChangesWhatIsHit() throws {
        let src = try png()
        var c = image("r", src: src, scale: 0.5)   // 100×100 を 45°
        c.rotation = 45
        let p = project([[c]])
        let a = RenderAssets()
        XCTAssertEqual(PreviewPicking.hits(in: p, at: CGPoint(x: 100, y: 100), time: 0.5, assets: a), ["r"])
        // 回転前なら (148, 148) は枠の中(角 150,150 の手前)。45° 回すと角が外へ出るので、その点は外れ、(100, 100 − 65) 付近の頂点側が当たる
        XCTAssertEqual(PreviewPicking.hits(in: p, at: CGPoint(x: 148, y: 148), time: 0.5, assets: a), [], "回して空いた角")
        XCTAssertEqual(PreviewPicking.hits(in: p, at: CGPoint(x: 100, y: 100 - 65), time: 0.5, assets: a), ["r"], "回して出てきた頂点")
    }

    func testHiddenLayersTransparentClipsAndUnpickableTypesAreSkipped() throws {
        let src = try png()
        var invisible = image("inv", src: src, scale: 1); invisible.opacity = 0
        var shape = Clip(); shape.id = "shape"; shape.type = .shape; shape.start = 0; shape.duration = 4
        var audio = Clip(); audio.id = "aud"; audio.type = .audio; audio.src = "/a.wav"; audio.start = 0; audio.duration = 4
        var p = project([[image("a", src: src, scale: 1)], [invisible, shape, audio], [image("hid", src: src, scale: 1)]])
        p.tracks[2].hidden = true
        XCTAssertEqual(PreviewPicking.hits(in: p, at: CGPoint(x: 100, y: 100), time: 1, assets: RenderAssets()), ["a"])
    }

    func testTextClipsAreHitByTheirBox() {
        var t = Clip(); t.id = "t"; t.type = .text; t.text = "あいう"; t.fontSize = 60; t.x = 0.5; t.y = 0.5; t.start = 0; t.duration = 4
        let p = project([[t]])
        XCTAssertEqual(PreviewPicking.hits(in: p, at: CGPoint(x: 100, y: 100), time: 1, assets: RenderAssets()), ["t"])
        XCTAssertEqual(PreviewPicking.hits(in: p, at: CGPoint(x: 5, y: 5), time: 1, assets: RenderAssets()), [])
    }

    func testStackListsVisibleClipsBackToFrontIncludingShapes() throws {
        let src = try png()
        var shape = Clip(); shape.id = "shape"; shape.type = .shape; shape.start = 0; shape.duration = 4
        var blur = Clip(); blur.id = "blur"; blur.type = .blur; blur.start = 0; blur.duration = 4
        var voice = Clip(); voice.id = "voice"; voice.type = .voice; voice.start = 0; voice.duration = 4
        var p = project([[image("a", src: src, scale: 1)], [shape, blur, voice], [image("b", src: src, scale: 1, start: 2)]])
        XCTAssertEqual(PreviewPicking.stack(in: p, at: 1), ["a", "shape"])
        XCTAssertEqual(PreviewPicking.stack(in: p, at: 3), ["a", "shape", "b"])
        p.tracks[1].hidden = true
        XCTAssertEqual(PreviewPicking.stack(in: p, at: 3), ["a", "b"])
    }

    func testNextCyclesFrontToBackAndWraps() {
        let ids = ["front", "mid", "back"]
        XCTAssertEqual(PreviewPicking.next(after: nil, in: ids), "front", "何も選んでいなければいちばん手前")
        XCTAssertEqual(PreviewPicking.next(after: "front", in: ids), "mid")
        XCTAssertEqual(PreviewPicking.next(after: "mid", in: ids), "back")
        XCTAssertEqual(PreviewPicking.next(after: "back", in: ids), "front")
        XCTAssertEqual(PreviewPicking.next(after: "other", in: ids), "front", "候補に無いクリップを選んでいたら手前から")
        XCTAssertNil(PreviewPicking.next(after: "x", in: []))
    }
}
