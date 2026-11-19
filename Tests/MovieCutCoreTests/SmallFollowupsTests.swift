import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import MovieCutCore

/// バッチV 小規模フォローアップの Core 側テスト。
/// F-5: PngWavExporter の後片付けが、WAV 工程に未着手の段階では既存 WAV を巻き込まないこと /
///      その回に WAV を作った後のキャンセルでは、その回の WAV ごと消えること。
/// F-7: プラグインエフェクトが WebVideo の中間描画・連番画像・静止画・サムネイル・
///      サムネイル候補・絵コンテの各経路でも効くこと / プロバイダ空では従来と完全一致すること。
final class SmallFollowupsTests: XCTestCase {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("smallfix-v-\(UUID().uuidString)")
    override func setUpWithError() throws { try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    struct NoFaces: FaceDetecting { func faces(in image: CGImage) -> [CGRect] { [] } }

    // MARK: - 描画の道具(WiringFollowupsTests と同じ流儀)

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
        var p = Project(); p.width = 40; p.height = 40; p.fps = 10; p.bg = "#000000"; p.characters = []
        var tr = Track(name: "L1"); tr.clips = [c]; p.tracks = [tr]
        return p
    }

    private func loadImage(_ url: URL) throws -> CGImage {
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil), "画像として開けない: \(url.lastPathComponent)")
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
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

    private func assertInverted(_ rgb: [Int], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(rgb[0], 55, accuracy: 3, file: file, line: line)
        XCTAssertEqual(rgb[1], 225, accuracy: 3, file: file, line: line)
        XCTAssertEqual(rgb[2], 195, accuracy: 3, file: file, line: line)
    }

    private var invertProject: Project {
        get throws {
            let path = try solidPNG(r: 200, g: 30, b: 60)
            return project(path: path, effects: [Effect(kind: InvertEffectPlugin.effectID, params: ["amount": 1])])
        }
    }

    // MARK: - F-5: 既存 WAV の保護

    func testPngWavCancelBeforeWavStageKeepsExistingWav() async throws {
        // 前回の書き出し結果に見立てた既存 WAV(中身は目印バイト列)。
        let dir = tmp.appendingPathComponent("out-keep")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let wavURL = dir.appendingPathComponent("frame.wav")
        let sentinel = Data("PREVIOUS-WAV".utf8)
        try sentinel.write(to: wavURL)

        // 長いプロジェクトを即キャンセルする(WAV 工程には届かない)。
        var p = Project.new()
        p.width = 640; p.height = 360; p.fps = 60
        var t = Clip(); t.type = .text; t.text = "長い"; t.start = 0; t.duration = 10; t.fontSize = 60; t.x = 0.5; t.y = 0.5
        p.tracks[4].clips.append(t)
        let task = Task { try await PngWavExporter.export(project: p, options: PngWavOptions(base: "frame"), to: dir) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("キャンセルされたら CancellationError のはず")
        } catch is CancellationError {}
        XCTAssertEqual(try Data(contentsOf: wavURL), sentinel, "WAV 未作成段階のキャンセルで既存 WAV を消さない")
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        XCTAssertEqual(leftovers.filter { $0.hasSuffix(".png") }, [], "その回に書いた PNG は消える")
        XCTAssertEqual(leftovers.filter { $0.hasSuffix(".part") }, [], ".part も残らない")
    }

    func testPngWavCancelAfterWavCreatedRemovesThatRunsWav() async throws {
        // 小さい無音プロジェクト。進み具合 1.0(= WAV を置き換えた直後)でキャンセルする。
        var p = Project.new()
        p.width = 160; p.height = 90; p.fps = 10; p.bg = "#FF0000"
        var t = Clip(); t.type = .text; t.text = "PNG"; t.start = 0; t.duration = 0.5; t.fontSize = 40; t.x = 0.5; t.y = 0.5
        p.tracks[4].clips.append(t)
        let dir = tmp.appendingPathComponent("out-drop")

        final class Box: @unchecked Sendable { var task: Task<PngWavExporter.Result, Error>? }
        let box = Box()
        let task = Task {
            try await PngWavExporter.export(project: p, options: PngWavOptions(base: "frame"), to: dir) { v in
                if v >= 1.0 { box.task?.cancel() }
            }
        }
        box.task = task
        do {
            _ = try await task.value
            XCTFail("WAV 作成直後のキャンセルでは CancellationError のはず")
        } catch is CancellationError {}
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        XCTAssertEqual(leftovers.filter { $0.hasSuffix(".png") || $0.hasSuffix(".wav") || $0.hasSuffix(".part") }, [],
                       "その回に作った WAV と PNG は一式消える: \(leftovers)")
    }

    func testPngWavSuccessfulExportStillReplacesExistingWav() async throws {
        // 正常完了では、既存 WAV はその回の WAV に置き換わる(従来どおり)。
        let dir = tmp.appendingPathComponent("out-replace")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("PREVIOUS-WAV".utf8).write(to: dir.appendingPathComponent("frame.wav"))
        var p = Project.new()
        p.width = 160; p.height = 90; p.fps = 10; p.bg = "#FF0000"
        var t = Clip(); t.type = .text; t.text = "PNG"; t.start = 0; t.duration = 0.5; t.fontSize = 40; t.x = 0.5; t.y = 0.5
        p.tracks[4].clips.append(t)
        let r = try await PngWavExporter.export(project: p, options: PngWavOptions(base: "frame"), to: dir)
        let info = try WavFileWriter.info(of: r.wavURL)
        XCTAssertEqual(info.sampleRate, 48000, "既存の目印ではなく、その回の WAV に置き換わっている")
        XCTAssertEqual(r.frameCount, 5)
    }

    // MARK: - F-7: 連番画像

    func testImageSequenceExportAppliesPluginEffect() async throws {
        let p = try invertProject
        let dir = tmp.appendingPathComponent("seq-fx")
        let r = try await ImageSequenceExporter.export(project: p, range: nil, to: dir, base: "f", format: .png,
                                                       pluginEffectProviders: [InvertEffectProvider()])
        XCTAssertGreaterThan(r.frameCount, 0)
        assertInverted(centerRGB(try loadImage(dir.appendingPathComponent(r.files[0]))))

        // プロバイダ無し・空では従来どおり(反転しない)で、互いに画素一致。
        let dirPlain = tmp.appendingPathComponent("seq-plain")
        let rp = try await ImageSequenceExporter.export(project: p, range: nil, to: dirPlain, base: "f", format: .png)
        XCTAssertEqual(centerRGB(try loadImage(dirPlain.appendingPathComponent(rp.files[0]))), [200, 30, 60])
        let dirEmpty = tmp.appendingPathComponent("seq-empty")
        let re = try await ImageSequenceExporter.export(project: p, range: nil, to: dirEmpty, base: "f", format: .png,
                                                        pluginEffectProviders: [])
        XCTAssertEqual(allPixels(try loadImage(dirPlain.appendingPathComponent(rp.files[0]))),
                       allPixels(try loadImage(dirEmpty.appendingPathComponent(re.files[0]))))
    }

    // MARK: - F-7: 静止画

    func testStillExportAppliesPluginEffect() throws {
        let p = try invertProject
        let fx = tmp.appendingPathComponent("still-fx.png")
        try StillExporter.write(project: p, at: 0.5, format: .png, to: fx, pluginEffectProviders: [InvertEffectProvider()])
        assertInverted(centerRGB(try loadImage(fx)))
        let plain = tmp.appendingPathComponent("still-plain.png")
        try StillExporter.write(project: p, at: 0.5, format: .png, to: plain)
        XCTAssertEqual(centerRGB(try loadImage(plain)), [200, 30, 60])
    }

    // MARK: - F-7: サムネイル

    func testThumbnailExportAppliesPluginEffect() throws {
        let p = try invertProject
        let fx = tmp.appendingPathComponent("thumb-fx.png")
        try ThumbnailExporter.write(project: p, at: 0.5, format: .png, to: fx, pluginEffectProviders: [InvertEffectProvider()])
        let img = try loadImage(fx)
        XCTAssertEqual(img.width, 1280); XCTAssertEqual(img.height, 720)
        assertInverted(centerRGB(img))
        let plain = tmp.appendingPathComponent("thumb-plain.png")
        try ThumbnailExporter.write(project: p, at: 0.5, format: .png, to: plain)
        XCTAssertEqual(centerRGB(try loadImage(plain)), [200, 30, 60])
    }

    // MARK: - F-7: サムネイル候補(探索の描画と書き出しの両方)

    func testThumbnailCandidatesApplyPluginEffect() throws {
        let p = try invertProject
        // 探索(find): 点数付けに使う描画にも効くので、候補の明るさが反転後の値になる。
        let plain = ThumbnailCandidateFinder.find(project: p, start: 0, duration: 4, count: 3, samples: 6, detector: NoFaces())
        XCTAssertFalse(plain.isEmpty)
        XCTAssertEqual(plain[0].brightness, 0.41, accuracy: 0.05, "元の色(200,30,60)の明るさ")
        let fx = ThumbnailCandidateFinder.find(project: p, start: 0, duration: 4, count: 3, samples: 6,
                                               pluginEffectProviders: [InvertEffectProvider()], detector: NoFaces())
        XCTAssertFalse(fx.isEmpty)
        XCTAssertEqual(fx[0].brightness, 0.79, accuracy: 0.05, "反転後の色(55,225,195)の明るさ")

        // 書き出し(write): 候補のコマを書く経路にも効く。
        let cand = [ThumbnailCandidate(time: 0.5, score: 1, sharpness: 0, brightness: 0, faceCount: 0)]
        let folder = tmp.appendingPathComponent("cand-fx")
        let urls = try ThumbnailCandidateFinder.write(cand, project: p, baseName: "demo",
                                                      pluginEffectProviders: [InvertEffectProvider()], to: folder)
        assertInverted(centerRGB(try loadImage(try XCTUnwrap(urls.first))))
    }

    // MARK: - F-7: 絵コンテ

    func testStoryboardAppliesPluginEffect() throws {
        let p = try invertProject
        let fx = tmp.appendingPathComponent("board-fx.png")
        try Storyboard.write(project: p, count: 1, columns: 1, pluginEffectProviders: [InvertEffectProvider()], to: fx)
        assertInverted(centerRGB(try loadImage(fx)))
        let plain = tmp.appendingPathComponent("board-plain.png")
        try Storyboard.write(project: p, count: 1, columns: 1, to: plain)
        XCTAssertEqual(centerRGB(try loadImage(plain)), [200, 30, 60])
    }

    // MARK: - F-7: 連番 PNG + WAV 経路でも従来どおり効く(回帰確認)

    func testPngWavExportAppliesPluginEffect() async throws {
        let p = try invertProject
        let dir = tmp.appendingPathComponent("pngwav-fx")
        let r = try await PngWavExporter.export(project: p, options: PngWavOptions(base: "frame"), to: dir,
                                                pluginEffectProviders: [InvertEffectProvider()])
        assertInverted(centerRGB(try loadImage(dir.appendingPathComponent(r.files[0]))))
    }
}
