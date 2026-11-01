import XCTest
import AVFoundation
import ImageIO
@testable import MovieCutCore

/// 書き出し範囲・静止画・連番画像(フェーズ C-1)。
final class ExportRangeTests: XCTestCase {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("range-tests-\(UUID().uuidString)")
    override func setUpWithError() throws { try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    /// 4 秒の文字クリップが 1 つ(音声なし)。
    private func project(fps: Double = 30, duration: Double = 4) -> Project {
        var p = Project.new()
        p.width = 320; p.height = 180; p.fps = fps
        var t = Clip(); t.type = .text; t.text = "A"; t.start = 0; t.duration = duration; t.fontSize = 60; t.x = 0.5; t.y = 0.5
        p.tracks[4].clips.append(t)
        return p
    }

    // MARK: 範囲の計算

    /// クリップを縮めたあと、プロジェクトの終わりより後ろに残った古い印が、新しい範囲の設定を邪魔しない。
    func testStaleMarksBeyondEndDoNotBlockEditing() {
        var p = project(duration: 4)
        p.rangeIn = 10; p.rangeOut = 12          // 縮める前の印(いまの終わりは 4 秒)
        XCTAssertNil(p.exportRange)
        let q = ExportRangeEditing.settingOut(p, at: 3)
        XCTAssertEqual(q?.rangeOut, 3)
        let r = ExportRangeEditing.settingIn(p, at: 1)
        XCTAssertEqual(r?.rangeIn, 1)
    }

    func testResolve() {
        XCTAssertNil(ExportRange.resolve(rangeIn: nil, rangeOut: nil, endTime: 4))
        XCTAssertEqual(ExportRange.resolve(rangeIn: 1, rangeOut: 3, endTime: 4), ExportRange(start: 1, end: 3))
        XCTAssertEqual(ExportRange.resolve(rangeIn: 1, rangeOut: nil, endTime: 4), ExportRange(start: 1, end: 4), "アウトが無ければ終わりまで")
        XCTAssertEqual(ExportRange.resolve(rangeIn: nil, rangeOut: 2, endTime: 4), ExportRange(start: 0, end: 2), "インが無ければ頭から")
        XCTAssertEqual(ExportRange.resolve(rangeIn: -5, rangeOut: 99, endTime: 4), ExportRange(start: 0, end: 4), "外は切り詰める")
        XCTAssertNil(ExportRange.resolve(rangeIn: 3, rangeOut: 3, endTime: 4), "長さ 0")
        XCTAssertNil(ExportRange.resolve(rangeIn: 3, rangeOut: 2, endTime: 4), "逆転")
        XCTAssertNil(ExportRange.resolve(rangeIn: 1, rangeOut: 2, endTime: 0), "空のプロジェクト")
        XCTAssertNil(ExportRange.resolve(rangeIn: 5, rangeOut: nil, endTime: 4), "終わりより後ろ")
    }

    func testParse() throws {
        XCTAssertEqual(try ExportRange.parse("1:3", endTime: 4).get(), ExportRange(start: 1, end: 3))
        XCTAssertEqual(try ExportRange.parse("2.5:", endTime: 4).get(), ExportRange(start: 2.5, end: 4))
        XCTAssertEqual(try ExportRange.parse(":1.5", endTime: 4).get(), ExportRange(start: 0, end: 1.5))
        for bad in ["", "3", ":", "a:b", "3:1", "-1:2", "1:2:3x", "5:6"] {
            if case .success(let r) = ExportRange.parse(bad, endTime: 4) { XCTFail("\(bad) が通った: \(r)") }
        }
    }

    func testFrameCountsHaveNoOffByOne() {
        let r30 = FrameRate.from(30), r60 = FrameRate.from(60), ntsc = FrameRate.from(29.97)
        XCTAssertEqual(ExportRange(start: 1, end: 3).frameCount(r30), 60)
        XCTAssertEqual(ExportRange(start: 0, end: 3.7).frameCount(r60), 222, "3.7×60 の浮動小数の誤差で 1 コマ増えない")
        XCTAssertEqual(ExportRange(start: 1.1, end: 1.1 + 1.0 / 30).frameCount(r30), 1, "1 コマぶん")
        XCTAssertEqual(ExportRange(start: 0, end: 1.0 / 30 + 0.001).frameCount(r30), 2, "少し超えたら 1 コマ増える")
        XCTAssertEqual(ExportRange(start: 2, end: 4).frameCount(ntsc), 60, "2 秒 × 29.97 = 59.94 → 60")
        XCTAssertEqual(ExportRange(start: 1, end: 3).time(ofFrame: 0, r30), 1)
        XCTAssertEqual(ExportRange(start: 1, end: 3).time(ofFrame: 59, r30), 1 + 59.0 / 30, accuracy: 1e-9)
        let p = project()
        XCTAssertEqual(Exporter(project: p, assets: RenderAssets()).totalFrames, 120, "範囲なしは従来どおり")
        XCTAssertEqual(Exporter(project: p, assets: RenderAssets(), range: ExportRange(start: 1, end: 3)).totalFrames, 60)
    }

    func testRangeEditingRules() {
        let p = project()
        let a = ExportRangeEditing.settingIn(p, at: 1)
        XCTAssertEqual(a?.rangeIn, 1)
        let b = ExportRangeEditing.settingOut(a!, at: 3)
        XCTAssertEqual(b?.exportRange, ExportRange(start: 1, end: 3))
        XCTAssertNil(ExportRangeEditing.settingIn(b!, at: 3), "イン >= アウトは断る")
        XCTAssertNil(ExportRangeEditing.settingOut(b!, at: 1), "アウト <= インは断る")
        XCTAssertNil(ExportRangeEditing.settingIn(p, at: 4), "終わりちょうどのインは長さ 0")
        XCTAssertNil(ExportRangeEditing.settingOut(p, at: 0))
        XCTAssertEqual(ExportRangeEditing.settingIn(p, at: -2)?.rangeIn, 0, "負は 0 に")
        XCTAssertEqual(ExportRangeEditing.settingOut(p, at: 99)?.rangeOut, 4, "終わり超えは終わりに")
        XCTAssertNil(ExportRangeEditing.settingIn(Project.new(), at: 0), "空のプロジェクト")
        XCTAssertEqual(ExportRangeEditing.clearing(b!), p)
    }

    // MARK: 保存形式

    func testRangeIsStoredOnlyWhenSet() throws {
        var p = project()
        var j = try JSONSerialization.jsonObject(with: p.encoded()) as! [String: Any]
        XCTAssertNil(j["rangeIn"]); XCTAssertNil(j["rangeOut"])
        p.rangeIn = 1.5
        j = try JSONSerialization.jsonObject(with: p.encoded()) as! [String: Any]
        XCTAssertEqual(j["rangeIn"] as? Double, 1.5); XCTAssertNil(j["rangeOut"])
        p.rangeOut = 3
        let q = try Project.decode(from: p.encoded())
        XCTAssertEqual(q.rangeIn, 1.5); XCTAssertEqual(q.rangeOut, 3); XCTAssertEqual(q, p)
        XCTAssertNil(q.extra["rangeIn"], "既知のキーなので extra に二重に入らない")
        // 解除すると、また書かれない
        let s = String(decoding: try ExportRangeEditing.clearing(p).encoded(), as: UTF8.self)
        XCTAssertFalse(s.contains("rangeIn") || s.contains("rangeOut"))
    }

    func testAllOldFixturesRoundTripWithoutRangeKeys() throws {
        let dir = try XCTUnwrap(Bundle.module.url(forResource: "rich", withExtension: "ymproj", subdirectory: "Fixtures")).deletingLastPathComponent()
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".ymproj") }
        XCTAssertGreaterThan(names.count, 5)
        for n in names {
            let p = try Project.load(from: dir.appendingPathComponent(n))
            XCTAssertNil(p.rangeIn, n); XCTAssertNil(p.rangeOut, n)
            let s = String(decoding: try p.encoded(), as: UTF8.self)
            XCTAssertFalse(s.contains("rangeIn") || s.contains("rangeOut"), n)
            // 2 回目の読み書きで形が変わらない
            XCTAssertEqual(try Project.decode(from: p.encoded()).encoded(), try p.encoded(), n)
        }
    }

    // MARK: 名前

    func testSequenceNaming() {
        XCTAssertEqual(ImageSequenceNaming.fileName(base: "x", index: 1, digits: 5, format: .png), "x_00001.png")
        XCTAssertEqual(ImageSequenceNaming.fileName(base: "x", index: 120, digits: 5, format: .jpeg), "x_00120.jpg")
        XCTAssertEqual(ImageSequenceNaming.digits(frameCount: 99_999), 5)
        XCTAssertEqual(ImageSequenceNaming.digits(frameCount: 100_000), 6)
        XCTAssertEqual(ImageSequenceNaming.fileName(base: "x", index: 100_000, digits: 6, format: .png), "x_100000.png")
        XCTAssertEqual(StillFormat(pathExtension: "JPG"), .jpeg)
        XCTAssertEqual(StillFormat(pathExtension: "png"), .png)
        XCTAssertNil(StillFormat(pathExtension: "gif"))
        let plan = ImageSequenceExporter.plan(project: project(), range: ExportRange(start: 1, end: 3), base: "clip", format: .png)
        XCTAssertEqual(plan.frames, 60); XCTAssertEqual(plan.first, "clip_00001.png"); XCTAssertEqual(plan.last, "clip_00060.png")
    }

    // MARK: 実際の書き出し

    private func size(of url: URL) throws -> (Int, Int) {
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
        return (props[kCGImagePropertyPixelWidth] as! Int, props[kCGImagePropertyPixelHeight] as! Int)
    }

    func testStillPNGAndJPEGHaveProjectSize() throws {
        let p = project()
        for f in StillFormat.allCases {
            let u = tmp.appendingPathComponent("s.\(f.fileExtension)")
            try StillExporter.write(project: p, at: 1, format: f, to: u)
            let (w, h) = try size(of: u)
            XCTAssertEqual(w, 320); XCTAssertEqual(h, 180)
        }
        let data = try Data(contentsOf: tmp.appendingPathComponent("s.png"))
        XCTAssertEqual(Array(data.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
        let j = try Data(contentsOf: tmp.appendingPathComponent("s.jpg"))
        XCTAssertEqual(Array(j.prefix(2)), [0xFF, 0xD8])
    }

    func testSequenceWritesExactFrameCountAndNames() async throws {
        var p = project(fps: 10, duration: 4)
        // 時間で変わる絵: 2 秒目から文字が出る
        p.tracks[4].clips[0].start = 2; p.tracks[4].clips[0].duration = 2
        var last = 0.0
        let r = try await ImageSequenceExporter.export(project: p, range: ExportRange(start: 1, end: 3), to: tmp.appendingPathComponent("seq"), base: "q", format: .png) { last = $0 }
        XCTAssertEqual(r.frameCount, 20, "2 秒 × 10fps")
        XCTAssertEqual(last, 1, accuracy: 1e-9)
        let names = try FileManager.default.contentsOfDirectory(atPath: tmp.appendingPathComponent("seq").path).sorted()
        XCTAssertEqual(names.count, 20)
        XCTAssertEqual(names.first, "q_00001.png"); XCTAssertEqual(names.last, "q_00020.png")
        let first = try Data(contentsOf: tmp.appendingPathComponent("seq/q_00001.png"))
        let lastD = try Data(contentsOf: tmp.appendingPathComponent("seq/q_00020.png"))
        XCTAssertNotEqual(first, lastD, "範囲の頭(1 秒: 文字なし)と終わり(2.9 秒: 文字あり)で絵が違う")
        // 範囲なしは全体
        let all = try await ImageSequenceExporter.export(project: p, to: tmp.appendingPathComponent("all"), base: "q", format: .jpeg)
        XCTAssertEqual(all.frameCount, 40)
    }

    func testSequenceCancelRemovesWrittenFiles() async throws {
        let p = project(fps: 30, duration: 4)
        let dir = tmp.appendingPathComponent("cancel")
        let task = Task { try await ImageSequenceExporter.export(project: p, to: dir, base: "c", format: .png) }
        task.cancel()
        do { _ = try await task.value; XCTFail("キャンセルされるはず") } catch is CancellationError {}
        let left = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        XCTAssertTrue(left.isEmpty, "書きかけのファイルを残さない: \(left.count)")
    }

    func testRangeVideoExportHasRangeDurationAndAudioSlice() async throws {
        var p = project(fps: 30, duration: 4)
        let wav = tmp.appendingPathComponent("tone.wav")
        try ToneVoiceProvider.writeTone(to: wav, duration: 2.5, frequency: 330)
        var v = Clip(); v.type = .voice; v.start = 0; v.duration = 4; v.src = wav.path; v.text = "ぴー"
        v.charId = p.characters[0].id; v.volume = 1
        p.tracks[0].clips.append(v)
        let out = tmp.appendingPathComponent("r.mp4")
        try await Exporter(project: p, assets: RenderAssets(), range: ExportRange(start: 1, end: 3)).export(to: out)
        let asset = AVURLAsset(url: out)
        let dur = try await asset.load(.duration).seconds
        XCTAssertEqual(dur, 2, accuracy: 0.06)
        let vt = try await asset.loadTracks(withMediaType: .video).first!
        let vtr = try await vt.load(.timeRange)
        XCTAssertEqual(vtr.duration.seconds, 2, accuracy: 0.001, "60 コマ")
        let at = try await asset.loadTracks(withMediaType: .audio).first
        XCTAssertNotNil(at)
        // 音声のミックスは範囲の長さ(トーンは元の 2.5 秒で切れるので、範囲の 1.5 秒以降は無音)
        let mix = tmp.appendingPathComponent("m.caf")
        let res = try AudioMixer.mixdownDetailed(project: p, to: mix, range: ExportRange(start: 1, end: 3))
        XCTAssertEqual(res.duration, 2, accuracy: 1e-6)
        let f = try AVAudioFile(forReading: mix)
        XCTAssertEqual(f.length, 96000)
        let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: 96000)!
        try f.read(into: buf)
        let ch = buf.floatChannelData![0]
        func peak(_ a: Int, _ b: Int) -> Float { (a..<b).map { abs(ch[$0]) }.max() ?? 0 }
        XCTAssertGreaterThan(peak(0, 48000), 0.01, "範囲の頭(元の 1〜2 秒)は鳴っている")
        XCTAssertGreaterThan(peak(48000, 70000), 0.01, "元の 2〜2.45 秒も鳴っている")
        XCTAssertLessThan(peak(74000, 96000), 0.001, "元の 2.5 秒以降は無音(頭を切った分だけ前へ詰まっている)")
    }
}
