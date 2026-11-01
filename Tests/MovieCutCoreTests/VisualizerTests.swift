import XCTest
import CoreGraphics
@testable import MovieCutCore

/// 音声ビジュアライザ(クリップの種類 visualizer): 合成音声の大きさで棒・波が伸びる。
/// 画素で確認する(無音 = 細い線、大きい音 = 高い棒)。Renderer と同じ経路。
final class VisualizerTests: XCTestCase {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("visualizer-tests-\(UUID().uuidString)")
    override func setUpWithError() throws { try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    // 400×200 のキャンバスで、枠は中心 (200, 170)、幅 240、高さ 40(下の縁 190)
    static let W = 400, H = 200

    func project(clips: [Clip]) -> Project {
        var p = Project()
        p.width = Self.W; p.height = Self.H; p.bg = "#000000"
        var tr = Track(name: "L1"); tr.clips = clips
        p.tracks = [tr]
        return p
    }

    func vizClip(style: String? = nil, color: String? = nil, count: Int? = nil, duration: Double = 1) -> Clip {
        var c = ClipEditing.makeVisualizerClip(at: 0, project: Project())
        c.duration = duration
        c.x = 0.5; c.y = 0.85; c.w = 0.6; c.h = 0.2
        if style != nil || color != nil || count != nil { c.visualizer = Visualizer(style: style, color: color, count: count) }
        return c
    }

    func audioClip(_ path: String, duration: Double = 1) -> Clip {
        var c = Clip(); c.id = "a"; c.type = .audio; c.start = 0; c.duration = duration; c.src = path
        return c
    }

    /// 画素(RGBA、左上原点)
    struct Pixels {
        let w: Int, h: Int
        var d: [UInt8]
        func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let i = (y * w + x) * 4
            return (Int(d[i]), Int(d[i + 1]), Int(d[i + 2]))
        }
    }

    func render(_ p: Project, t: Double = 0.5) throws -> Pixels {
        let assets = RenderAssets()
        let img = try XCTUnwrap(Renderer(project: p, assets: assets).renderImage(t: t))
        var d = [UInt8](repeating: 0, count: img.width * img.height * 4)
        let c = CGContext(data: &d, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return Pixels(w: img.width, h: img.height, d: d)
    }

    /// 列 x で、棒の下の縁(y = 189、枠の下端 190 の一つ上)から上へ、背景より明るい画素が続く高さ(画素)。
    func columnHeight(_ px: Pixels, x: Int) -> Int {
        var n = 0
        var y = 189
        while y >= 0 {
            let (r, g, b) = px.rgb(x, y)
            if r + g + b < 60 { break }
            n += 1; y -= 1
        }
        return n
    }

    /// 棒 i の中心の x(枠の左 80、幅 240、本数 n)
    func barCenter(_ i: Int, count n: Int) -> Int {
        let slot = 240.0 / Double(n)
        return Int((80 + slot * (Double(i) + 0.5)).rounded())
    }

    /// 1 秒の正弦波(振幅 amp、440 Hz、24 kHz)
    func writeSine(_ name: String, amp: Float) throws -> String {
        let url = tmp.appendingPathComponent(name)
        try AudioFixture.writeSine(url, sampleRate: 24000, segments: [(1, amp)])
        return url.path
    }

    // MARK: 定義

    func testNewVisualizerClipHasDefaultsAndWritesNoVisualizerKey() throws {
        let c = ClipEditing.makeVisualizerClip(at: 2, project: Project())
        XCTAssertEqual(c.type, .visualizer)
        XCTAssertNil(c.visualizer, "見た目の既定は項目を書かない")
        XCTAssertEqual(c.visualizerOrDefault.styleOrDefault, "bars")
        XCTAssertEqual(c.visualizerOrDefault.colorOrDefault, "#ffffff")
        XCTAssertEqual(c.visualizerOrDefault.countOrDefault, 32)
        let data = try JSONEncoder().encode(c)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"type\":\"visualizer\""))
        XCTAssertFalse(text.contains("\"visualizer\":"), "既定のときは visualizer を書かない: \(text)")
    }

    func testSettingsRoundTripAndUnknownStyleFallsBackToBars() throws {
        var c = vizClip(style: "wave", color: "#ff0000", count: 8)
        let data = try JSONEncoder().encode(c)
        let back = try JSONDecoder().decode(Clip.self, from: data)
        XCTAssertEqual(back.visualizer, Visualizer(style: "wave", color: "#ff0000", count: 8))
        XCTAssertEqual(back.visualizerOrDefault.styleOrDefault, "wave")
        XCTAssertEqual(Visualizer(style: "spiral").styleOrDefault, "bars", "知らない形は棒")
        XCTAssertEqual(Visualizer(count: 1).countOrDefault, 4)
        XCTAssertEqual(Visualizer(count: 9999).countOrDefault, 128)
        c.visualizer = nil
        let plain = try JSONEncoder().encode(c)
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("\"visualizer\":"))
    }

    func testAnimationKeysForVisualizerAreFrame() {
        XCTAssertEqual(Animation.keys(for: vizClip()), ["x", "y", "w", "h"])
    }

    // MARK: 画素

    func testSilentDrawsMinimalBars() throws {
        let p = project(clips: [vizClip(color: "#ff0000", count: 8)])
        let px = try render(p)
        for i in 0..<8 {
            let h = columnHeight(px, x: barCenter(i, count: 8))
            XCTAssertLessThanOrEqual(h, 3, "無音の棒 \(i) は細い線: \(h) 画素")
            XCTAssertGreaterThanOrEqual(h, 1, "無音でも線は見える")
        }
    }

    func testLoudSoundDrawsTallBars() throws {
        let sine = try writeSine("loud.wav", amp: 0.5)
        let p = project(clips: [vizClip(color: "#ff0000", count: 8), audioClip(sine)])
        let px = try render(p)
        // 棒 0 の形は 0.94、音量は頭打ち → 高さ 0.94 × 40 ≒ 37 画素
        let h0 = columnHeight(px, x: barCenter(0, count: 8))
        XCTAssertGreaterThanOrEqual(h0, 32, "大きい音の棒は高い: \(h0) 画素")
        XCTAssertLessThanOrEqual(h0, 40, "枠の高さを超えない")
    }

    func testLoudIsTallerThanSilentAndColorIsUsed() throws {
        let sine = try writeSine("mid.wav", amp: 0.2)
        let silent = try render(project(clips: [vizClip(color: "#00ff00", count: 8)]))
        let loud = try render(project(clips: [vizClip(color: "#00ff00", count: 8), audioClip(sine)]))
        let x = barCenter(0, count: 8)
        XCTAssertGreaterThan(columnHeight(loud, x: x), columnHeight(silent, x: x) + 5)
        let (r, g, b) = loud.rgb(x, 185)
        XCTAssertGreaterThan(g, 200, "色は指定どおり: (\(r),\(g),\(b))")
        XCTAssertLessThan(r, 60)
        XCTAssertLessThan(b, 60)
    }

    func testBarCountChangesNumberOfBars() throws {
        let sine = try writeSine("count.wav", amp: 0.5)
        let px = try render(project(clips: [vizClip(color: "#ff0000", count: 4), audioClip(sine)]))
        // 4 本: 棒と棒のあいだ(隙間)は背景のまま
        let gapX = Int((80 + 60 * 1.0).rounded())   // 1 本目と 2 本目の境目
        XCTAssertLessThanOrEqual(columnHeight(px, x: gapX), 1, "隙間は塗られない")
        XCTAssertGreaterThan(columnHeight(px, x: barCenter(0, count: 4)), 30)
    }

    func testWaveStyleIsSymmetricAndGrowsWithLoudness() throws {
        let sine = try writeSine("wave.wav", amp: 0.5)
        let silent = try render(project(clips: [vizClip(style: "wave", color: "#ff0000", count: 16)]))
        let loud = try render(project(clips: [vizClip(style: "wave", color: "#ff0000", count: 16), audioClip(sine)]))
        // 中央の列で、上下に伸びる帯(中心 y = 170)
        func band(_ px: Pixels) -> Int {
            var n = 0
            for y in 0..<Self.H where px.rgb(200, y).0 > 120 && px.rgb(200, y).1 < 80 { n += 1 }
            return n
        }
        XCTAssertLessThanOrEqual(band(silent), 3, "無音は細い線")
        XCTAssertGreaterThan(band(loud), 25, "大きい音は帯が太い")
    }

    // MARK: 合成音声のエンベロープ

    func testMixEnvelopeFollowsTheMixAtTime() throws {
        let sine = try writeSine("env.wav", amp: 0.5)
        let p = project(clips: [audioClip(sine)])
        let env = try XCTUnwrap(RenderAssets().mixEnvelope(for: p))
        XCTAssertEqual(Double(env.count), 60, accuracy: 3, "1 秒 ≒ 60 点")
        // 振幅 0.5 の正弦波の RMS は 0.5 / √2 ≒ 0.354
        let mid = Double(env[30])
        XCTAssertEqual(mid, 0.354, accuracy: 0.05)
    }

    func testSilentProjectHasZeroEnvelope() throws {
        let env = RenderAssets().mixEnvelope(for: project(clips: [vizClip()]))
        if let env { XCTAssertTrue(env.allSatisfy { $0 == 0 }) }
    }

    func testMixKeyChangesOnlyWithAudio() {
        var t = Clip(); t.id = "t"; t.type = .text; t.start = 0; t.duration = 1; t.text = "a"
        let a = project(clips: [t, audioClip("/x.wav")])
        var moved = a
        moved.tracks[0].clips[0].x = 0.1
        XCTAssertEqual(RenderAssets.mixKey(a), RenderAssets.mixKey(moved), "文字だけの変更では作り直さない")
        var louder = a
        louder.tracks[0].clips[1].volume = 0.5
        XCTAssertNotEqual(RenderAssets.mixKey(a), RenderAssets.mixKey(louder), "音量の変更では作り直す")
    }
}
