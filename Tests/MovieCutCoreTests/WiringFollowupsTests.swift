import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import MovieCutCore

/// 配線フォローアップバッチQ の Core 側テスト。
/// F-1: プラグインエフェクトが Renderer の実際の描画に効くこと / プロバイダ無しでは従来と完全一致すること。
/// F-4: MIDI 取り込みの総尺・ノート数上限ガードと、連番 PNG の欠番算出の打ち切り。
final class WiringFollowupsTests: XCTestCase {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("wiring-q-\(UUID().uuidString)")
    override func setUpWithError() throws { try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    // MARK: - 描画の道具

    private func solidPNG(r: UInt8, g: UInt8, b: UInt8, size: Int = 40) throws -> String {
        let c = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1))
        c.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let url = tmp.appendingPathComponent("solid\(r)-\(g)-\(b).png")
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, c.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url.path
    }

    private func project(path: String, effects: [Effect]) -> Project {
        var c = Clip(); c.id = "i"; c.type = .image; c.src = path; c.start = 0; c.duration = 4
        c.effects = effects
        var p = Project(); p.width = 40; p.height = 40; p.bg = "#000000"; p.characters = []
        var tr = Track(name: "L1"); tr.clips = [c]; p.tracks = [tr]
        return p
    }

    private func centerRGB(_ img: CGImage) -> [Int] {
        var d = [UInt8](repeating: 0, count: img.width * img.height * 4)
        let ctx = CGContext(data: &d, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        let i = ((img.height / 2) * img.width + img.width / 2) * 4
        return [Int(d[i]), Int(d[i + 1]), Int(d[i + 2])]
    }

    private func allPixels(_ img: CGImage) -> [UInt8] {
        var d = [UInt8](repeating: 0, count: img.width * img.height * 4)
        let ctx = CGContext(data: &d, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return d
    }

    // MARK: - F-1 Renderer 配線

    func testRendererAppliesPluginEffectToActualFrame() throws {
        let path = try solidPNG(r: 200, g: 30, b: 60)
        let fx = Effect(kind: InvertEffectPlugin.effectID, params: ["amount": 1])
        let p = project(path: path, effects: [fx])

        let plain = try XCTUnwrap(Renderer(project: p, assets: RenderAssets()).renderImage(t: 0.5))
        XCTAssertEqual(centerRGB(plain), [200, 30, 60])

        let inverted = try XCTUnwrap(Renderer(project: p, assets: RenderAssets(),
                                              pluginEffectProviders: [InvertEffectProvider()]).renderImage(t: 0.5))
        let rgb = centerRGB(inverted)
        XCTAssertEqual(rgb[0], 55, accuracy: 3)
        XCTAssertEqual(rgb[1], 225, accuracy: 3)
        XCTAssertEqual(rgb[2], 195, accuracy: 3)
    }

    func testRendererWithoutProvidersIsPixelIdenticalEvenWithPluginEffects() throws {
        // プラグイン未導入(プロバイダ空)では、プラグインエフェクト付きクリップも従来どおり「何もしない」で完全一致。
        let path = try solidPNG(r: 200, g: 30, b: 60)
        let fx = Effect(kind: InvertEffectPlugin.effectID, params: ["amount": 1])
        let withFx = project(path: path, effects: [fx])
        let noFx = project(path: path, effects: [])
        let a = try XCTUnwrap(Renderer(project: withFx, assets: RenderAssets()).renderImage(t: 0.5))
        let b = try XCTUnwrap(Renderer(project: noFx, assets: RenderAssets()).renderImage(t: 0.5))
        XCTAssertEqual(allPixels(a), allPixels(b))
        // 空のプロバイダを明示的に渡しても同じ。
        let c = try XCTUnwrap(Renderer(project: withFx, assets: RenderAssets(), pluginEffectProviders: []).renderImage(t: 0.5))
        XCTAssertEqual(allPixels(a), allPixels(c))
        // 内蔵エフェクトだけの絵も、プロバイダ有無で変わらない(プラグインは内蔵に干渉しない)。
        let builtin = project(path: path, effects: [Effect(.brightness)])
        let d = try XCTUnwrap(Renderer(project: builtin, assets: RenderAssets()).renderImage(t: 0.5))
        let e = try XCTUnwrap(Renderer(project: builtin, assets: RenderAssets(),
                                       pluginEffectProviders: [InvertEffectProvider()]).renderImage(t: 0.5))
        XCTAssertEqual(allPixels(d), allPixels(e))
    }

    func testRendererPluginEffectInsideCompoundAndAdjustment() throws {
        let path = try solidPNG(r: 200, g: 30, b: 60)
        let fx = Effect(kind: InvertEffectPlugin.effectID, params: ["amount": 1])
        // 複合クリップの中のクリップにも、子 Renderer へ引き継がれて効く。
        var inner = Clip(); inner.id = "in"; inner.type = .image; inner.src = path; inner.start = 0; inner.duration = 4
        inner.effects = [fx]
        var innerTrack = Track(name: "in"); innerTrack.clips = [inner]
        var comp = Clip(); comp.id = "comp"; comp.type = .compound; comp.start = 0; comp.duration = 4; comp.tracks = [innerTrack]
        var p = Project(); p.width = 40; p.height = 40; p.bg = "#000000"; p.characters = []
        var tr = Track(name: "L1"); tr.clips = [comp]; p.tracks = [tr]
        let img = try XCTUnwrap(Renderer(project: p, assets: RenderAssets(),
                                         pluginEffectProviders: [InvertEffectProvider()]).renderImage(t: 0.5))
        let rgb = centerRGB(img)
        XCTAssertEqual(rgb[0], 55, accuracy: 3)
        XCTAssertEqual(rgb[1], 225, accuracy: 3)

        // 調整レイヤーに付けたプラグインエフェクトも、下の絵に効く。
        var base = Clip(); base.id = "b"; base.type = .image; base.src = path; base.start = 0; base.duration = 4
        var adj = Clip(); adj.id = "a"; adj.type = .adjustment; adj.start = 0; adj.duration = 4; adj.effects = [fx]
        var p2 = Project(); p2.width = 40; p2.height = 40; p2.bg = "#000000"; p2.characters = []
        var t1 = Track(name: "L1"); t1.clips = [base]
        var t2 = Track(name: "L2"); t2.clips = [adj]
        p2.tracks = [t1, t2]
        let img2 = try XCTUnwrap(Renderer(project: p2, assets: RenderAssets(),
                                          pluginEffectProviders: [InvertEffectProvider()]).renderImage(t: 0.5))
        let rgb2 = centerRGB(img2)
        XCTAssertEqual(rgb2[0], 55, accuracy: 3)
        XCTAssertEqual(rgb2[1], 225, accuracy: 3)
    }

    // MARK: - F-4 MIDI ガード

    private func midiData(duration: Double, notes: [MidiNote] = []) -> MidiFileData {
        MidiFileData(format: 0, trackCount: 1, ticksPerQuarter: 480, smpteFramesPerSecond: nil,
                     smpteTicksPerFrame: nil, tempos: [], trackNames: [:], notes: notes, duration: duration)
    }

    func testMIDIValidateRejectsTooLongAndTooManyNotes() {
        XCTAssertThrowsError(try MidiImporter.validate(midiData(duration: MidiImporter.maxDurationSeconds + 1))) { error in
            guard case MidiError.tooLong(_, let limit) = error as! MidiError else { return XCTFail("tooLong のはず: \(error)") }
            XCTAssertEqual(limit, MidiImporter.maxDurationSeconds)
        }
        let many = (0..<(MidiImporter.maxNotes + 1)).map {
            MidiNote(track: 0, channel: 0, pitch: 60, velocity: 100, startTick: $0, endTick: $0 + 1, start: Double($0) * 0.001, duration: 0.001)
        }
        XCTAssertThrowsError(try MidiImporter.validate(midiData(duration: 10, notes: many))) { error in
            guard case MidiError.tooManyNotes(_, let limit) = error as! MidiError else { return XCTFail("tooManyNotes のはず: \(error)") }
            XCTAssertEqual(limit, MidiImporter.maxNotes)
        }
        // 通常のファイルはそのまま通る(上限ちょうども可)。
        XCTAssertNoThrow(try MidiImporter.validate(midiData(duration: MidiImporter.maxDurationSeconds)))
        XCTAssertNoThrow(try MidiImporter.validate(midiData(duration: 3.5, notes: Array(many.prefix(3)))))
    }

    private func vlq(_ v: Int) -> [UInt8] {
        var bytes: [UInt8] = [UInt8(v & 0x7f)]
        var rest = v >> 7
        while rest > 0 { bytes.insert(UInt8((rest & 0x7f) | 0x80), at: 0); rest >>= 7 }
        return bytes
    }

    func testMIDIPrepareRejectsPathologicallyLongFile() throws {
        // 480 tick = 0.5 秒(テンポ 500000)。ノートを 700 秒鳴らす SMF を作る。
        var ev: [UInt8] = []
        ev += vlq(0) + [0xff, 0x51, 0x03, 0x07, 0xa1, 0x20]   // テンポ 500000
        ev += vlq(0) + [0x90, 60, 100]
        ev += vlq(672_000) + [0x80, 60, 0]                     // 672000 tick = 700 秒
        ev += vlq(0) + [0xff, 0x2f, 0x00]
        var smf: [UInt8] = []
        smf += Array("MThd".utf8) + [0, 0, 0, 6, 0, 0, 0, 1, 0x01, 0xe0]
        smf += Array("MTrk".utf8)
        smf += [UInt8((ev.count >> 24) & 0xff), UInt8((ev.count >> 16) & 0xff), UInt8((ev.count >> 8) & 0xff), UInt8(ev.count & 0xff)]
        smf += ev
        let url = tmp.appendingPathComponent("long.mid")
        try Data(smf).write(to: url)
        let parsed = try MidiParser.parseFile(atPath: url.path)
        XCTAssertEqual(parsed.duration, 700, accuracy: 0.01)
        XCTAssertThrowsError(try MidiImporter.prepare(atPath: url.path, cacheDir: tmp.appendingPathComponent("mc"))) { error in
            guard case MidiError.tooLong = error as! MidiError else { return XCTFail("tooLong のはず: \(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("mc/rendered.wav").path),
                       "弾いたときは WAV を作らない")
    }

    func testMIDIRenderSamplesAreCappedAndNormalFileUnchanged() throws {
        // 病的に長い入力でも、確保するサンプルは上限まで(prepare を通らない直接呼び出しの防御)。
        let capped = MidiImporter.renderSamples(midiData(duration: 100_000))
        XCTAssertEqual(capped.count, MidiImporter.maxSamples)
        // 通常のファイルは従来どおり(長さ = 総尺 + 余韻、決定的)。
        let f = midiData(duration: 1.0, notes: [MidiNote(track: 0, channel: 0, pitch: 69, velocity: 100, startTick: 0, endTick: 480, start: 0, duration: 0.5)])
        let a = MidiImporter.renderSamples(f)
        XCTAssertEqual(a.count, Int(((1.0 + MidiImporter.tail) * 44100).rounded()))
        XCTAssertEqual(a, MidiImporter.renderSamples(f))
        XCTAssertGreaterThan(a.map { abs($0) }.max() ?? 0, 0)
    }

    // MARK: - F-4 連番 PNG の欠番

    func testSequenceMissingNumbersAreCappedForSparseHugeNumbers() {
        let urls = [URL(fileURLWithPath: "/x/f_000000001.png"), URL(fileURLWithPath: "/x/f_100000000.png")]
        let found = ImageSequenceDetector.detect(urls: urls)
        XCTAssertEqual(found.count, 1)
        let seq = found[0]
        XCTAssertEqual(seq.frames.map(\.number), [1, 100_000_000])
        // 欠番の列挙は上限で打ち切る(範囲全走査なら 1 億件になって固まる)。
        XCTAssertEqual(seq.missingNumbers.count, ImageSequenceDetector.missingLimit)
        XCTAssertEqual(seq.missingNumbers.first, 2)
        XCTAssertEqual(seq.missingNumbers.last, 1 + ImageSequenceDetector.missingLimit)
    }

    func testSequenceMissingNumbersNormalCaseUnchanged() {
        let urls = ["/x/f_001.png", "/x/f_003.png", "/x/f_004.png"].map { URL(fileURLWithPath: $0) }
        let seq = ImageSequenceDetector.detect(urls: urls).first
        XCTAssertEqual(seq?.missingNumbers, [2])
    }
}


// MARK: - バグ確認 第2部 C20: MIDI の総量ガードと、配置時の余韻

final class MidiDensityAndTailTests: XCTestCase {
    private func midiData(duration: Double, notes: [MidiNote]) -> MidiFileData {
        MidiFileData(format: 0, trackCount: 1, ticksPerQuarter: 480, smpteFramesPerSecond: nil,
                     smpteTicksPerFrame: nil, tempos: [], trackNames: [:], notes: notes, duration: duration)
    }
    func testValidateRejectsOverlappingLongNotes() {
        // 600 秒の音を 12 音重ねると、描画の総量上限を超え、後半が黙って消える入力になる
        let notes = (0..<12).map { _ in
            MidiNote(track: 0, channel: 0, pitch: 60, velocity: 100, startTick: 0, endTick: 115200, start: 0, duration: 600)
        }
        XCTAssertThrowsError(try MidiImporter.validate(midiData(duration: 600, notes: notes))) { error in
            XCTAssertEqual(error as? MidiError, .tooDense)
        }
    }
    func testPlacementDurationIncludesTail() {
        let f = midiData(duration: 10, notes: [])
        var p = Project()
        let ids = MidiImporter.place(wavPath: "/nonexistent/midi.wav", file: f, at: 0, in: &p)
        XCTAssertEqual(ids.count, 1)
        let clip = p.tracks.flatMap(\.clips).first { $0.id == ids[0] }
        XCTAssertEqual(clip?.duration ?? 0, 10.5, accuracy: 1e-9)
    }
    func testStepVolumeRejectsNonFiniteDb() {
        var c = Clip(); c.type = .audio; c.volume = 1
        XCTAssertFalse(AudioFxEditing.stepVolume(&c, db: .nan))
        XCTAssertEqual(c.volume, 1)
    }
}
