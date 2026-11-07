import XCTest
import AVFoundation
@testable import MovieCutCore

/// M7: 書き出しプリセット(パラメータ・元を変えないこと・ffprobe で確かめる実書き出し・音声のみ)。
final class ExportPresetTests: XCTestCase {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("preset-tests-\(UUID().uuidString)")
    override func setUpWithError() throws { try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private func sample(w: Int = 1280, h: Int = 720, fps: Double = 60, codec: String = "h264") -> Project {
        var p = Project.new()
        p.width = w; p.height = h; p.fps = fps; p.codec = codec
        var t = Clip(); t.type = .text; t.text = "字幕"; t.start = 0; t.duration = 2; t.fontSize = 60
        var b = Clip(); b.type = .blur; b.start = 0; b.duration = 2; b.strength = 20
        p.tracks[0].clips = [t, b]
        return p
    }

    // MARK: パラメータ

    func testPresetParameters() {
        let p = sample()
        func check(_ preset: ExportPreset, _ w: Int, _ h: Int, _ codec: String, _ fps: Double, line: UInt = #line) {
            let q = preset.apply(to: p)
            XCTAssertEqual([q.width, q.height], [w, h], "\(preset)", line: line); XCTAssertEqual(q.fps, fps, "\(preset)", line: line)
            XCTAssertEqual(q.codec, codec, "\(preset)", line: line)
        }
        check(.youtube1080, 1920, 1080, "h264", 60)
        check(.youtube4k, 3840, 2160, "hevc", 60)
        check(.short, 1080, 1920, "h264", 60)
        check(.light, 1280, 720, "h264", 30)
        let audio = ExportPreset.audio.apply(to: p)
        XCTAssertEqual(audio, p, "音声のみは映像の設定を変えない")
    }

    func testLightKeepsLowFpsAndCapsHighFps() {
        XCTAssertEqual(ExportPreset.light.apply(to: sample(fps: 24)).fps, 24)
        XCTAssertEqual(ExportPreset.light.apply(to: sample(fps: 30)).fps, 30)
        XCTAssertEqual(ExportPreset.light.apply(to: sample(fps: 60)).fps, 30)
        XCTAssertEqual(ExportPreset.youtube1080.apply(to: sample(fps: 24)).fps, 24, "light 以外は fps を変えない")
    }

    func testPresetScalesTextLikeResolutionChange() {
        let p = sample()      // 1280x720, 字幕 60
        let q = ExportPreset.youtube1080.apply(to: p)
        XCTAssertEqual(q, p.scaledForResolution(newWidth: 1920, newHeight: 1080).withCodec("h264"))
        XCTAssertEqual(q.tracks[0].clips[0].fontSize, 90)
    }

    func testApplyReturnsACopyAndNeverChangesTheOriginal() {
        let p = sample(codec: "h264")
        let before = p
        for preset in ExportPreset.allCases { _ = preset.apply(to: p) }
        XCTAssertEqual(p, before)
        XCTAssertEqual(ExportJob.resolvedProject(p, preset: nil), p)
        XCTAssertEqual(ExportJob.resolvedProject(p, preset: .youtube4k).codec, "hevc")
    }

    func testNamesAndCliKeys() {
        XCTAssertEqual(ExportPreset.allCases.map(\.title), ["YouTube 1080p", "YouTube 1080p60", "YouTube 4K", "ショート縦", "YouTube Shorts", "TikTok", "Instagram リール", "X 720p", "X 1080p", "軽量 720p", "音声のみ"])
        XCTAssertEqual(ExportPreset.allCases.map(\.rawValue), ["youtube1080", "youtube1080p60", "youtube4k", "short", "shorts", "tiktok", "reels", "x720", "x1080", "light", "audio"])
        XCTAssertEqual(ExportPreset.youtube1080.suggestedFileName(documentName: "動画"), "動画-youtube1080.mp4")
        XCTAssertEqual(ExportPreset.audio.suggestedFileName(documentName: "動画"), "動画-audio.m4a")
        XCTAssertEqual(ExportPreset(cliName: "SHORT"), .short)
        XCTAssertNil(ExportPreset(cliName: "nope"))
        XCTAssertEqual(ExportPreset.allCases.filter(\.isAudioOnly), [.audio])
    }

    // MARK: 実際の書き出し(本物の声 + ffprobe)

    private func ffprobe() throws -> String {
        for p in ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe", "/usr/bin/ffprobe"] where FileManager.default.isExecutableFile(atPath: p) { return p }
        throw XCTSkip("ffprobe が無いので実書き出しの確認は飛ばします")
    }

    struct Probe { var streams: [[String: Any]]; var duration: Double
        var video: [String: Any]? { streams.first { $0["codec_type"] as? String == "video" } }
        var audio: [String: Any]? { streams.first { $0["codec_type"] as? String == "audio" } }
    }

    private func probe(_ url: URL) throws -> Probe {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: try ffprobe())
        p.arguments = ["-v", "error", "-print_format", "json", "-show_streams", "-show_format", url.path]
        let pipe = Pipe(); p.standardOutput = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let j = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let d = Double(((j["format"] as? [String: Any])?["duration"] as? String) ?? "") ?? 0
        return Probe(streams: j["streams"] as? [[String: Any]] ?? [], duration: d)
    }

    private func fps(_ s: [String: Any]) -> Double {
        let parts = ((s["avg_frame_rate"] as? String) ?? "0/1").split(separator: "/").compactMap { Double($0) }
        return parts.count == 2 && parts[1] != 0 ? parts[0] / parts[1] : 0
    }

    /// 本物の声(AquesTalk または say)で 1 行だけ作った小さなプロジェクト。
    private func projectWithRealVoice() async throws -> Project {
        var p = sample(w: 640, h: 360, fps: 60)
        p.tracks[0].clips = []
        let provider = RealVoiceProvider(project: p, cache: VoiceCache(directory: tmp.appendingPathComponent("voices")))
        do {
            try await ScriptTimeline.add(lines: ["キャラ1: プリセット"], to: &p, voice: provider, directory: tmp, selectedCharId: p.characters[0].id)
        } catch { throw XCTSkip("声を作れないので飛ばします: \(error.localizedDescription)") }
        var t = Clip(); t.type = .text; t.text = "字幕"; t.start = 0; t.duration = p.endTime; t.fontSize = 60; t.x = 0.5; t.y = 0.3
        p.tracks[4].clips = [t]
        return p
    }

    func testRealExportsOfEveryVideoPresetMatchTheirParametersAndLeaveTheProjectAlone() async throws {
        _ = try ffprobe()
        let p = try await projectWithRealVoice()
        let before = p
        let end = p.endTime
        XCTAssertGreaterThan(end, 0.5)
        let expected: [(ExportPreset, Int, Int, String, Double)] = [
            (.youtube1080, 1920, 1080, "h264", 60), (.youtube4k, 3840, 2160, "hevc", 60),
            (.short, 1080, 1920, "h264", 60), (.light, 1280, 720, "h264", 30),
        ]
        for (preset, w, h, codec, f) in expected {
            let out = tmp.appendingPathComponent("\(preset.rawValue).mp4")
            var last = 0.0
            try await ExportJob.run(project: p, preset: preset, to: out) { last = max(last, $0) }
            XCTAssertEqual(last, 1.0, accuracy: 1e-9, "\(preset) 進み具合が最後まで届く")
            let pr = try probe(out)
            let v = try XCTUnwrap(pr.video, "\(preset)")
            XCTAssertEqual(v["codec_name"] as? String, codec, "\(preset)")
            XCTAssertEqual(v["width"] as? Int, w, "\(preset)")
            XCTAssertEqual(v["height"] as? Int, h, "\(preset)")
            XCTAssertEqual(fps(v), f, accuracy: 0.01, "\(preset)")
            XCTAssertEqual(pr.duration, end, accuracy: 0.1, "\(preset) 長さ")
            let a = try XCTUnwrap(pr.audio, "\(preset) 音声")
            XCTAssertEqual(a["codec_name"] as? String, "aac")
            XCTAssertEqual(p, before, "\(preset) のあとでもプロジェクトは変わらない")
        }
    }

    func testRealAudioOnlyExportHasOnlyAnAacStream() async throws {
        _ = try ffprobe()
        let p = try await projectWithRealVoice()
        let out = tmp.appendingPathComponent("a.m4a")
        var last = 0.0
        try await ExportJob.run(project: p, preset: .audio, to: out) { v in XCTAssertGreaterThanOrEqual(v, last); last = v }
        XCTAssertEqual(last, 1.0, accuracy: 1e-9)
        let pr = try probe(out)
        XCTAssertEqual(pr.streams.count, 1, "音声ストリームだけ")
        XCTAssertNil(pr.video)
        let a = try XCTUnwrap(pr.audio)
        XCTAssertEqual(a["codec_name"] as? String, "aac")
        XCTAssertEqual(a["sample_rate"] as? String, "48000")
        XCTAssertEqual(a["channels"] as? Int, 2)
        XCTAssertEqual(pr.duration, p.endTime, accuracy: 0.1)
        // 256 kbps 指定(AAC なので実測は少し低くなる)
        let br = Double((a["bit_rate"] as? String) ?? "") ?? 0
        XCTAssertGreaterThan(br, 100_000)
        XCTAssertLessThanOrEqual(br, 300_000)
    }

    func testAudioOnlyWithoutAnySoundFailsClearlyAndLeavesNoFile() async throws {
        let p = sample()
        let out = tmp.appendingPathComponent("none.m4a")
        do {
            try await ExportJob.run(project: p, preset: .audio, to: out)
            XCTFail("音が無いのに成功した")
        } catch let e as ExportError {
            guard case .noAudio = e else { return XCTFail("\(e)") }
            XCTAssertNotNil(e.errorDescription)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
    }

    func testAudioOnlyEmptyProjectIsRejected() async {
        var p = Project.new(); p.tracks = [Track(name: "1")]
        do { try await AudioExporter.export(project: p, to: tmp.appendingPathComponent("e.m4a")); XCTFail() }
        catch let e as ExportError { guard case .emptyProject = e else { return XCTFail("\(e)") } }
        catch { XCTFail("\(error)") }
    }

    func testCancelledAudioExportThrowsCancellationAndRemovesTheFile() async throws {
        var p = Project.new()
        p.tracks = [Track(name: "1")]
        let wav = tmp.appendingPathComponent("long.wav")
        try ToneVoiceProvider.writeTone(to: wav, duration: 30, frequency: 220)
        var v = Clip(); v.type = .audio; v.src = wav.path; v.start = 0; v.duration = 30; v.srcDuration = 30
        p.tracks[0].clips = [v]
        let out = tmp.appendingPathComponent("c.m4a")
        let task = Task { try await AudioExporter.export(project: p, to: out) }
        task.cancel()
        do { try await task.value; XCTFail("キャンセルが効かなかった") } catch is CancellationError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
    }
}

private extension Project {
    func withCodec(_ c: String) -> Project { var p = self; p.codec = c; return p }
}
