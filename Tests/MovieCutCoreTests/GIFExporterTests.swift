import XCTest
import ImageIO
@testable import MovieCutCore

/// GIF の書き出し(ImageIO)。実ファイルのコマ数・サイズ・ループ・時間を読み直して確かめる。
final class GIFExporterTests: XCTestCase {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("gif-tests-\(UUID().uuidString)")
    override func setUpWithError() throws { try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    /// 文字クリップ 1 つ(音声なし)。`width` は画面の幅。
    private func project(width: Int = 640, height: Int = 360, duration: Double = 2, fps: Double = 30) -> Project {
        var p = Project.new()
        p.width = width; p.height = height; p.fps = fps
        var t = Clip(); t.type = .text; t.text = "GIF"; t.start = 0; t.duration = duration; t.fontSize = 60; t.x = 0.5; t.y = 0.5
        p.tracks[4].clips.append(t)
        return p
    }

    struct Read {
        var count: Int
        var width: Int
        var height: Int
        var delays: [Double]
        var loopCount: Int?
    }

    /// 書かれた GIF を開き直して、コマ数・先頭コマのサイズ・各コマの時間・ループ回数を読む。
    private func read(_ url: URL) throws -> Read {
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil), "GIF として開けない")
        XCTAssertEqual(CGImageSourceGetType(src) as String?, "com.compuserve.gif")
        let count = CGImageSourceGetCount(src)
        let first = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
        let w = (first[kCGImagePropertyPixelWidth] as? Int) ?? -1
        let h = (first[kCGImagePropertyPixelHeight] as? Int) ?? -1
        var delays: [Double] = []
        for i in 0..<count {
            let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]
            let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            delays.append((gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? -1)
        }
        let fileProps = CGImageSourceCopyProperties(src, nil) as? [CFString: Any]
        let loop = (fileProps?[kCGImagePropertyGIFDictionary] as? [CFString: Any])?[kCGImagePropertyGIFLoopCount] as? Int
        return Read(count: count, width: w, height: h, delays: delays, loopCount: loop)
    }

    // MARK: 計画

    func testPlanFrameCountAndSize() {
        let p = project(width: 1920, height: 1080, duration: 3.7)
        let plan = GIFExporter.plan(project: p, range: nil, options: GIFOptions(fps: 10, maxWidth: 480))
        XCTAssertEqual(plan.width, 480)
        XCTAssertEqual(plan.height, 270, "縦横比を保つ")
        XCTAssertEqual(plan.frames, 37, "3.7 秒 × 10 fps")
        XCTAssertEqual(plan.delay, 0.1, accuracy: 1e-9)
    }

    func testPlanRoundsFrameCountUpAndUsesRange() {
        // 3.7 × 10 = 37.000000000000004 のような誤差で 1 コマ増えない。範囲は長さで数える。
        let p = project(width: 320, height: 180, duration: 4)
        XCTAssertEqual(GIFExporter.plan(project: p, range: nil, options: GIFOptions(fps: 10, maxWidth: nil)).frames, 40)
        XCTAssertEqual(GIFExporter.plan(project: p, range: ExportRange(start: 1, end: 2.5), options: GIFOptions(fps: 10, maxWidth: nil)).frames, 15)
        XCTAssertEqual(GIFExporter.plan(project: p, range: ExportRange(start: 0, end: 0.25), options: GIFOptions(fps: 10, maxWidth: nil)).frames, 3, "0.25 秒 × 10 は切り上げて 3")
    }

    func testMaxWidthNeverUpscalesAndNilKeepsSize() {
        let p = project(width: 320, height: 180)
        XCTAssertEqual(GIFExporter.outputSize(project: p, maxWidth: 480).width, 320, "大きくしない")
        XCTAssertEqual(GIFExporter.outputSize(project: p, maxWidth: nil).height, 180)
        XCTAssertEqual(GIFExporter.outputSize(project: p, maxWidth: 160).height, 90)
        // 極端な縦長でも高さは 1 以上
        XCTAssertGreaterThanOrEqual(GIFExporter.outputSize(project: project(width: 4000, height: 2), maxWidth: 16).height, 1)
    }

    func testOptionsValidation() {
        XCTAssertEqual(GIFOptions.validFPS(10), 10)
        XCTAssertNil(GIFOptions.validFPS(0))
        XCTAssertNil(GIFOptions.validFPS(31))
        XCTAssertNil(GIFOptions.validFPS(.nan))
        XCTAssertEqual(GIFOptions(fps: 10, maxWidth: 2).maxWidth, 16, "幅は下限に丸める")
        XCTAssertEqual(GIFOptions(fps: 10, maxWidth: 99999).maxWidth, 4096, "幅は上限に丸める")
    }

    // MARK: 書き出し(実ファイル)

    func testExportWritesRealAnimatedGIF() async throws {
        let p = project(width: 640, height: 360, duration: 2)
        let out = tmp.appendingPathComponent("a.gif")
        var last = 0.0
        let r = try await GIFExporter.export(project: p, options: GIFOptions(fps: 10, maxWidth: 160), to: out) { v in
            XCTAssertGreaterThanOrEqual(v, last); last = v
        }
        XCTAssertEqual(last, 1.0)
        XCTAssertEqual(r.frameCount, 20)
        let g = try read(out)
        XCTAssertEqual(g.count, 20, "実ファイルのコマ数")
        XCTAssertEqual(g.width, 160)
        XCTAssertEqual(g.height, 90)
        XCTAssertEqual(g.loopCount, 0, "無限ループ")
        XCTAssertEqual(g.delays.count, 20)
        for d in g.delays { XCTAssertEqual(d, 0.1, accuracy: 0.011, "1 コマ 0.1 秒(GIF は 1/100 秒単位)") }
        XCTAssertGreaterThan(r.bytes, 0)
        let size = try FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int
        XCTAssertEqual(size, r.bytes)
        XCTAssertEqual(try Data(contentsOf: out).prefix(3), Data("GIF".utf8))
        // 一時ファイルが残っていない
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: tmp.path).filter { $0.hasSuffix(".part") }
        XCTAssertEqual(leftovers, [])
    }

    func testRangeExportsOnlyThatSpan() async throws {
        let p = project(width: 320, height: 180, duration: 4)
        let out = tmp.appendingPathComponent("range.gif")
        let r = try await GIFExporter.export(project: p, range: ExportRange(start: 1, end: 2), options: GIFOptions(fps: 5, maxWidth: nil), to: out)
        XCTAssertEqual(r.frameCount, 5)
        XCTAssertEqual(try read(out).count, 5)
    }

    func testFPSChangesFrameCount() async throws {
        let p = project(width: 320, height: 180, duration: 1)
        let slow = tmp.appendingPathComponent("slow.gif")
        let fast = tmp.appendingPathComponent("fast.gif")
        try await GIFExporter.export(project: p, options: GIFOptions(fps: 5, maxWidth: nil), to: slow)
        try await GIFExporter.export(project: p, options: GIFOptions(fps: 20, maxWidth: nil), to: fast)
        XCTAssertEqual(try read(slow).count, 5)
        XCTAssertEqual(try read(fast).count, 20)
    }

    func testExistingFileIsReplaced() async throws {
        let p = project(width: 320, height: 180, duration: 1)
        let out = tmp.appendingPathComponent("old.gif")
        try Data("old".utf8).write(to: out)
        try await GIFExporter.export(project: p, options: GIFOptions(fps: 5, maxWidth: nil), to: out)
        XCTAssertEqual(try read(out).count, 5)
    }

    func testEmptyProjectThrows() async {
        let out = tmp.appendingPathComponent("e.gif")
        do {
            try await GIFExporter.export(project: Project.new(), to: out)
            XCTFail("空のプロジェクトは例外になるはず")
        } catch {
            XCTAssertTrue(error is ExportError)
            XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
        }
    }

    /// キャンセルしたら、途中のファイルも一時ファイルも残らず、既存のファイルは元のまま。
    func testCancelKeepsExistingFileAndRemovesPartial() async throws {
        let p = project(width: 1280, height: 720, duration: 60)  // 600 コマ: 十分に長い
        let out = tmp.appendingPathComponent("cancel.gif")
        try Data("keep".utf8).write(to: out)
        let started = expectation(description: "progress")
        started.assertForOverFulfill = false
        let task = Task { try await GIFExporter.export(project: p, options: GIFOptions(fps: 10, maxWidth: 640), to: out) { _ in started.fulfill() } }
        await fulfillment(of: [started], timeout: 60)
        task.cancel()
        do { _ = try await task.value; XCTFail("キャンセルされるはず") }
        catch is CancellationError {}
        catch { XCTFail("CancellationError のはずが \(error)") }
        XCTAssertEqual(try Data(contentsOf: out), Data("keep".utf8), "既存のファイルは変えない")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: tmp.path).filter { $0.hasSuffix(".part") }
        XCTAssertEqual(leftovers, [], "一時ファイルを残さない")
    }
}
