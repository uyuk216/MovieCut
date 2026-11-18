import XCTest
import CoreGraphics
import ImageIO
import AVFoundation
@testable import MovieCutCore

/// W3-25 連番PNG+WAV(#70)/ W3-26 exo(#71)/ F-3 WebVideo ラウドネス引き継ぎの検証。
final class PngWavExoExportTests: XCTestCase {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pngwav-exo-tests-\(UUID().uuidString)")
    override func setUpWithError() throws { try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    /// 赤背景 + 文字クリップ(音声なし)。
    private func silentProject(width: Int = 160, height: Int = 90, duration: Double = 0.5, fps: Double = 10) -> Project {
        var p = Project.new()
        p.width = width; p.height = height; p.fps = fps; p.bg = "#FF0000"
        var t = Clip(); t.type = .text; t.text = "PNG"; t.start = 0; t.duration = duration; t.fontSize = 40; t.x = 0.5; t.y = 0.5
        p.tracks[4].clips.append(t)
        return p
    }

    /// 小さい音量の正弦波 WAV(44.1kHz モノラル)を作り、その音声クリップ + 文字のプロジェクトを返す。
    private func toneProject(amplitude: Float = 0.02, duration: Double = 2) throws -> Project {
        let sr = 44100
        let samples = (0..<Int(Double(sr) * duration)).map { i in Double(amplitude) * sin(2 * Double.pi * 440 * Double(i) / Double(sr)) }
        let url = tmp.appendingPathComponent("tone.wav")
        try BuiltInSounds.wavData(samples.map { Float($0) }, sampleRate: sr).write(to: url)
        var p = Project.new()
        p.width = 160; p.height = 90; p.fps = 10
        var a = Clip(); a.type = .audio; a.src = url.path; a.start = 0; a.duration = duration
        var t = Clip(); t.type = .text; t.text = "音"; t.start = 0; t.duration = duration; t.fontSize = 40; t.x = 0.5; t.y = 0.5
        p.tracks[3].clips.append(a)
        p.tracks[4].clips.append(t)
        return p
    }

    private func pngInfo(_ url: URL) throws -> (width: Int, height: Int, pixels: [UInt8]) {
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil), "PNG として開けない")
        let img = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        var d = [UInt8](repeating: 0, count: img.width * img.height * 4)
        let ctx = CGContext(data: &d, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return (img.width, img.height, d)
    }

    // MARK: 連番 PNG + WAV: 計画と命名

    func testPngWavPlanAndNaming() {
        let p = silentProject(duration: 2, fps: 30)
        let plan = PngWavExporter.plan(project: p, options: PngWavOptions(base: "frame"))
        XCTAssertEqual(plan.frameCount, 60)
        XCTAssertEqual(plan.digits, 6, "最低 6 桁")
        XCTAssertEqual(plan.firstFileName, "frame_000001.png")
        XCTAssertEqual(plan.lastFileName, "frame_000060.png")
        XCTAssertEqual(plan.wavFileName, "frame.wav")
        XCTAssertEqual(PngWavExporter.digits(frameCount: 1_234_567), 7, "コマ数が多いと桁が増える")
        XCTAssertEqual(PngWavExporter.fileName(base: "shot", index: 42, digits: 6), "shot_000042.png")
        // 範囲指定は長さで数える
        let ranged = PngWavExporter.plan(project: p, range: ExportRange(start: 0.5, end: 1.5), options: PngWavOptions(base: "frame"))
        XCTAssertEqual(ranged.frameCount, 30)
    }

    // MARK: 連番 PNG + WAV: 実書き出し(無音プロジェクト)

    func testPngWavExportSilentProject() async throws {
        let dir = tmp.appendingPathComponent("out-silent")
        let r = try await PngWavExporter.export(project: silentProject(), options: PngWavOptions(base: "frame"), to: dir)
        XCTAssertEqual(r.frameCount, 5, "0.5 秒 × 10 fps")
        XCTAssertEqual(r.files, (1...5).map { String(format: "frame_%06d.png", $0) })
        for name in r.files { XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path), name) }
        // 画素: サイズはプロジェクトどおり、隅は背景の赤
        let info = try pngInfo(dir.appendingPathComponent("frame_000001.png"))
        XCTAssertEqual(info.width, 160); XCTAssertEqual(info.height, 90)
        XCTAssertGreaterThan(info.pixels[0], 200, "左上の赤成分")
        XCTAssertLessThan(info.pixels[1], 60, "左上の緑成分")
        // WAV: 無音でも尺いっぱい入る(同期用)
        XCTAssertFalse(r.hasAudio)
        let winfo = try WavFileWriter.info(of: r.wavURL)
        XCTAssertEqual(winfo.sampleRate, 48000)
        XCTAssertEqual(winfo.channels, 2)
        XCTAssertEqual(winfo.duration, 0.5, accuracy: 0.02)
        XCTAssertEqual(r.wavDuration, 0.5, accuracy: 0.02)
    }

    // MARK: 連番 PNG + WAV: 音声つき + ラウドネス

    func testPngWavExportWithAudioAndLoudnessDifference() async throws {
        let p = try toneProject()
        let plainDir = tmp.appendingPathComponent("out-plain")
        let plain = try await PngWavExporter.export(project: p, options: PngWavOptions(base: "take"), to: plainDir)
        XCTAssertTrue(plain.hasAudio)
        XCTAssertEqual(plain.frameCount, 20, "2 秒 × 10 fps")
        let plainReport = try LoudnessAnalysis.measureFile(plain.wavURL)
        XCTAssertTrue(plainReport.integrated.isFinite)
        XCTAssertLessThan(plainReport.integrated, -25, "元のトーンは小さい")

        let normDir = tmp.appendingPathComponent("out-norm")
        let norm = try await PngWavExporter.export(project: p, options: PngWavOptions(base: "take", loudness: .enabled(targetLUFS: -14)), to: normDir)
        let normReport = try LoudnessAnalysis.measureFile(norm.wavURL)
        XCTAssertEqual(normReport.integrated, -14, accuracy: 1.5, "目標ラウドネスに近づく")
        XCTAssertGreaterThan(normReport.integrated, plainReport.integrated + 5)
        // WAV の長さは正規化しても変わらない
        XCTAssertEqual(norm.wavDuration, plain.wavDuration, accuracy: 0.02)
    }

    // MARK: 連番 PNG + WAV: キャンセルでファイルを残さない

    func testPngWavExportCancellationCleansUp() async throws {
        var p = Project.new()
        p.width = 640; p.height = 360; p.fps = 60
        var t = Clip(); t.type = .text; t.text = "長い"; t.start = 0; t.duration = 10; t.fontSize = 60; t.x = 0.5; t.y = 0.5
        p.tracks[4].clips.append(t)
        let dir = tmp.appendingPathComponent("out-cancel")
        let task = Task { try await PngWavExporter.export(project: p, options: PngWavOptions(base: "frame"), to: dir) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("キャンセルされたら CancellationError のはず")
        } catch is CancellationError {
            // 期待どおり
        }
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        XCTAssertEqual(leftovers.filter { $0.hasSuffix(".png") || $0.hasSuffix(".wav") }, [], "途中のファイルを残さない")
    }

    // MARK: exo: 単位変換

    func testExoFrameConversionAndTextHex() {
        XCTAssertEqual(ExoExporter.startFrame(0, fps: 30), 1)
        XCTAssertEqual(ExoExporter.startFrame(1, fps: 30), 31)
        XCTAssertEqual(ExoExporter.endFrame(start: 0, duration: 2, fps: 30), 60)
        XCTAssertEqual(ExoExporter.endFrame(start: 1, duration: 0.5, fps: 30), 45)
        let hex = ExoExporter.hexText("あA")
        XCTAssertEqual(ExoExporter.decodeHexText(hex), "あA", "UTF-16LE 16 進の往復")
        XCTAssertEqual(ExoExporter.exoColor("#FF8000"), "ff8000")
        XCTAssertNil(ExoExporter.exoColor("red"))
    }

    // MARK: exo: 構造の往復

    func testExoExportRoundTrip() throws {
        var p = Project.new()
        p.width = 320; p.height = 180; p.fps = 30
        var img = Clip(); img.type = .image; img.src = "/素材/背景.png"; img.start = 0; img.duration = 2; img.x = 0.5; img.y = 0.5
        var txt = Clip(); txt.type = .text; txt.text = "こんにちは"; txt.start = 1; txt.duration = 1.5; txt.fontSize = 48; txt.color = "#FF0000"; txt.x = 0.5; txt.y = 0.8
        txt.keyframes = ["x": [Keyframe(t: 0, v: 0.5)]]
        var aud = Clip(); aud.type = .audio; aud.src = "/素材/bgm.wav"; aud.start = 0; aud.duration = 2; aud.volume = 0.5
        var shape = Clip(); shape.type = .shape; shape.start = 0; shape.duration = 1
        p.tracks[0].clips = [img]
        p.tracks[1].clips = [aud]
        p.tracks[2].clips = [txt, shape]

        let out = ExoExporter.export(project: p)
        let doc = try XCTUnwrap(ExoParser.parse(out.text), "自前パーサで読める")
        XCTAssertEqual(doc.header["width"], "320")
        XCTAssertEqual(doc.header["height"], "180")
        XCTAssertEqual(doc.header["rate"], "30")
        XCTAssertEqual(doc.header["length"], "75", "2.5 秒 × 30 fps")
        XCTAssertEqual(doc.objects.count, 3, "図形は落ちて 3 件")
        // 画像: レイヤー 1、1〜60 フレーム
        let o0 = doc.objects[0]
        XCTAssertEqual(o0.layer, 1); XCTAssertEqual(o0.start, 1); XCTAssertEqual(o0.end, 60)
        XCTAssertEqual(o0.effectNames, ["画像ファイル", "標準描画"])
        XCTAssertEqual(o0.sections["0.0"]?["file"], "/素材/背景.png")
        // 音声: 音量 50
        let o1 = doc.objects[1]
        XCTAssertEqual(o1.effectNames, ["音声ファイル", "標準再生"])
        XCTAssertEqual(o1.sections["1.1"]?["音量"], "50")
        // テキスト: 31〜75 フレーム、本文が 16 進から戻る
        let o2 = doc.objects[2]
        XCTAssertEqual(o2.start, 31); XCTAssertEqual(o2.end, 75)
        XCTAssertEqual(o2.effectNames.first, "テキスト")
        XCTAssertEqual(o2.sections["2.0"]?["テキスト"].flatMap { ExoExporter.decodeHexText($0) }, "こんにちは")
        XCTAssertEqual(o2.sections["2.0"]?["サイズ"], "48")
        XCTAssertEqual(o2.sections["2.0"]?["color"], "ff0000")
        // レポート: 図形は unsupported、キーフレームは droppedFeatures
        XCTAssertEqual(out.report.convertedCount, 3)
        XCTAssertEqual(out.report.unsupported.map { $0.typeName }, ["shape"])
        XCTAssertTrue(out.report.droppedFeatures.contains { $0.feature.contains("キーフレーム") })
        XCTAssertTrue(out.report.hasLoss)
        // Shift_JIS のバイト列からも同じ構造が読める
        let doc2 = try XCTUnwrap(ExoParser.parse(data: out.data))
        XCTAssertEqual(doc2.objects.count, 3)
        XCTAssertEqual(doc2.header["length"], "75")
    }

    func testExoVoiceWithoutSourceIsUnsupported() {
        var p = Project.new()
        p.width = 320; p.height = 180; p.fps = 30
        var v = Clip(); v.type = .voice; v.text = "セリフ"; v.start = 0; v.duration = 1
        p.tracks[0].clips = [v]
        let out = ExoExporter.export(project: p)
        XCTAssertEqual(out.report.convertedCount, 0)
        XCTAssertEqual(out.report.unsupported.first?.typeName, "voice")
    }

    // MARK: F-3: WebVideo 書き出しへのラウドネス引き継ぎ

    func testWebVideoLoudnessPassthrough() async throws {
        guard let ffmpeg = FFmpegLocator.find() else { throw XCTSkip("ffmpeg が無い環境") }
        let encoders = FFmpegLocator.availableEncoders(at: ffmpeg)
        try XCTSkipIf(WebVideoFormat.webmVP9.unavailableReason(encoders: encoders, ffmpegFound: true) != nil, "VP9/Opus エンコーダが無い環境")
        let p = try toneProject()

        func exportAndMeasure(loudness: LoudnessNormalizationSettings, name: String) async throws -> LoudnessReport {
            let webm = tmp.appendingPathComponent("\(name).webm")
            try await FFmpegVideoExporter.export(project: p, format: .webmVP9, to: webm, loudness: loudness)
            // 音声だけ WAV(48kHz ステレオ)に戻して、通常の計測で比べる
            let wav = tmp.appendingPathComponent("\(name).wav")
            let proc = Process()
            proc.executableURL = ffmpeg
            proc.arguments = ["-hide_banner", "-y", "-i", webm.path, "-vn", "-ar", "48000", "-ac", "2", wav.path]
            proc.standardOutput = Pipe(); proc.standardError = Pipe()
            try proc.run(); proc.waitUntilExit()
            XCTAssertEqual(proc.terminationStatus, 0, "ffmpeg で音声を取り出せる")
            return try LoudnessAnalysis.measureFile(wav)
        }

        let plain = try await exportAndMeasure(loudness: .disabled, name: "web-plain")
        let norm = try await exportAndMeasure(loudness: .enabled(targetLUFS: -14), name: "web-norm")
        XCTAssertTrue(plain.integrated.isFinite); XCTAssertTrue(norm.integrated.isFinite)
        XCTAssertGreaterThan(norm.integrated, plain.integrated + 5, "WebVideo でも正規化が効く")
        XCTAssertEqual(norm.integrated, -14, accuracy: 3.0, "目標付近になる(コーデック変換の誤差は許す)")
    }
}
