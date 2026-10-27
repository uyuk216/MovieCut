import XCTest
import AVFoundation
@testable import MovieCutCore

final class FrameRateAndOutputTests: XCTestCase {
    // MARK: FrameRate

    func testBroadcastRatesMapToExactRationals() {
        let cases: [(Double, Int, Int)] = [(23.976, 24000, 1001), (29.97, 30000, 1001), (47.952, 48000, 1001), (59.94, 60000, 1001), (119.88, 120000, 1001),
                                           (23.98, 24000, 1001), (29.975, 30000, 1001)]
        for (v, n, d) in cases { let r = FrameRate.from(v); XCTAssertEqual([r.num, r.den], [n, d], "\(v)") }
    }

    func testOtherRatesUseDenominator1000Reduced() {
        for (v, n, d) in [(12.5, 25, 2), (24.0, 24, 1), (60.0, 60, 1), (240.0, 240, 1), (25.0, 25, 1), (29.123, 29123, 1000)] {
            let r = FrameRate.from(v); XCTAssertEqual([r.num, r.den], [n, d], "\(v)")
        }
        XCTAssertEqual(FrameRate.from(0).value, 1, accuracy: 1e-9)
        XCTAssertEqual(FrameRate.from(1000).value, 240, accuracy: 1e-9)
        XCTAssertEqual(FrameRate.from(.nan).value, 60, accuracy: 1e-9)
    }

    func testLabels() {
        XCTAssertEqual(FrameRate.label(60), "60"); XCTAssertEqual(FrameRate.label(29.97), "29.97")
        XCTAssertEqual(FrameRate.label(30000.0 / 1001), "29.97"); XCTAssertEqual(FrameRate.label(23.976), "23.976")
        XCTAssertEqual(FrameRate.label(12.5), "12.5"); XCTAssertEqual(FrameRate.label(12.3456), "12.346")
        XCTAssertEqual(VideoText.chip(width: 1920, height: 1080, fps: 29.97), "1920×1080 · 29.97fps")
        XCTAssertEqual(VideoText.chip(width: 1920, height: 1080, fps: 60), "1920×1080 · 60fps")
    }

    func testFrameCountAndTimeMath() {
        let r = FrameRate.from(29.97)
        XCTAssertEqual(r.frameCount(duration: 3), 90)
        XCTAssertEqual(r.frameCount(duration: 1001.0 / 30000 * 90), 90, "ちょうどのときは増えない")
        XCTAssertEqual(FrameRate.from(60).frameCount(duration: 3.7), 222)
        XCTAssertEqual(r.time(ofFrame: 30000), 1001, accuracy: 1e-9)
        XCTAssertEqual(r.cmTime(frame: 30).value, 30030); XCTAssertEqual(r.cmTime(frame: 30).timescale, 30000)
        XCTAssertEqual(r.frameIndex(at: r.time(ofFrame: 17)), 17)
        XCTAssertEqual(FrameRate.from(12.5).frameCount(duration: 3.4402), 44)
        XCTAssertEqual(r.frameMilliseconds(), "33.367")
        // コマ送り
        XCTAssertEqual(r.stepped(from: r.time(ofFrame: 10), frames: 1), r.time(ofFrame: 11), accuracy: 1e-9)
        XCTAssertEqual(r.stepped(from: r.time(ofFrame: 10), frames: -1), r.time(ofFrame: 9), accuracy: 1e-9)
        XCTAssertEqual(r.stepped(from: 0, frames: -1), 0)
        XCTAssertEqual(r.stepped(from: r.time(ofFrame: 10) + 0.01, frames: -1), r.time(ofFrame: 10), accuracy: 1e-9)
    }

    // MARK: JSON

    func testFpsJsonRoundTripAndLenientDecode() throws {
        var p = Project.new()
        p.fps = 60
        var s = String(decoding: try p.encoded(), as: UTF8.self)
        XCTAssertTrue(s.contains("\"fps\" : 60,") || s.contains("\"fps\" : 60\n"), s)
        XCTAssertFalse(s.contains("60.0"))
        p.fps = 29.97
        s = String(decoding: try p.encoded(), as: UTF8.self)
        XCTAssertTrue(s.contains("\"fps\" : 29.97"))
        XCTAssertEqual(try Project.decode(from: p.encoded()).fps, 29.97)
        func fps(_ json: String) throws -> Double { try Project.decode(from: Data(json.utf8)).fps }
        XCTAssertEqual(try fps(#"{"fps":30}"#), 30)
        XCTAssertEqual(try fps(#"{"fps":23.976}"#), 23.976)
        XCTAssertEqual(try fps(#"{"fps":"29.97"}"#), 29.97)
        XCTAssertEqual(try fps(#"{"fps":"30000/1001"}"#), 30000.0 / 1001, accuracy: 1e-9)
        XCTAssertEqual(try fps(#"{}"#), 60)
        XCTAssertEqual(try fps(#"{"fps":"abc"}"#), 60)
        XCTAssertEqual(try fps(#"{"fps":1000}"#), 240)
        XCTAssertEqual(try fps(#"{"fps":0}"#), 1)
    }

    func testTimecodeStaysCorrectForFractionalRates() {
        // 画面のタイムコード(mm:ss.cc)は秒から作るので、コマ数ではずれない。コマの時刻も 29.97 / 23.976 で単調に進む
        for v in [29.97, 23.976] {
            let r = FrameRate.from(v)
            var prev = -1.0
            for i in 0..<2000 { let t = r.time(ofFrame: i); XCTAssertGreaterThan(t, prev); prev = t; XCTAssertEqual(r.frameIndex(at: t), i) }
        }
        XCTAssertEqual(FrameRate.from(29.97).time(ofFrame: 1800), 60.06, accuracy: 1e-9)
    }

    // MARK: 入力

    func testFrameRateInputParsing() {
        func ok(_ s: String) -> Double? { if case .success(let v) = FrameRateInput.parse(s) { return v }; return nil }
        XCTAssertEqual(ok("29.97"), 29.97); XCTAssertEqual(ok("30000/1001"), 29.97); XCTAssertEqual(ok(" 12,5 "), 12.5)
        XCTAssertEqual(ok("２９．９７"), 29.97); XCTAssertEqual(ok("60fps"), 60); XCTAssertEqual(ok("24000 / 1001"), 23.976)
        for bad in ["", "abc", "0", "0.5", "241", "-3", "30/0", "1/2"] { XCTAssertNil(ok(bad), bad) }
        if case .failure(let e) = FrameRateInput.parse("500") { XCTAssertTrue(e.message.contains("1〜240")) } else { XCTFail() }
        XCTAssertEqual(FrameRateInput.describe(29.97), "1フレーム = 33.367 ms · 毎秒 29.97 コマ")
        XCTAssertEqual(FrameRate.presets, [24, 30, 48, 60, 120, 240])
    }

    func testResolutionInputValidationAspectSwapAndNotices() {
        var r = ResolutionInput(width: 1920, height: 1080)
        XCTAssertTrue(r.isValid); XCTAssertEqual(r.summary, "縦横比 16:9 · 書き出しサイズ 1920×1080 · H.264")
        r.setLock(true); r.setWidth("1280"); XCTAssertEqual(r.heightText, "720")
        r.setHeight("1080"); XCTAssertEqual(r.widthText, "1920")
        r.swap(); XCTAssertEqual([r.widthText, r.heightText], ["1080", "1920"])
        r.setWidth("540"); XCTAssertEqual(r.heightText, "960", "入れ替え後も縦横比(9:16)を保つ")
        var o = ResolutionInput(width: 1081, height: 607)
        XCTAssertEqual(o.notices, ["書き出しは 1080×606 になります"])
        XCTAssertEqual(o.summary, "縦横比 1.78:1 · 書き出しサイズ 1080×606 · H.264")
        o.set(width: 63, height: 100); XCTAssertNotNil(o.validation); XCTAssertTrue(o.validation!.contains("64〜8192"))
        o.set(width: 8193, height: 100); XCTAssertNotNil(o.validation)
        o.set(width: 8192, height: 8192); XCTAssertTrue(o.validation!.contains("大きすぎ"))
        o.widthText = "x"; XCTAssertEqual(o.validation, "幅と高さは数字で入力してください")
        o.widthText = "5120"; o.heightText = "2880"; XCTAssertEqual(o.notices, [OutputPlan.fallbackNotice])
        o.set(width: 64, height: 64); XCTAssertTrue(o.isValid)
        o.set(width: 8192, height: 4320); o.fps = 60
        XCTAssertTrue(o.notices.contains(OutputPlan.heavyNotice))
        switch ResolutionInput.parseAndValidate("1920x1080") { case .success(let s): XCTAssertEqual([s.width, s.height], [1920, 1080]); default: XCTFail() }
        if case .success = ResolutionInput.parseAndValidate("10x10") { XCTFail() }
        if case .success = ResolutionInput.parseAndValidate("abc") { XCTFail() }
    }

    func testH264LimitAndPlan() {
        XCTAssertTrue(OutputPlan.h264Supports(width: 4096, height: 2304))
        XCTAssertTrue(OutputPlan.h264Supports(width: 4096, height: 2160))
        XCTAssertTrue(OutputPlan.h264Supports(width: 2304, height: 4096))
        XCTAssertFalse(OutputPlan.h264Supports(width: 5120, height: 2880))
        XCTAssertFalse(OutputPlan.h264Supports(width: 4098, height: 2304))
        XCTAssertFalse(OutputPlan.h264Supports(width: 7680, height: 4320))
        let p = OutputPlan.make(width: 5120, height: 2880, codec: "h264")
        XCTAssertEqual(p.codec, "hevc"); XCTAssertTrue(p.usesFallbackCodec); XCTAssertNil(p.error)
        XCTAssertEqual(OutputPlan.make(width: 1920, height: 1080, codec: "h264").codec, "h264")
        XCTAssertEqual(OutputPlan.make(width: 8192, height: 4320, codec: "hevc").error, nil)
        XCTAssertNotNil(OutputPlan.make(width: 8192, height: 8192, codec: "hevc").error)
        XCTAssertNotNil(OutputPlan.make(width: 1, height: 1, codec: "h264").error)
        XCTAssertEqual(OutputPlan.make(width: 1081, height: 607, codec: "h264").evenNotice, "書き出しは 1080×606 になります")
    }

    func testHeavyWarning() {
        XCTAssertNil(OutputPlan.heavyWarning(width: 3840, height: 2160, fps: 120))
        XCTAssertNil(OutputPlan.heavyWarning(width: 1920, height: 1080, fps: 240))
        XCTAssertNil(OutputPlan.heavyWarning(width: 3840, height: 2160, fps: 60))
        XCTAssertNotNil(OutputPlan.heavyWarning(width: 7680, height: 4320, fps: 60))
        XCTAssertNotNil(OutputPlan.heavyWarning(width: 3840, height: 2160, fps: 240))
        XCTAssertNotNil(OutputPlan.heavyWarning(width: 5120, height: 2880, fps: 120))
        XCTAssertNil(OutputPlan.heavyWarning(width: 5120, height: 2880, fps: 60))
    }

    func testRecentCustoms() {
        let d = UserDefaults(suiteName: "moviecut-tests-\(UUID().uuidString)")!
        let r = RecentCustoms.resolutions(d)
        XCTAssertEqual(r.items, [])
        r.addSize(width: 1000, height: 500); r.addSize(width: 1001, height: 501); r.addSize(width: 1002, height: 502)
        r.addSize(width: 1000, height: 500)   // 重複は先頭へ
        XCTAssertEqual(r.items, ["1000x500", "1002x502", "1001x501"])
        r.addSize(width: 999, height: 499)
        XCTAssertEqual(r.items.count, 3); XCTAssertEqual(r.items.first, "999x499"); XCTAssertFalse(r.items.contains("1001x501"))
        XCTAssertEqual(RecentCustoms.resolutions(d).sizes.first?.width, 999, "同じ UserDefaults から読める(保存される)")
        let f = RecentCustoms.frameRates(d)
        f.addRate(12.5); f.addRate(29.97); f.addRate(12.5)
        XCTAssertEqual(f.rates, [12.5, 29.97])
        XCTAssertEqual(RecentCustoms.resolutions(d).items.count, 3, "キーが別")
    }

    // MARK: 書き出し(短い実際の書き出し)

    func testExportsExactFrameTimingForBroadcastRate() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("fr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        var p = Project.new(); p.width = 320; p.height = 180; p.fps = 29.97
        var t = Clip(); t.type = .text; t.text = "a"; t.start = 0; t.duration = 1; t.fontSize = 40
        p.tracks[4].clips.append(t)
        let out = tmp.appendingPathComponent("a.mp4")
        let ex = Exporter(project: p, assets: RenderAssets())
        XCTAssertEqual(ex.totalFrames, 30)
        try await ex.export(to: out)
        let asset = AVURLAsset(url: out)
        let tr = try await asset.loadTracks(withMediaType: .video)[0]
        let rate = try await tr.load(.nominalFrameRate)
        XCTAssertEqual(Double(rate), 29.97, accuracy: 0.01)
        let dur = try await tr.load(.timeRange).duration.seconds
        XCTAssertEqual(dur, 30 * 1001.0 / 30000, accuracy: 0.002)
    }

    func testLargeSizeFallsBackToHEVC() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("fr-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: tmp) }
        var p = Project.new(); p.width = 4608; p.height = 2592; p.fps = 2; p.codec = "h264"
        var t = Clip(); t.type = .text; t.text = "a"; t.start = 0; t.duration = 1; t.fontSize = 40
        p.tracks[4].clips.append(t)
        try await Exporter(project: p, assets: RenderAssets()).export(to: tmp)
        let tr = try await AVURLAsset(url: tmp).loadTracks(withMediaType: .video)[0]
        let fd = try await tr.load(.formatDescriptions)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(fd[0]), kCMVideoCodecType_HEVC)
    }
}
