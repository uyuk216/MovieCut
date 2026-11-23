import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import MovieCutCore

/// 入力形式の拡充(#4 SVG / #5 MIDI / #6 連番 PNG): 判定・パース・取り込みの土台。
final class InputFormatsTests: XCTestCase {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("input-formats-\(UUID().uuidString)")
    override func setUpWithError() throws { try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    // MARK: ヘルパー

    func solid(_ c: (UInt8, UInt8, UInt8), w: Int = 20, h: Int = 20) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: CGFloat(c.0) / 255, green: CGFloat(c.1) / 255, blue: CGFloat(c.2) / 255, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    @discardableResult
    func writePNG(_ name: String, _ c: (UInt8, UInt8, UInt8), w: Int = 20, h: Int = 20) throws -> URL {
        let url = tmp.appendingPathComponent(name)
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, solid(c, w: w, h: h), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    func pixel(_ img: CGImage, _ x: Int, _ y: Int) -> (Int, Int, Int) {
        var d = [UInt8](repeating: 0, count: img.width * img.height * 4)
        let c = CGContext(data: &d, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        let i = (y * img.width + x) * 4
        return (Int(d[i]), Int(d[i + 1]), Int(d[i + 2]))
    }

    // MARK: - SVG: 寸法のパース

    func testSVGParsesWidthHeightAndViewBox() {
        let info = SVGParser.parseInfo(#"<svg xmlns="http://www.w3.org/2000/svg" width="200" height="100" viewBox="0 0 200 100"><rect/></svg>"#)
        XCTAssertEqual(info?.width, 200)
        XCTAssertEqual(info?.height, 100)
        XCTAssertEqual(info?.viewBox, SVGViewBox(x: 0, y: 0, width: 200, height: 100))
        XCTAssertEqual(info?.intrinsicSize, CGSize(width: 200, height: 100))
    }

    func testSVGUnitsConvertToPixels() {
        // 72pt = 96px、1in = 96px、25.4mm = 96px
        let info = SVGParser.parseInfo(#"<svg width="72pt" height="1in"></svg>"#)
        XCTAssertEqual(info?.width ?? 0, 96, accuracy: 0.01)
        XCTAssertEqual(info?.height ?? 0, 96, accuracy: 0.01)
        let mm = SVGParser.parseInfo(#"<svg width="25.4mm" height="10px"></svg>"#)
        XCTAssertEqual(mm?.width ?? 0, 96, accuracy: 0.01)
        XCTAssertEqual(mm?.height, 10)
    }

    func testSVGViewBoxOnlyAndPercent() {
        let vb = SVGParser.parseInfo(#"<svg viewBox="0 0 40 20"></svg>"#)
        XCTAssertNil(vb?.width)
        XCTAssertEqual(vb?.intrinsicSize, CGSize(width: 40, height: 20))
        // % は viewBox の縦横比で補う
        let pct = SVGParser.parseInfo(#"<svg width="100%" height="50" viewBox="0 0 40 20"></svg>"#)
        XCTAssertNil(pct?.width)
        XCTAssertEqual(pct?.intrinsicSize, CGSize(width: 100, height: 50))
    }

    func testSVGSkipsPrologAndRejectsNonSVG() {
        let text = "<?xml version=\"1.0\"?>\n<!-- comment -->\n<svg width=\"10\" height=\"20\"></svg>"
        XCTAssertEqual(SVGParser.parseInfo(text)?.intrinsicSize, CGSize(width: 10, height: 20))
        XCTAssertNil(SVGParser.parseInfo("<html><body></body></html>"))
        XCTAssertNil(SVGParser.parseInfo("not xml at all"))
        XCTAssertNil(SVGParser.parseInfo(""))
    }

    func testSVGPixelSizes() {
        let big = SVGInfo(width: 4000, height: 2000)
        XCTAssertEqual(SVGImporter.defaultPixelSize(info: big), CGSize(width: 2048, height: 1024))
        let small = SVGInfo(width: 200, height: 100)
        XCTAssertEqual(SVGImporter.defaultPixelSize(info: small), CGSize(width: 200, height: 100))
        XCTAssertEqual(SVGImporter.defaultPixelSize(info: SVGInfo()), SVGImporter.fallbackSize)
        // 枠に収める(拡大あり)
        XCTAssertEqual(SVGImporter.fittedPixelSize(info: small, maxWidth: 1920, maxHeight: 1080), CGSize(width: 1920, height: 960))
        XCTAssertEqual(SVGImporter.fittedPixelSize(info: SVGInfo(), maxWidth: 800, maxHeight: 600), CGSize(width: 800, height: 600))
    }

    // MARK: - SVG: ラスタライズ(実ファイル)

    /// 左半分が赤・右半分が緑の SVG(上下反転では判定が変わらない形)。
    private var sampleSVG: String {
        ##"<svg xmlns="http://www.w3.org/2000/svg" width="200" height="100" viewBox="0 0 200 100"><rect x="0" y="0" width="100" height="100" fill="#ff0000"/><rect x="100" y="0" width="100" height="100" fill="#00ff00"/></svg>"##
    }

    func testSVGRasterizeAtRequestedResolution() throws {
        let url = tmp.appendingPathComponent("sample.svg")
        try sampleSVG.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(SVGParser.info(atPath: url.path)?.intrinsicSize, CGSize(width: 200, height: 100))
        let img = try XCTUnwrap(SVGImporter.rasterize(atPath: url.path, pixelWidth: 400, pixelHeight: 200))
        XCTAssertEqual(img.width, 400)
        XCTAssertEqual(img.height, 200)
        XCTAssertEqual(pixel(img, 10, 100).0, 255)   // 左は赤
        XCTAssertEqual(pixel(img, 390, 100).1, 255)  // 右は緑
        // 1 倍でも描ける
        let small = try XCTUnwrap(SVGImporter.rasterize(atPath: url.path, pixelWidth: 200, pixelHeight: 100))
        XCTAssertEqual(small.width, 200)
        XCTAssertNil(SVGImporter.rasterize(atPath: tmp.appendingPathComponent("none.svg").path, pixelWidth: 10, pixelHeight: 10))
    }

    func testSVGPrepareWritesLoadablePNG() throws {
        let url = tmp.appendingPathComponent("sample.svg")
        try sampleSVG.write(to: url, atomically: true, encoding: .utf8)
        let cache = tmp.appendingPathComponent("cache")
        let png = try SVGImporter.prepare(atPath: url.path, pixelWidth: 200, pixelHeight: 100, cacheDir: cache)
        let loaded = try XCTUnwrap(RenderAssets().image(at: png))
        XCTAssertEqual(loaded.width, 200)
        XCTAssertEqual(loaded.height, 100)
        // 置くと画像クリップになる
        var p = Project.new()
        let ids = SVGImporter.place(pngPath: png, at: 2, in: &p)
        XCTAssertEqual(ids.count, 1)
        let clip = try XCTUnwrap(p.allClips.first { $0.id == ids[0] })
        XCTAssertEqual(clip.type, .image)
        XCTAssertEqual(clip.src, png)
        XCTAssertEqual(clip.start, 2)
        XCTAssertEqual(clip.duration, ClipEditing.defaultMediaDuration)
    }

    func testSVGPrepareRejectsNonSVG() throws {
        let url = tmp.appendingPathComponent("fake.svg")
        try "<html></html>".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try SVGImporter.prepare(atPath: url.path, pixelWidth: 10, pixelHeight: 10, cacheDir: tmp.appendingPathComponent("c2"))) {
            XCTAssertEqual($0 as? SVGError, .notSVG)
        }
    }

    // MARK: - MIDI: パース

    private func vlq(_ v: Int) -> [UInt8] {
        var stack = [UInt8(v & 0x7f)]
        var rest = v >> 7
        while rest > 0 { stack.insert(UInt8(rest & 0x7f) | 0x80, at: 0); rest >>= 7 }
        return stack
    }
    private func be16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 0xff), UInt8(v & 0xff)] }
    private func be32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8((v >> (24 - 8 * $0)) & 0xff) } }
    private func track(_ events: [UInt8]) -> [UInt8] { Array("MTrk".utf8) + be32(events.count) + events }
    private func smf(format: Int, division: Int, tracks: [[UInt8]]) -> Data {
        var d = Array("MThd".utf8) + be32(6) + be16(format) + be16(tracks.count) + be16(division)
        for t in tracks { d += track(t) }
        return Data(d)
    }
    private func tempoEvent(delta: Int, _ us: Int) -> [UInt8] {
        vlq(delta) + [0xff, 0x51, 0x03, UInt8((us >> 16) & 0xff), UInt8((us >> 8) & 0xff), UInt8(us & 0xff)]
    }
    private func endOfTrack(delta: Int = 0) -> [UInt8] { vlq(delta) + [0xff, 0x2f, 0x00] }

    /// フォーマット 0: テンポ 120BPM、 C4(0〜480tick) → E4(480〜960tick、ランニングステータス)。
    private func sampleMIDI() -> Data {
        var ev: [UInt8] = []
        ev += tempoEvent(delta: 0, 500_000)
        ev += vlq(0) + [0x90, 60, 100]          // C4 on
        ev += vlq(480) + [0x80, 60, 0]          // C4 off
        ev += vlq(0) + [0x90, 64, 90]           // E4 on
        ev += vlq(480) + [64, 0]                // ランニングステータスで E4 off(velocity 0)
        ev += endOfTrack()
        return smf(format: 0, division: 480, tracks: [ev])
    }

    func testMIDIParsesNotesWithTempo() throws {
        let f = try MidiParser.parse(sampleMIDI())
        XCTAssertEqual(f.format, 0)
        XCTAssertEqual(f.ticksPerQuarter, 480)
        XCTAssertEqual(f.tempos, [MidiTempo(tick: 0, microsecondsPerQuarter: 500_000)])
        XCTAssertEqual(f.notes.count, 2)
        let c = f.notes[0]
        XCTAssertEqual(c.pitch, 60)
        XCTAssertEqual(c.name, "C4")
        XCTAssertEqual(c.velocity, 100)
        XCTAssertEqual(c.start, 0, accuracy: 1e-9)
        XCTAssertEqual(c.duration, 0.5, accuracy: 1e-9)   // 480tick = 4分音符 = 0.5 秒(120BPM)
        let e = f.notes[1]
        XCTAssertEqual(e.pitch, 64)
        XCTAssertEqual(e.start, 0.5, accuracy: 1e-9)
        XCTAssertEqual(e.duration, 0.5, accuracy: 1e-9)
        XCTAssertEqual(f.duration, 1.0, accuracy: 1e-9)
        XCTAssertEqual(f.pitchRange, 60...64)
    }

    func testMIDITempoChangeAffectsSeconds() throws {
        // フォーマット 1: テンポトラックで 480tick 地点から 240BPM(250000us)へ
        var tempo: [UInt8] = []
        tempo += tempoEvent(delta: 0, 500_000)
        tempo += tempoEvent(delta: 480, 250_000)
        tempo += endOfTrack()
        var notes: [UInt8] = []
        notes += vlq(0) + [0xff, 0x03, 0x05] + Array("Piano".utf8)
        notes += vlq(0) + [0x90, 69, 127]
        notes += vlq(960) + [0x80, 69, 0]
        notes += endOfTrack()
        let f = try MidiParser.parse(smf(format: 1, division: 480, tracks: [tempo, notes]))
        XCTAssertEqual(f.format, 1)
        XCTAssertEqual(f.trackNames[1], "Piano")
        XCTAssertEqual(f.notes.count, 1)
        // 0〜480tick は 0.5 秒、480〜960tick は 0.25 秒
        XCTAssertEqual(f.notes[0].duration, 0.75, accuracy: 1e-9)
        XCTAssertEqual(f.notes[0].name, "A4")
        XCTAssertEqual(f.notes[0].frequency, 440, accuracy: 1e-9)
    }

    func testMIDISMPTEAndErrors() throws {
        // SMPTE 25fps・40tick/frame: 1000tick = 1 秒
        var ev: [UInt8] = []
        ev += vlq(0) + [0x90, 60, 100]
        ev += vlq(1000) + [0x80, 60, 0]
        ev += endOfTrack()
        let division = (0xe7 << 8) | 40   // -25fps, 40 tpf
        let f = try MidiParser.parse(smf(format: 0, division: division, tracks: [ev]))
        XCTAssertTrue(f.isSMPTE)
        XCTAssertEqual(f.smpteFramesPerSecond, 25)
        XCTAssertEqual(f.notes[0].duration, 1.0, accuracy: 1e-9)

        XCTAssertThrowsError(try MidiParser.parse(Data("XXXX".utf8))) { XCTAssertEqual($0 as? MidiError, .notMIDI) }
        XCTAssertThrowsError(try MidiParser.parse(Data(sampleMIDI().prefix(20)))) { XCTAssertEqual($0 as? MidiError, .truncated) }
    }

    func testMIDIUnclosedNoteEndsAtTrackEnd() throws {
        var ev: [UInt8] = []
        ev += vlq(0) + [0x90, 72, 80]
        ev += endOfTrack(delta: 240)
        let f = try MidiParser.parse(smf(format: 0, division: 480, tracks: [ev]))
        XCTAssertEqual(f.notes.count, 1)
        XCTAssertEqual(f.notes[0].duration, 0.25, accuracy: 1e-9)
    }

    // MARK: - MIDI: 音声化と配置

    func testMIDIRenderIsDeterministicAndAudible() throws {
        let f = try MidiParser.parse(sampleMIDI())
        let a = MidiImporter.renderSamples(f)
        let b = MidiImporter.renderSamples(f)
        XCTAssertEqual(a, b)   // 同じ入力なら毎回同じ
        XCTAssertEqual(a.count, Int(((f.duration + MidiImporter.tail) * 44100).rounded()))
        let peak = a.map { abs($0) }.max() ?? 0
        XCTAssertEqual(peak, BuiltInSounds.peakLevel, accuracy: 0.001)
        let wav = MidiImporter.renderWAV(f)
        XCTAssertEqual(Array(wav.prefix(4)), Array("RIFF".utf8))
        XCTAssertEqual(wav.count, 44 + a.count * 2)
    }

    func testMIDIMarkersAndPlace() throws {
        // 和音(同じ開始の 2 音)は 1 つのマーカーにまとまる
        var ev: [UInt8] = []
        ev += tempoEvent(delta: 0, 500_000)
        ev += vlq(0) + [0x90, 60, 100]
        ev += vlq(0) + [0x90, 64, 100]
        ev += vlq(480) + [0x80, 60, 0]
        ev += vlq(0) + [0x80, 64, 0]
        ev += endOfTrack()
        let f = try MidiParser.parse(smf(format: 0, division: 480, tracks: [ev]))
        let markers = MidiImporter.noteMarkers(for: f, at: 10)
        XCTAssertEqual(markers.count, 1)
        XCTAssertEqual(markers[0].time, 10)
        XCTAssertEqual(markers[0].name, "MIDI C4 +1")

        var p = Project.new()
        let ids = MidiImporter.place(wavPath: "/tmp/x.wav", file: f, at: 3, in: &p)
        XCTAssertEqual(ids.count, 1)
        let clip = try XCTUnwrap(p.allClips.first { $0.id == ids[0] })
        XCTAssertEqual(clip.type, .audio)
        XCTAssertEqual(clip.src, "/tmp/x.wav")
        XCTAssertEqual(clip.start, 3)
        XCTAssertEqual(clip.duration, 0.5, accuracy: 1e-9)
        XCTAssertEqual(p.markers.map(\.time), [3])
    }

    func testMIDIPrepareWritesWAV() throws {
        let url = tmp.appendingPathComponent("song.mid")
        try sampleMIDI().write(to: url)
        let (wav, f) = try MidiImporter.prepare(atPath: url.path, cacheDir: tmp.appendingPathComponent("mcache"))
        XCTAssertEqual(f.notes.count, 2)
        let data = try Data(contentsOf: URL(fileURLWithPath: wav))
        XCTAssertEqual(Array(data.prefix(4)), Array("RIFF".utf8))
        XCTAssertTrue(MidiImporter.isMIDI(path: "a.MID"))
        XCTAssertTrue(MidiImporter.isMIDI(path: "a.midi"))
        XCTAssertFalse(MidiImporter.isMIDI(path: "a.mp3"))
    }

    // MARK: - 連番 PNG: 名前の分解と検出

    func testSequenceParseFileName() {
        let a = ImageSequenceDetector.parseFileName("frame_0001.png")
        XCTAssertEqual(a, SequenceFileName(prefix: "frame_", suffix: "", number: 1, digits: 4, ext: "png"))
        let b = ImageSequenceDetector.parseFileName("img10.JPG")
        XCTAssertEqual(b?.number, 10)
        XCTAssertEqual(b?.digits, 2)
        XCTAssertEqual(b?.ext, "jpg")
        let c = ImageSequenceDetector.parseFileName("a1b2.png")
        XCTAssertEqual(c?.prefix, "a1b")
        XCTAssertEqual(c?.number, 2)
        XCTAssertNil(ImageSequenceDetector.parseFileName("photo.png"))
    }

    func testSequenceDetectSortsAndFindsGaps() {
        let dir = tmp.path
        let urls = ["frame_0004.png", "frame_0001.png", "frame_0002.png", "other_01.png", "other_02.png", "photo.png", "frame_0002.jpg"]
            .map { URL(fileURLWithPath: (dir as NSString).appendingPathComponent($0)) }
        let found = ImageSequenceDetector.detect(urls: urls)
        XCTAssertEqual(found.count, 2)
        let seq = found[0]
        XCTAssertEqual(seq.prefix, "frame_")
        XCTAssertEqual(seq.frames.map(\.number), [1, 2, 4])
        XCTAssertEqual(seq.missingNumbers, [3])
        XCTAssertEqual(seq.frameCount, 3)
        XCTAssertEqual(found[1].prefix, "other_")
        // 1 枚だけでは連番にならない
        XCTAssertTrue(ImageSequenceDetector.detect(urls: [URL(fileURLWithPath: "/x/f_01.png")]).isEmpty)
        // 番号の重なりは連番にしない
        let dup = [URL(fileURLWithPath: "/x/f_01.png"), URL(fileURLWithPath: "/x/f_01.png")]
        XCTAssertTrue(ImageSequenceDetector.detect(urls: dup).isEmpty)
        // singleSequence: 全コマそろった選択だけ
        let three = ["f_01.png", "f_02.png", "f_03.png"].map { URL(fileURLWithPath: "/x/\($0)") }
        XCTAssertEqual(ImageSequenceDetector.singleSequence(urls: three)?.frameCount, 3)
        XCTAssertNil(ImageSequenceDetector.singleSequence(urls: three + [URL(fileURLWithPath: "/x/photo.png")]))
    }

    func testSequenceFPSClampAndDuration() {
        XCTAssertEqual(ImageSequence.validFPS(0), 1)
        XCTAssertEqual(ImageSequence.validFPS(1000), 60)
        XCTAssertEqual(ImageSequence.validFPS(.nan), ImageSequence.defaultFPS)
        let seq = ImageSequence(directory: "/x", prefix: "f_", suffix: "", ext: "png", digits: 2,
                                frames: (1...48).map { ImageSequence.Frame(path: "/x/f_\($0).png", number: $0) }, missingNumbers: [])
        XCTAssertEqual(seq.duration(fps: 24), 2, accuracy: 1e-9)
    }

    // MARK: - 連番 PNG: APNG 化と再生

    func testSequenceWriteAPNGAndPlaybackFrames() throws {
        let colors: [(UInt8, UInt8, UInt8)] = [(255, 0, 0), (0, 255, 0), (0, 0, 255)]
        var urls: [URL] = []
        for (i, c) in colors.enumerated() { urls.append(try writePNG("frame_000\(i + 1).png", c)) }
        let seq = try XCTUnwrap(ImageSequenceDetector.singleSequence(urls: urls))
        XCTAssertEqual(seq.missingNumbers, [])

        let apng = tmp.appendingPathComponent("out/sequence.png")
        try ImageSequenceImporter.writeAPNG(sequence: seq, fps: 10, to: apng)
        // 既存のアニメーション読み取りで 3 コマ・0.1 秒間隔として読める
        let timing = try XCTUnwrap(AnimatedImage.timing(atPath: apng.path))
        XCTAssertEqual(timing.frameCount, 3)
        for d in timing.delays { XCTAssertEqual(d, 0.1, accuracy: 0.01) }
        // コマの選択: 0 秒→赤、0.15 秒→緑、0.25 秒→青
        let assets = RenderAssets()
        let f0 = try XCTUnwrap(assets.animatedImage(at: apng.path, elapsed: 0))
        XCTAssertEqual(pixel(f0, 10, 10).0, 255)
        let f1 = try XCTUnwrap(assets.animatedImage(at: apng.path, elapsed: 0.15))
        XCTAssertEqual(pixel(f1, 10, 10).1, 255)
        let f2 = try XCTUnwrap(assets.animatedImage(at: apng.path, elapsed: 0.25))
        XCTAssertEqual(pixel(f2, 10, 10).2, 255)

        // クリップ化: 印と長さ(3 コマ ÷ 10fps = 0.3 秒)
        var p = Project.new()
        let ids = ImageSequenceImporter.place(apngPath: apng.path, sequence: seq, fps: 10, at: 1, in: &p)
        let clip = try XCTUnwrap(p.allClips.first { $0.id == ids[0] })
        XCTAssertEqual(clip.type, .image)
        XCTAssertEqual(clip.playsAnimation, true)
        XCTAssertEqual(clip.duration, 0.3, accuracy: 1e-9)
        XCTAssertEqual(clip.start, 1)

        // 描画でもコマが進む(レンダラー経由)
        var proj = Project.new()
        proj.width = 20; proj.height = 20
        _ = ImageSequenceImporter.place(apngPath: apng.path, sequence: seq, fps: 10, at: 0, in: &proj)
        let renderer = Renderer(project: proj, assets: RenderAssets())
        let at0 = try XCTUnwrap(renderer.renderImage(t: 0))
        XCTAssertEqual(pixel(at0, 10, 10).0, 255)
        let at1 = try XCTUnwrap(renderer.renderImage(t: 0.15))
        XCTAssertEqual(pixel(at1, 10, 10).1, 255)
    }

    func testSequencePrepareReusesCache() throws {
        var urls: [URL] = []
        for i in 1...3 { urls.append(try writePNG("s_\(i).png", (10, 20, 30))) }
        let seq = try XCTUnwrap(ImageSequenceDetector.singleSequence(urls: urls))
        let cache = tmp.appendingPathComponent("scache")
        let path = try ImageSequenceImporter.prepare(sequence: seq, fps: 24, cacheDir: cache)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertEqual(try ImageSequenceImporter.prepare(sequence: seq, fps: 24, cacheDir: cache), path)
    }

    // MARK: - 既存の挙動を変えないこと

    func testExistingMediaKindsUnchanged() {
        // 既存の対応拡張子に svg / mid は足さない(取り込みは専用経路で変換してから置く)
        XCTAssertFalse(ClipEditing.mediaExtensions.contains("svg"))
        XCTAssertFalse(ClipEditing.mediaExtensions.contains("mid"))
        XCTAssertFalse(ClipEditing.mediaExtensions.contains("midi"))
        XCTAssertFalse(ClipEditing.isSupportedMedia(path: "a.svg"))
        XCTAssertEqual(ClipEditing.kindOf(path: "a.png"), .image)
        XCTAssertTrue(SVGImporter.isSVG(path: "a.SVG"))
        // playsAnimation は付けたときだけファイルに書かれる
        var plain = Clip()
        plain.type = .image
        XCTAssertNil(plain.playsAnimation)
        let data = try! JSONEncoder().encode(plain)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("playsAnimation"))
        var anim = plain
        anim.playsAnimation = true
        let data2 = try! JSONEncoder().encode(anim)
        XCTAssertTrue(String(decoding: data2, as: UTF8.self).contains("\"playsAnimation\":true"))
        let back = try! JSONDecoder().decode(Clip.self, from: data2)
        XCTAssertEqual(back.playsAnimation, true)
        let backPlain = try! JSONDecoder().decode(Clip.self, from: data)
        XCTAssertNil(backPlain.playsAnimation)
    }
}


// MARK: - バグ確認 第2部 C20: 宣言より短い MIDI トラックは切れている

final class MidiTruncatedTrackTests: XCTestCase {
    func testDeclaredLengthBeyondDataIsTruncated() {
        var d: [UInt8] = Array("MThd".utf8) + [0, 0, 0, 6, 0, 0, 0, 1, 0x01, 0xE0]
        d += Array("MTrk".utf8) + [0, 0, 0, 10]        // 10 バイトあると宣言
        d += [0x00, 0xFF, 0x2F, 0x00]                   // 実際は 4 バイトだけ
        XCTAssertThrowsError(try MidiParser.parse(Data(d))) {
            XCTAssertEqual($0 as? MidiError, .truncated)
        }
    }
}
