import XCTest
import AVFoundation
import CoreMedia
@testable import MovieCutCore

/// MP4 字幕トラック埋め込み(mov_text)の検証。
/// 純粋部分(件の取り出し・隙間の挿入・tx3g のバイト列)は常時、実書き出しは AVAssetWriter で
/// 字幕トラックを読み戻して時刻・テキスト・言語を照合する。
final class SubtitleEmbedTests: XCTestCase {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("subtitle-embed-tests-\(UUID().uuidString)")
    override func setUpWithError() throws { try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    // MARK: 設定

    func testSettingsDefaults() {
        XCTAssertFalse(SubtitleEmbedSettings.disabled.enabled, "既定は埋め込まない(従来どおり)")
        XCTAssertTrue(SubtitleEmbedSettings.japanese.enabled)
        XCTAssertEqual(SubtitleEmbedSettings.japanese.languageCode, "ja")
        XCTAssertEqual(SubtitleEmbedSettings(enabled: true, languageCode: "").languageCode, "ja", "空の言語コードは ja に戻す")
    }

    // MARK: 件の取り出し(純粋な計算)

    /// 字幕レイヤーの文字 2 件 + 土台の文字(通常レイヤー)を持つ 3 秒のプロジェクト。
    private func subtitleProject() -> Project {
        var p = Project.new()
        p.width = 320; p.height = 180; p.fps = 30
        var bg = Clip(); bg.type = .text; bg.text = "背景"; bg.start = 0; bg.duration = 3; bg.x = 0.5; bg.y = 0.5; bg.fontSize = 40
        p.tracks[4].clips.append(bg)
        var layer = Track(name: SubtitleFile.layerName)
        var c1 = Clip(); c1.type = .text; c1.text = "こんにちは、世界"; c1.start = 0.2; c1.duration = 1.0; c1.x = 0.5; c1.y = 0.85; c1.fontSize = 32
        var c2 = Clip(); c2.type = .text; c2.text = "日本語の字幕テストです"; c2.start = 1.5; c2.duration = 1.3; c2.x = 0.5; c2.y = 0.85; c2.fontSize = 32
        layer.clips = [c1, c2]
        p.tracks.append(layer)
        return p
    }

    func testCuesCollectsSubtitleLayerTextOnly() {
        let cues = SubtitleEmbed.cues(from: subtitleProject(), range: nil)
        XCTAssertEqual(cues.count, 2, "通常レイヤーの「背景」は字幕に入らない")
        XCTAssertEqual(cues[0].text, "こんにちは、世界")
        XCTAssertEqual(cues[0].start, 0.2, accuracy: 1e-9)
        XCTAssertEqual(cues[0].end, 1.2, accuracy: 1e-9)
        XCTAssertEqual(cues[1].text, "日本語の字幕テストです")
        XCTAssertEqual(cues[1].start, 1.5, accuracy: 1e-9)
        XCTAssertEqual(cues[1].end, 2.8, accuracy: 1e-9)
    }

    func testCuesCollectsVoiceSubtitles() {
        var p = Project.new()
        var v = Clip(); v.type = .voice; v.start = 0.5; v.duration = 1.5; v.text = "ボイスの字幕"; v.subtitle = true
        p.tracks[0].clips.append(v)
        var off = Clip(); off.type = .voice; off.start = 3; off.duration = 1; off.text = "字幕オフ"; off.subtitle = false
        p.tracks[0].clips.append(off)
        let cues = SubtitleEmbed.cues(from: p, range: nil)
        XCTAssertEqual(cues.map(\.text), ["ボイスの字幕"], "字幕オフのボイスは入らない")
        XCTAssertEqual(cues[0].start, 0.5, accuracy: 1e-9)
        XCTAssertEqual(cues[0].end, 2.0, accuracy: 1e-9)
    }

    func testCuesRangeShiftsAndClips() {
        let cues = SubtitleEmbed.cues(from: subtitleProject(), range: ExportRange(start: 1.0, end: 3.0))
        XCTAssertEqual(cues.count, 2)
        // 0.2〜1.2 は範囲の頭で切れて 0〜0.2、1.5〜2.8 は 0.5〜1.8 へずれる
        XCTAssertEqual(cues[0].start, 0, accuracy: 1e-9)
        XCTAssertEqual(cues[0].end, 0.2, accuracy: 1e-9)
        XCTAssertEqual(cues[1].start, 0.5, accuracy: 1e-9)
        XCTAssertEqual(cues[1].end, 1.8, accuracy: 1e-9)
    }

    func testCuesOutsideRangeAreDropped() {
        let cues = SubtitleEmbed.cues(from: subtitleProject(), range: ExportRange(start: 1.3, end: 1.4))
        XCTAssertEqual(cues, [], "範囲に重ならない件は全部落ちる")
    }

    func testCuesOverlapIsClamped() {
        var p = Project.new()
        var layer = Track(name: SubtitleFile.layerName)
        var c1 = Clip(); c1.type = .text; c1.text = "前"; c1.start = 0; c1.duration = 2
        var c2 = Clip(); c2.type = .text; c2.text = "後"; c2.start = 1; c2.duration = 2
        layer.clips = [c1, c2]
        p.tracks.append(layer)
        let cues = SubtitleEmbed.cues(from: p, range: nil)
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].end, 1.0, accuracy: 1e-9, "重なりは前の件の終わりを詰めて解消する")
        XCTAssertEqual(cues[1].start, 1.0, accuracy: 1e-9)
        XCTAssertEqual(cues[1].end, 3.0, accuracy: 1e-9)
    }

    func testCuesCleanBodyAndDropEmpty() {
        var p = Project.new()
        var layer = Track(name: SubtitleFile.layerName)
        var c1 = Clip(); c1.type = .text; c1.text = "  \n  あ  \n\n"; c1.start = 0; c1.duration = 1
        var c2 = Clip(); c2.type = .text; c2.text = "   \n  "; c2.start = 1; c2.duration = 1
        layer.clips = [c1, c2]
        p.tracks.append(layer)
        let cues = SubtitleEmbed.cues(from: p, range: nil)
        XCTAssertEqual(cues.map(\.text), ["あ"], "サイドカーと同じ作法で整え、空の件は落とす")
    }

    func testNoSubtitlesYieldNoCues() {
        var p = Project.new()
        var t = Clip(); t.type = .text; t.text = "ただの文字"; t.start = 0; t.duration = 2
        p.tracks[4].clips.append(t)
        XCTAssertEqual(SubtitleEmbed.cues(from: p, range: nil), [])
    }

    // MARK: 隙間の挿入(純粋な計算)

    func testSamplesInsertGaps() {
        let cues = [SubtitleCue(start: 0.2, end: 1.2, text: "あ"), SubtitleCue(start: 1.5, end: 2.8, text: "い")]
        let s = SubtitleEmbed.samples(from: cues, trackDuration: 3.0)
        XCTAssertEqual(s.count, 4, "件の間と末尾に空の件が入る")
        XCTAssertEqual(s[0].text, "あ")
        XCTAssertEqual(s[1].text, "")
        XCTAssertEqual(s[1].start, 1.2, accuracy: 1e-9)
        XCTAssertEqual(s[1].end, 1.5, accuracy: 1e-9)
        XCTAssertEqual(s[2].text, "い")
        XCTAssertEqual(s[3].text, "")
        XCTAssertEqual(s[3].start, 2.8, accuracy: 1e-9)
        XCTAssertEqual(s[3].end, 3.0, accuracy: 1e-9)
    }

    func testSamplesNoGapWhenContiguousOrAtEnd() {
        let cues = [SubtitleCue(start: 0, end: 1, text: "あ"), SubtitleCue(start: 1, end: 2, text: "い")]
        XCTAssertEqual(SubtitleEmbed.samples(from: cues, trackDuration: 2.0), cues, "隙間が無ければ何も足さない")
        XCTAssertEqual(SubtitleEmbed.samples(from: [], trackDuration: 2.0), [])
    }

    // MARK: tx3g のバイト列(純粋な計算)

    func testTx3gPayload() {
        let p = SubtitleEmbed.tx3gPayload(text: "あ")
        XCTAssertEqual(Array(p), [0, 3, 0xE3, 0x81, 0x82], "2 バイトの長さ + UTF-8")
        XCTAssertEqual(Array(SubtitleEmbed.tx3gPayload(text: "")), [0, 0], "空は長さ 0")
        let long = SubtitleEmbed.tx3gPayload(text: String(repeating: "あ", count: 30_000))
        XCTAssertEqual(long.count, 2 + 65_535, "上限で文字の途中で切らずに切り詰める")
        XCTAssertEqual((Int(long[0]) << 8) | Int(long[1]), long.count - 2)
    }

    func testFormatDescriptionIsTx3g() throws {
        let fmt = try XCTUnwrap(SubtitleEmbed.makeFormatDescription(width: 320, height: 180))
        XCTAssertEqual(CMFormatDescriptionGetMediaType(fmt), kCMMediaType_Text)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(fmt), kCMTextFormatType_3GText)
    }

    // MARK: 実書き出し(字幕トラックの読み戻し)

    /// 字幕トラックのサンプルを全部読み戻す(pts・長さ・本文)。
    private func readSubtitleSamples(_ url: URL) async throws -> [(start: Double, duration: Double, text: String)] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .text)
        guard let track = tracks.first else { return [] }
        let reader = try XCTUnwrap(try? AVAssetReader(asset: asset), "字幕トラックを読むリーダーを作れない")
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? ExportError.audioReadFailed(nil) }
        var out: [(Double, Double, String)] = []
        while let sb = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sb).seconds
            let dur = CMSampleBufferGetDuration(sb).seconds
            var text = ""
            if let bb = CMSampleBufferGetDataBuffer(sb) {
                let len = CMBlockBufferGetDataLength(bb)
                if len >= 2 {
                    var bytes = [UInt8](repeating: 0, count: len)
                    CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: len, destination: &bytes)
                    let bodyLen = (Int(bytes[0]) << 8) | Int(bytes[1])
                    if len >= 2 + bodyLen { text = String(decoding: bytes[2..<(2 + bodyLen)], as: UTF8.self) }
                }
            }
            out.append((pts, dur, text))
        }
        return out
    }

    func testExportEmbedsSubtitleTrack() async throws {
        let out = tmp.appendingPathComponent("embedded.mp4")
        try await Exporter(project: subtitleProject(), assets: RenderAssets(), subtitleEmbed: .japanese).export(to: out, progress: nil)
        let asset = AVURLAsset(url: out)
        let textTracks = try await asset.loadTracks(withMediaType: .text)
        XCTAssertEqual(textTracks.count, 1, "字幕トラックが 1 本入る")
        let track = try XCTUnwrap(textTracks.first)
        let fds = try await track.load(.formatDescriptions)
        XCTAssertEqual(fds.first.map { CMFormatDescriptionGetMediaSubType($0) }, kCMTextFormatType_3GText, "mov_text(tx3g)形式")
        XCTAssertTrue(["ja", "jpn"].contains(track.languageCode ?? ""), "言語は日本語: \(track.languageCode ?? "nil")")
        // 映像も従来どおり
        let video = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(video.count, 1)
        let total = try await asset.load(.duration).seconds
        XCTAssertEqual(total, 3.0, accuracy: 0.05)

        // AVAssetReader は字幕トラックの開始位置(0.2 秒)を引いた相対時刻で返し、境界に長さ 0 の
        // 空サンプルも足す(ファイル自体のパケット時刻は ffprobe で別途確認済み。docs/MP4字幕埋め込み.md)。
        // ここでは「見える件」の本文・長さ・間隔が元の件と一致することを見る。
        let samples = try await readSubtitleSamples(out)
        let visible = samples.filter { !$0.text.isEmpty }
        XCTAssertEqual(visible.count, 2)
        XCTAssertEqual(visible[0].text, "こんにちは、世界", "日本語が化けない")
        XCTAssertEqual(visible[0].start, 0, accuracy: 0.02, "トラック開始(0.2 秒)からの相対時刻")
        XCTAssertEqual(visible[0].duration, 1.0, accuracy: 0.02, "終わりの時刻が次の件まで伸びない")
        XCTAssertEqual(visible[1].text, "日本語の字幕テストです")
        XCTAssertEqual(visible[1].start, 1.3, accuracy: 0.02, "0.2 秒ずらし + 隙間 0.3 秒を挟んで 1.5 秒地点")
        XCTAssertEqual(visible[1].duration, 1.3, accuracy: 0.02)
        XCTAssertEqual(visible[1].start - (visible[0].start + visible[0].duration), 0.3, accuracy: 0.02, "件の間の隙間が保たれる")
    }

    func testExportWithoutEmbedHasNoSubtitleTrack() async throws {
        let out = tmp.appendingPathComponent("plain.mp4")
        try await Exporter(project: subtitleProject(), assets: RenderAssets()).export(to: out, progress: nil)
        let asset = AVURLAsset(url: out)
        let textCount = try await asset.loadTracks(withMediaType: .text).count
        XCTAssertEqual(textCount, 0, "既定(埋め込みなし)は従来どおり字幕トラックなし")
        let total = try await asset.load(.duration).seconds
        XCTAssertEqual(total, 3.0, accuracy: 0.05)
    }

    func testExportEmbedWithoutSubtitlesHasNoTrack() async throws {
        var p = Project.new()
        p.width = 320; p.height = 180; p.fps = 30
        var bg = Clip(); bg.type = .text; bg.text = "字幕なし"; bg.start = 0; bg.duration = 1; bg.x = 0.5; bg.y = 0.5; bg.fontSize = 40
        p.tracks[4].clips.append(bg)
        let out = tmp.appendingPathComponent("nosubs.mp4")
        try await Exporter(project: p, assets: RenderAssets(), subtitleEmbed: .japanese).export(to: out, progress: nil)
        let asset = AVURLAsset(url: out)
        let textCount = try await asset.loadTracks(withMediaType: .text).count
        XCTAssertEqual(textCount, 0, "字幕が無いプロジェクトでは従来と同一(トラックを作らない)")
        let total = try await asset.load(.duration).seconds
        XCTAssertEqual(total, 1.0, accuracy: 0.05)
    }

    func testExportEmbedWithRange() async throws {
        let out = tmp.appendingPathComponent("ranged.mp4")
        try await Exporter(project: subtitleProject(), assets: RenderAssets(), range: ExportRange(start: 1.0, end: 3.0), subtitleEmbed: .japanese)
            .export(to: out, progress: nil)
        let samples = try await readSubtitleSamples(out)
        let visible = samples.filter { !$0.text.isEmpty }
        XCTAssertEqual(visible.count, 2)
        XCTAssertEqual(visible[0].start, 0, accuracy: 0.02, "範囲の頭に合わせてずれる")
        XCTAssertEqual(visible[0].duration, 0.2, accuracy: 0.02)
        XCTAssertEqual(visible[1].start, 0.5, accuracy: 0.02)
        XCTAssertEqual(visible[1].duration, 1.3, accuracy: 0.02)
    }

    func testExportJobPassesEmbedThrough() async throws {
        let out = tmp.appendingPathComponent("job.mp4")
        try await ExportJob.run(project: subtitleProject(), preset: nil, to: out, subtitleEmbed: .japanese, progress: nil)
        let asset = AVURLAsset(url: out)
        let textCount = try await asset.loadTracks(withMediaType: .text).count
        XCTAssertEqual(textCount, 1, "ExportJob 経由でも埋め込まれる")
    }
}
