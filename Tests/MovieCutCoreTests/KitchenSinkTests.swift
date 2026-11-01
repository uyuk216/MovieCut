import XCTest
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import MovieCutCore

/// 全部入りのプロジェクト(統合確認)。ほぼ全種類のクリップ・エフェクト・音声処理・マーカー・書き出し範囲を 1 つに入れ、
/// (a) Renderer で 5 コマ描けること、(c) 保存・読み直し・保存で同じバイト列になること、を速く確かめる。
/// 実際の MP4 書き出しは `moviecut-cli export` で行う(手順は docs/Codex引き継ぎ.md)。
/// 環境変数 `MC_KITCHEN_SINK_DIR` を指定すると、そのフォルダに `kitchen-sink.mcpjc` と素材を残す(CLI の書き出し用)。
final class KitchenSinkTests: XCTestCase {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("kitchen-sink-\(UUID().uuidString)")
    /// 素材(PNG・動画・LUT)の置き場。`kitchenSink(dir:)` が決める。
    var assetDir: URL = FileManager.default.temporaryDirectory

    override func setUpWithError() throws { try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    // MARK: 素材の作成

    /// 単色と図形を描いた PNG を作る。
    func writePNG(_ name: String, w: Int, h: Int, draw: (CGContext) -> Void) throws -> String {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        draw(ctx)
        let img = try XCTUnwrap(ctx.makeImage())
        let url = assetDir.appendingPathComponent(name)
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, img, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url.path
    }

    func fill(_ c: CGContext, _ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ rect: CGRect? = nil) {
        c.setFillColor(red: r, green: g, blue: b, alpha: 1)
        c.fill(rect ?? CGRect(x: 0, y: 0, width: c.width, height: c.height))
    }

    /// 1 コマごとに明るさが変わる動画(コマ番号を灰色の濃さで持つ)。速度ランプとコマ補間の確認用。
    func makeRampVideo(frames: Int, fps: Int, size: (Int, Int)) async throws -> URL {
        let url = assetDir.appendingPathComponent("ramp.mp4")
        try? FileManager.default.removeItem(at: url)
        let w = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: size.0, AVVideoHeightKey: size.1,
        ])
        let ad = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: size.0, kCVPixelBufferHeightKey as String: size.1,
        ])
        w.add(input)
        XCTAssertTrue(w.startWriting())
        w.startSession(atSourceTime: .zero)
        for i in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, ad.pixelBufferPool!, &pb)
            let buf = try XCTUnwrap(pb)
            CVPixelBufferLockBaseAddress(buf, [])
            let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
            let bpr = CVPixelBufferGetBytesPerRow(buf)
            let v = UInt8(min(255, 20 + i * 200 / max(1, frames - 1)))
            for y in 0..<size.1 { for x in 0..<size.0 {
                let o = y * bpr + x * 4
                base[o] = v; base[o + 1] = v; base[o + 2] = v; base[o + 3] = 255
            } }
            CVPixelBufferUnlockBaseAddress(buf, [])
            XCTAssertTrue(ad.append(buf, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps))))
        }
        input.markAsFinished()
        await w.finishWriting()
        XCTAssertEqual(w.status, .completed)
        return url
    }

    /// `.cube`(2 段のアイデンティティ)。LUT の読み込みを通すため。
    func writeCube() throws -> String {
        var s = "TITLE \"identity\"\nLUT_3D_SIZE 2\n"
        for b in 0..<2 { for g in 0..<2 { for r in 0..<2 { s += "\(r) \(g) \(b)\n" } } }
        let url = assetDir.appendingPathComponent("identity.cube")
        try s.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    // MARK: 全部入りのプロジェクト

    /// 10 秒の全部入り。書き出し範囲は 1〜9 秒。
    func kitchenSink(dir: URL) async throws -> Project {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        assetDir = dir
        var p = Project.new()
        p.width = 1920; p.height = 1080; p.fps = 30
        p.bg = "#102030"

        // キャラクター: 口・まばたき・表情の画像を持たせる
        let mouthClosed = try writePNG("reimu-closed.png", w: 200, h: 200) { fill($0, 0.9, 0.3, 0.3) }
        let mouthOpen = try writePNG("reimu-open.png", w: 200, h: 200) { fill($0, 0.6, 0.1, 0.1) }
        let blink = try writePNG("reimu-blink.png", w: 200, h: 200) { fill($0, 0.8, 0.5, 0.5) }
        let smile = try writePNG("reimu-smile.png", w: 200, h: 200) { fill($0, 1, 0.8, 0.2) }
        let angry = try writePNG("reimu-angry.png", w: 200, h: 200) { fill($0, 0.2, 0.2, 0.9) }
        p.characters = Character.defaults()
        p.characters[0].imgClosed = mouthClosed
        p.characters[0].imgOpen = mouthOpen
        p.characters[0].imgBlink = blink
        p.characters[0].expressions = ["笑顔": smile, "怒り": angry]
        p.characters[0].bounce = true
        p.characters[2].imgClosed = mouthClosed
        p.characters[2].imgOpen = mouthOpen

        // 声: 表情タグ・口パク・まばたきのある 4 行。音程変更と雑音除去、ダッキングの対象の BGM も置く。
        p.tracks = [Track(name: "声")]
        let voice = ToneVoiceProvider(durations: [1.7, 1.6], frequencies: [220, 330])
        let voiceClips = try await ScriptTimeline.add(lines: [
            "霊夢: [笑顔]ゆっくりしていってね",
            "ずんだもん: [怒り]ずんだもんなのだ",
            "霊夢: [まばたき]つぎのせりふ",
            "霊夢: 最後の行",
        ], to: &p, voice: voice, directory: dir, selectedCharId: p.characters[0].id)
        XCTAssertFalse(voiceClips.isEmpty)
        for i in p.tracks[0].clips.indices {
            p.tracks[0].clips[i].audioFx = AudioFx(eq: AudioFx.EQ(low: 2, mid: 0, high: -2), denoise: 0.5, pitch: 2)
        }
        let bgmSrc = try XCTUnwrap(voiceClips.first?.src)
        var bgm = Clip()
        bgm.type = .audio; bgm.start = 0; bgm.duration = 10; bgm.src = bgmSrc; bgm.srcDuration = 10
        bgm.volume = 0.5
        var duck = Duck(); duck.enabled = true; duck.amount = -12; duck.attack = 0.15; duck.release = 0.5
        bgm.duck = duck
        var bgmTrack = Track(name: "BGM")
        bgmTrack.clips = [bgm]

        // 映像: 速度ランプ + コマ補間、顔ぼかし、クロマキー + LUT、マスク付きの静止画
        let rampURL = try await makeRampVideo(frames: 60, fps: 30, size: (320, 180))
        var ramp = Clip()
        ramp.type = .video; ramp.start = 0; ramp.duration = 4; ramp.src = rampURL.path; ramp.srcDuration = 2
        ramp.x = 0.25; ramp.y = 0.3; ramp.scale = 1; ramp.w = nil; ramp.h = nil
        ramp.speedRamp = [SpeedKey(t: 0, v: 1), SpeedKey(t: 2, v: 0.25), SpeedKey(t: 4, v: 1)]
        ramp.frameBlend = true
        ramp.effects = [Effect(.faceBlur)]

        let green = try writePNG("greenscreen.png", w: 320, h: 180) { c in
            fill(c, 0, 1, 0)
            fill(c, 1, 0, 0, CGRect(x: 100, y: 50, width: 120, height: 80))
        }
        var key = Clip()
        key.type = .image; key.start = 0; key.duration = 6; key.src = green
        key.x = 0.75; key.y = 0.3; key.scale = 1.2
        var chroma = Effect(.chromaKey); chroma.color = "#00ff00"
        var lut = Effect(.lut); lut.path = try writeCube()
        key.effects = [chroma, lut]

        var masked = Clip()
        masked.type = .image; masked.start = 2; masked.duration = 5
        masked.src = try writePNG("mask-src.png", w: 320, h: 180) { fill($0, 0.2, 0.7, 0.9) }
        masked.x = 0.5; masked.y = 0.7; masked.w = 0.3; masked.h = 0.3
        masked.mask = ClipMask(shape: "ellipse", x: 0.25, y: 0.25, w: 0.5, h: 0.5, feather: 0.1, invert: false)

        var videoTrack = Track(name: "映像")
        videoTrack.clips = [ramp, key, masked]

        // 図形・スタンプ・ビジュアライザ
        var star = Clip()
        star.type = .shape; star.start = 1; star.duration = 4; star.x = 0.2; star.y = 0.2; star.w = 0.2; star.h = 0.2
        var fig = Figure(); fig.kind = FigureKind.star.rawValue; fig.fill = "#ffd84f"; fig.stroke = "#000000"; fig.strokeWidth = 4
        star.figure = fig
        var arrow = Clip()
        arrow.type = .shape; arrow.start = 3; arrow.duration = 3; arrow.x = 0.8; arrow.y = 0.8; arrow.w = 0.3; arrow.h = 0.1
        var afig = Figure(); afig.kind = FigureKind.arrow.rawValue; afig.stroke = "#ff5c5c"; afig.strokeWidth = 10
        arrow.figure = afig
        let stamp = ClipEditing.makeStampClip("🎉", at: 5)
        var viz = Clip()
        viz.type = .visualizer; viz.start = 0; viz.duration = 10; viz.x = 0.5; viz.y = 0.9; viz.w = 0.6; viz.h = 0.1
        viz.visualizer = Visualizer(style: "wave", color: "#7ac943", count: 32)
        var shapesTrack = Track(name: "図形")
        shapesTrack.clips = [star, arrow, stamp, viz]

        // 文字: 縁・影・箱・グラデ・カラオケ・カウンター・スクロール・吹き出し
        func text(_ s: String, start: Double, dur: Double, x: Double, y: Double) -> Clip {
            var c = Clip(); c.type = .text; c.text = s; c.start = start; c.duration = dur; c.x = x; c.y = y; c.fontSize = 72
            c.color = "#ffffff"; c.outline = "#000000"; c.opacity = 1
            return c
        }
        var styled = text("装飾テキスト", start: 0, dur: 3, x: 0.5, y: 0.15)
        var ts = TextStyle()
        ts.shadow = TextStyle.Shadow(); ts.box = TextStyle.Box(); ts.gradient = TextStyle.Gradient()
        styled.textStyle = ts
        var karaoke = text("カラオケ字幕です", start: 3, dur: 3, x: 0.5, y: 0.35)
        var kts = TextStyle(); kts.highlight = Highlight(color: "#ffd84f", mode: "word", times: nil)
        karaoke.textStyle = kts
        var counter = text("0", start: 1, dur: 4, x: 0.15, y: 0.5)
        counter.counter = TextCounter(from: 0, to: 100, format: TextCounter.defaultFormat)
        var scroll = text("スクロールする文字", start: 6, dur: 3, x: 0.5, y: 0.5)
        scroll.textAnim = TextAnim(kind: "scrollUp", duration: 2, speed: nil)
        var bubble = text("吹き出し", start: 4, dur: 3, x: 0.7, y: 0.45)
        bubble.bubble = Bubble()
        var textTrack = Track(name: "文字")
        textTrack.clips = [styled, karaoke, counter, scroll, bubble]

        // 調整レイヤー(下の全部にエフェクト)
        var adj = Clip()
        adj.type = .adjustment; adj.start = 0; adj.duration = 10
        adj.effects = [Effect(.vignette), Effect(.contrast)]
        var adjTrack = Track(name: "調整")
        adjTrack.clips = [adj]

        // 複合クリップ: 中に 2 つのクリップ(文字と図形)
        var inner1 = text("複合の中", start: 0, dur: 3, x: 0.5, y: 0.5)
        inner1.start = 0
        var inner2 = Clip()
        inner2.type = .shape; inner2.start = 0; inner2.duration = 3; inner2.x = 0.5; inner2.y = 0.7; inner2.w = 0.2; inner2.h = 0.2
        var ifig = Figure(); ifig.kind = FigureKind.ellipse.rawValue; ifig.fill = "#4f8cff"; inner2.figure = ifig
        var innerTrack = Track(name: "中")
        innerTrack.clips = [inner1, inner2]
        var compound = Clip()
        compound.type = .compound; compound.start = 5; compound.duration = 3; compound.offset = 0
        compound.tracks = [innerTrack]
        var compTrack = Track(name: "複合")
        compTrack.clips = [compound]

        p.tracks.append(bgmTrack)
        p.tracks.append(videoTrack)
        p.tracks.append(shapesTrack)
        p.tracks.append(textTrack)
        p.tracks.append(adjTrack)
        p.tracks.append(compTrack)

        // マーカー(色つき)と書き出し範囲
        var m1 = Marker(time: 1, name: "開始"); m1.color = MarkerColor.red.rawValue
        var m2 = Marker(time: 5, name: "山場"); m2.color = MarkerColor.purple.rawValue
        p.markers = [m1, m2]
        p.rangeIn = 1
        p.rangeOut = 9
        return p
    }

    // MARK: テスト

    struct Pixels {
        let w: Int, h: Int
        var d: [UInt8]
        func lum(_ x: Int, _ y: Int) -> Int { let i = (y * w + x) * 4; return (Int(d[i]) + Int(d[i + 1]) + Int(d[i + 2])) / 3 }
    }

    func pixels(_ img: CGImage) -> Pixels {
        var d = [UInt8](repeating: 0, count: img.width * img.height * 4)
        let c = CGContext(data: &d, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return Pixels(w: img.width, h: img.height, d: d)
    }

    /// (a) 5 コマを Renderer で描く。落ちない・正しい大きさ・真っ黒でない・隣り合うコマが同じでない(動いているのに同じになっていないか)。
    func testRendersFiveFramesWithCorrectSizeAndContent() async throws {
        let p = try await kitchenSink(dir: tmp)
        let renderer = Renderer(project: p, assets: RenderAssets())
        var hashes: [Int] = []
        var means: [Double] = []
        for t in [0.5, 2.5, 4.5, 6.5, 8.5] {
            let img = try XCTUnwrap(renderer.renderImage(t: t), "t=\(t) で描けませんでした")
            XCTAssertEqual(img.width, 1920); XCTAssertEqual(img.height, 1080)
            let px = pixels(img)
            var sum = 0, nonzero = 0, h = 5381
            for y in stride(from: 0, to: px.h, by: 4) { for x in stride(from: 0, to: px.w, by: 4) {
                let l = px.lum(x, y); sum += l; if l > 8 { nonzero += 1 }
                h = (h &* 33) ^ l
            } }
            let samples = (px.h / 4) * (px.w / 4)
            let mean = Double(sum) / Double(samples)
            means.append(mean)
            XCTAssertGreaterThan(Double(nonzero) / Double(samples), 0.05, "t=\(t) がほぼ黒(描画されていない可能性)")
            hashes.append(h)
        }
        XCTAssertEqual(Set(hashes).count, hashes.count, "5 コマのうち同じ絵がある(動きが描かれていない可能性): means=\(means)")
    }

    /// (c) 保存 → 読み直し → 保存 で、バイト列が同じ。
    /// 既定値(例: EQ の mid = 0)は書かない方針なので、メモリ上の値と読み直した値は厳密には一致しない。
    /// そこで 1 回目の保存で正規化してから、2 回目以降を比べる。
    func testSaveReloadSaveRoundTripIsByteIdentical() async throws {
        let p = try await kitchenSink(dir: tmp)
        let a = tmp.appendingPathComponent("a.mcpjc")
        let b = tmp.appendingPathComponent("b.mcpjc")
        try p.save(to: a)
        let reloaded = try Project.load(from: a)
        try reloaded.save(to: b)
        XCTAssertEqual(try Data(contentsOf: a), try Data(contentsOf: b), "保存し直したらバイト列が変わった")
        XCTAssertEqual(try Project.load(from: b), reloaded, "2 回目の読み直しが 1 回目と違う")
        XCTAssertEqual(reloaded.allClips.count, p.allClips.count)
        XCTAssertEqual(reloaded.markers.map(\.color), ["red", "purple"])
        XCTAssertEqual(reloaded.exportRange, ExportRange(start: 1, end: 9))
    }

    /// 動画の終わり(素材の長さ)を越えた時刻は、書き出しと同じく最後のコマを出し続ける(プレビュー・`frame` も)。
    /// 以前は AVAssetImageGenerator が失敗して黒になり、さらにその動画を「見つからない素材」として記録していた。
    func testVideoPastSourceEndHoldsLastFrameInPreview() async throws {
        let url = try await makeRampVideo(frames: 60, fps: 30, size: (320, 180))
        var c = Clip()
        c.type = .video; c.start = 0; c.duration = 4; c.src = url.path; c.srcDuration = 2
        c.x = 0.5; c.y = 0.5; c.scale = 1
        var tr = Track(name: "映像"); tr.clips = [c]
        var p = Project()
        p.width = 320; p.height = 180; p.fps = 30; p.bg = "#000000"; p.characters = []; p.tracks = [tr]
        let renderer = Renderer(project: p, assets: RenderAssets())
        let inside = pixels(try XCTUnwrap(renderer.renderImage(t: 1.0)))
        let past = try XCTUnwrap(renderer.renderImage(t: 3.0), "素材の終わりを越えた時刻が描けない(黒になる)")
        let pastPx = pixels(past)
        XCTAssertGreaterThan(pastPx.lum(160, 90), inside.lum(160, 90) + 40, "最後のコマ(明るい)が出ていない: past=\(pastPx.lum(160, 90)) inside=\(inside.lum(160, 90))")
        // 越えた後も、素材の内側の時刻が読める(素材が missing 扱いになっていない)
        let again = pixels(try XCTUnwrap(renderer.renderImage(t: 0.5), "越えた後に素材が読めなくなった"))
        XCTAssertLessThan(again.lum(160, 90), inside.lum(160, 90), "時刻 0.5 は時刻 1.0 より暗いはず")
    }

    /// 速度ランプ(1 → 0.25 → 1、コマ補間あり)の中で、素材の明るさは単調に増え、素材の終わり(約 3.4 秒以降)で止まる。
    /// 1 コマずつ違うはずの所が同じ絵になっていないか(動いているのに止まっていないか)も見る。
    func testSpeedRampIsMonotonicAndFreezesAtSourceEnd() async throws {
        let url = try await makeRampVideo(frames: 60, fps: 30, size: (320, 180))
        var c = Clip()
        c.type = .video; c.start = 0; c.duration = 4; c.src = url.path; c.srcDuration = 2
        c.x = 0.5; c.y = 0.5; c.scale = 1
        c.speedRamp = [SpeedKey(t: 0, v: 1), SpeedKey(t: 2, v: 0.25), SpeedKey(t: 4, v: 1)]
        c.frameBlend = true
        var tr = Track(name: "映像"); tr.clips = [c]
        var p = Project()
        p.width = 320; p.height = 180; p.fps = 30; p.bg = "#000000"; p.characters = []; p.tracks = [tr]
        let renderer = Renderer(project: p, assets: RenderAssets())
        func mean(_ t: Double) throws -> Double {
            let px = pixels(try XCTUnwrap(renderer.renderImage(t: t), "t=\(t) が描けない"))
            var sum = 0
            for y in stride(from: 0, to: px.h, by: 2) { for x in stride(from: 0, to: px.w, by: 2) { sum += px.lum(x, y) } }
            return Double(sum) / Double((px.h / 2) * (px.w / 2))
        }
        let times = [0.2, 0.6, 1.0, 1.4, 1.8, 2.2, 2.6, 3.0]
        let means = try times.map { try mean($0) }
        for i in 1..<means.count {
            XCTAssertGreaterThanOrEqual(means[i], means[i - 1] - 0.5, "明るさが逆戻り: t=\(times[i]) means=\(means)")
        }
        XCTAssertGreaterThan(means[means.count - 1] - means[0], 20, "動いているのに明るさが変わらない: \(means)")
        // 素材の終わりを越えたあとは同じ絵(止まる)
        let a = try mean(3.6), b = try mean(3.9)
        XCTAssertEqual(a, b, accuracy: 0.5, "素材の終わり以降は止まるはず: 3.6=\(a) 3.9=\(b)")
    }

    /// CLI の実書き出し用に、環境変数が指定されたときだけ保存する(通常の `swift test` では何もしない)。
    func testWriteKitchenSinkForCLIWhenRequested() async throws {
        guard let dir = ProcessInfo.processInfo.environment["MC_KITCHEN_SINK_DIR"] else { throw XCTSkip("MC_KITCHEN_SINK_DIR 未指定") }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        let p = try await kitchenSink(dir: url)
        try p.save(to: url.appendingPathComponent("kitchen-sink.mcpjc"))
    }
}
