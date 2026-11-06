import XCTest
import AVFoundation
import CoreGraphics
@testable import MovieCutCore

/// 同梱素材: 合成が決まった結果になること(長さ・ピーク・無音でない・毎回同じ)、WAV・PNG が読めること、フォルダの作成と一覧。
final class BuiltInLibraryTests: XCTestCase {
    var tmp: URL!
    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("builtin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }
    var locations: DataLocations { DataLocations(edition: .personal, applicationSupport: tmp) }

    func testCountsAre12Sounds6Backgrounds6Shapes() {
        XCTAssertEqual(BuiltInSounds.specs.count, 12)
        XCTAssertEqual(BuiltInImages.specs.filter { !$0.isShape }.count, 6)
        XCTAssertEqual(BuiltInImages.specs.filter { $0.isShape }.count, 6)
        XCTAssertEqual(Set(BuiltInLibrary.fileNames).count, 24, "名前が重ならない")
    }

    func testEverySoundHasDurationPeakAndIsNotSilent() {
        for s in BuiltInSounds.specs {
            let x = BuiltInSounds.render(s.id)
            XCTAssertEqual(x.count, Int((s.duration * 44100).rounded()), s.id)
            let peak = x.map { abs($0) }.max() ?? 0
            XCTAssertEqual(peak, BuiltInSounds.peakLevel, accuracy: 0.01, "\(s.id) のピーク")
            XCTAssertTrue(x.allSatisfy { $0.isFinite && abs($0) <= 1 }, s.id)
            let rms = (x.map { Double($0 * $0) }.reduce(0, +) / Double(x.count)).squareRoot()
            XCTAssertGreaterThan(rms, 0.02, "\(s.id) は無音でない")
            XCTAssertEqual(x.last ?? 1, 0, accuracy: 0.01, "\(s.id) は終わりでゼロへ落ちる")
        }
    }

    func testSynthesisIsDeterministic() {
        for s in BuiltInSounds.specs { XCTAssertEqual(BuiltInSounds.render(s.id), BuiltInSounds.render(s.id), s.id) }
        XCTAssertEqual(BuiltInSounds.wavData(BuiltInSounds.render("click")), BuiltInSounds.wavData(BuiltInSounds.render("click")))
        XCTAssertTrue(BuiltInSounds.render("nope").isEmpty)
    }

    func testSoundsAreDistinctFromEachOther() {
        var seen = Set<[Float]>()
        for s in BuiltInSounds.specs { seen.insert(Array(BuiltInSounds.render(s.id).prefix(2000))) }
        XCTAssertEqual(seen.count, 12)
    }

    func testImagesRenderWithExpectedSizeAndContent() throws {
        for s in BuiltInImages.specs {
            let img = try XCTUnwrap(BuiltInImages.render(s.id), s.id)
            let (w, h) = s.isShape ? (512, 512) : (1280, 720)
            XCTAssertEqual(img.width, w); XCTAssertEqual(img.height, h)
            var d = [UInt8](repeating: 0, count: w * h * 4)
            let c = CGContext(data: &d, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            c.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            func px(_ x: Int, _ y: Int) -> [UInt8] { Array(d[(y * w + x) * 4..<(y * w + x) * 4 + 4]) }
            if s.isShape {
                XCTAssertEqual(px(2, 2)[3], 0, "\(s.id) の四隅は透明")
                var opaque = 0
                for i in stride(from: 3, to: d.count, by: 4) where d[i] == 255 { opaque += 1 }
                XCTAssertGreaterThan(opaque, w * h / 8, "\(s.id) の本体がある")
            } else {
                XCTAssertEqual(px(0, 0)[3], 255)
                let distinct = Set((0..<400).map { px(($0 * 37) % w, ($0 * 53) % h) })
                XCTAssertGreaterThan(distinct.count, 1, "\(s.id) は一色でない")
            }
        }
    }

    func testInstallWritesReadableFilesOnceAndListsThem() throws {
        let dir = BuiltInLibrary.ensureInstalled(in: locations)
        XCTAssertEqual(dir, locations.builtinMedia)
        for n in BuiltInLibrary.fileNames { XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(n).path), n) }
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("ライセンス.txt"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), "このアプリが生成したものでライセンス自由")
        // WAV が AVAudioFile で読め、長さが合う
        let f = try AVAudioFile(forReading: dir.appendingPathComponent("効果音-チャイム.wav"))
        XCTAssertEqual(Double(f.length) / f.fileFormat.sampleRate, 1.5, accuracy: 0.01)
        // 2 回目は書き直さない(更新日が変わらない)
        let url = dir.appendingPathComponent("効果音-ベル.wav")
        let m1 = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        Thread.sleep(forTimeInterval: 0.05)
        BuiltInLibrary.ensureInstalled(in: locations)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date, m1)
        // 消したファイルは作り直す
        try FileManager.default.removeItem(at: url)
        BuiltInLibrary.ensureInstalled(in: locations)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        // 素材ブラウザの一覧
        let items = BuiltInLibrary.items(in: locations)
        XCTAssertEqual(items.count, 24)
        XCTAssertEqual(items.filter { $0.kind == .audio }.count, 12)
        XCTAssertEqual(items.filter { $0.kind == .image }.count, 12)
        XCTAssertEqual(MediaBrowser.filter(items, kind: .audio, query: "ベル").map(\.name), ["効果音-ベル.wav"])
        XCTAssertEqual(MediaBrowser.filter(items, kind: .image, query: "背景").count, 6)
        XCTAssertTrue(BuiltInLibrary.isBuiltIn(dir, in: locations))
        XCTAssertFalse(BuiltInLibrary.isBuiltIn(tmp, in: locations))
    }

    func testListedFilesAreProbeReadable() async throws {
        let items = BuiltInLibrary.items(in: locations)
        for it in items {
            let p = await MediaBrowser.probe(url: it.url, kind: it.kind)
            XCTAssertFalse(p.unreadable, it.name)
            if it.kind == .audio { XCTAssertNotNil(p.duration, it.name) }
        }
    }

    func testBuiltinFolderDoesNotOverlapOtherDataFolders() {
        let paths = locations.allPaths.map(\.path)
        XCTAssertEqual(Set(paths).count, paths.count)
    }
}
