import XCTest
@testable import MovieCutCore

/// 追加出力形式(ffmpeg 任意バックエンド)の検証。
/// 純粋部分(エンコーダ一覧のパース・可否判定・引数)は常時、実書き出しは ffmpeg と
/// 必要なエンコーダがある環境でのみ実行する(無い環境では理由を確認してスキップ)。
/// アニメーション WebP は img2webp 予備道の判定・引数計画・実書き出しも対象。
final class FFmpegExportTests: XCTestCase {

    // MARK: エンコーダ一覧のパース

    func testParseEncoders() {
        let sample = """
         Encoders:
         V..... = Video
         A..... = Audio
         ------
         V....D libvpx-vp9           libvpx VP9 (codec vp9)
         V..... libsvtav1            SVT-AV1 encoder (codec av1)
         A....D libopus              Opus (codec opus)
         V....D gif                  GIF (codec gif)
        """
        let encoders = FFmpegLocator.parseEncoders(sample)
        XCTAssertTrue(encoders.contains("libvpx-vp9"))
        XCTAssertTrue(encoders.contains("libsvtav1"))
        XCTAssertTrue(encoders.contains("libopus"))
        XCTAssertTrue(encoders.contains("gif"))
        XCTAssertFalse(encoders.contains("Encoders:"))
        XCTAssertFalse(encoders.contains("Video"))
    }

    // MARK: 可否判定(届かない形式は理由が返る)

    func testUnavailableReasons() {
        XCTAssertNotNil(WebVideoFormat.webmVP9.unavailableReason(encoders: nil, ffmpegFound: false), "ffmpeg が無い")
        XCTAssertNotNil(WebVideoFormat.webmVP9.unavailableReason(encoders: [], ffmpegFound: true), "エンコーダが無い")
        XCTAssertNil(WebVideoFormat.webmVP9.unavailableReason(encoders: ["libvpx-vp9", "libopus"], ffmpegFound: true))
        XCTAssertNotNil(WebVideoFormat.webmAV1.unavailableReason(encoders: ["libvpx-vp9", "libopus"], ffmpegFound: true), "AV1 エンコーダが無い")
        XCTAssertNil(WebVideoFormat.webmAV1.unavailableReason(encoders: ["libaom-av1", "libopus"], ffmpegFound: true), "libaom-av1 でも可")
        // 対象 Mac の実態: libwebp 系が無い ffmpeg では WebP が書けない理由が返る
        XCTAssertNotNil(WebVideoFormat.animatedWebP.unavailableReason(encoders: ["libvpx-vp9", "libsvtav1", "libopus"], ffmpegFound: true))
        XCTAssertNil(WebVideoFormat.animatedWebP.unavailableReason(encoders: ["libwebp_anim"], ffmpegFound: true))
        XCTAssertNil(WebVideoFormat.mp4AV1.unavailableReason(encoders: ["libsvtav1", "aac"], ffmpegFound: true))
        // img2webp 予備道: ffmpeg に libwebp が無くても、img2webp があれば WebP は書ける
        XCTAssertNil(WebVideoFormat.animatedWebP.unavailableReason(encoders: ["libvpx-vp9", "libsvtav1", "libopus"], ffmpegFound: true, img2webpFound: true))
        XCTAssertNotNil(WebVideoFormat.animatedWebP.unavailableReason(encoders: ["libvpx-vp9"], ffmpegFound: true, img2webpFound: false), "どちらも無ければ従来どおり不可")
        XCTAssertNotNil(WebVideoFormat.animatedWebP.unavailableReason(encoders: ["libwebp_anim"], ffmpegFound: false, img2webpFound: true), "予備道もフレーム取り出しに ffmpeg が要る")
        // 他形式は img2webp があっても従来どおり
        XCTAssertNotNil(WebVideoFormat.webmVP9.unavailableReason(encoders: [], ffmpegFound: true, img2webpFound: true))
    }

    func testFormatMetadata() {
        XCTAssertEqual(WebVideoFormat.webmVP9.fileExtension, "webm")
        XCTAssertEqual(WebVideoFormat.webmAV1.fileExtension, "webm")
        XCTAssertEqual(WebVideoFormat.mp4AV1.fileExtension, "mp4")
        XCTAssertEqual(WebVideoFormat.animatedWebP.fileExtension, "webp")
        let args = WebVideoFormat.webmVP9.ffmpegArguments(videoEncoder: "libvpx-vp9", crf: 30)
        XCTAssertTrue(args.contains("libvpx-vp9"))
        XCTAssertTrue(args.contains("libopus"))
        let webpArgs = WebVideoFormat.animatedWebP.ffmpegArguments(videoEncoder: "libwebp_anim", crf: 30)
        XCTAssertTrue(webpArgs.contains("-an"), "WebP は音なし")
    }

    // MARK: img2webp 予備道(検出・引数計画)

    func testImg2WebPLocatorHonorsEnvironment() {
        // 環境変数が最優先。実行できる既存ファイル(/bin/ls)を指せば、そのまま返る
        setenv("MOVIECUT_IMG2WEBP", "/bin/ls", 1)
        defer { unsetenv("MOVIECUT_IMG2WEBP") }
        XCTAssertEqual(Img2WebPLocator.find()?.path, "/bin/ls")
    }

    func testImg2WebPFrameDurations() {
        XCTAssertEqual(Img2WebPComposer.frameDurationsMs(frameCount: 10, fps: 10), Array(repeating: 100, count: 10))
        let d30 = Img2WebPComposer.frameDurationsMs(frameCount: 30, fps: 30)
        XCTAssertEqual(d30.reduce(0, +), 1000, "30fps × 30 コマで合計ちょうど 1 秒")
        XCTAssertTrue(d30.allSatisfy { $0 == 33 || $0 == 34 }, "33/34ms の配分: \(d30)")
        XCTAssertEqual(Img2WebPComposer.frameDurationsMs(frameCount: 0, fps: 30), [])
        XCTAssertEqual(Img2WebPComposer.frameDurationsMs(frameCount: 5, fps: 0), [])
    }

    func testImg2WebPArguments() {
        let args = Img2WebPComposer.arguments(frameFiles: ["/t/f1.png", "/t/f2.png", "/t/f3.png"], durationsMs: [100, 100, 200])
        XCTAssertEqual(args.prefix(2), ["-loop", "0"], "無限ループ")
        XCTAssertTrue(args.contains("-lossy"))
        XCTAssertTrue(args.contains("\(Img2WebPComposer.quality)"))
        // -d は値が変わるときだけ、対象フレームの直前に出る
        let dIndices = args.indices.filter { args[$0] == "-d" }
        XCTAssertEqual(dIndices.count, 2)
        XCTAssertEqual(args[dIndices[0] + 1], "100")
        XCTAssertEqual(args[dIndices[1] + 1], "200")
        XCTAssertEqual(args.filter { $0.hasSuffix(".png") }, ["/t/f1.png", "/t/f2.png", "/t/f3.png"], "フレームは渡した順")
    }

    // MARK: 実書き出しスモーク(環境があるときだけ)

    private func tinyProject() -> Project {
        var p = Project.new()
        p.width = 320; p.height = 180; p.fps = 30
        var t = Clip(); t.type = .text; t.text = "WebM"; t.start = 0; t.duration = 0.5; t.fontSize = 48; t.x = 0.5; t.y = 0.5
        p.tracks[4].clips.append(t)
        return p
    }

    func testWebMVP9SmokeExport() async throws {
        guard let ffmpeg = FFmpegLocator.find() else { throw XCTSkip("ffmpeg が無い環境") }
        let encoders = FFmpegLocator.availableEncoders(at: ffmpeg)
        try XCTSkipIf(WebVideoFormat.webmVP9.unavailableReason(encoders: encoders, ffmpegFound: true) != nil, "VP9/Opus エンコーダが無い環境")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("webm-smoke-\(UUID().uuidString).webm")
        defer { try? FileManager.default.removeItem(at: url) }
        try await FFmpegVideoExporter.export(project: tinyProject(), format: .webmVP9, to: url)
        let data = try Data(contentsOf: url)
        XCTAssertGreaterThan(data.count, 100)
        // WebM は EBML ヘッダ(1A 45 DF A3)で始まる
        XCTAssertEqual(Array(data.prefix(4)), [0x1A, 0x45, 0xDF, 0xA3], "WebM の EBML ヘッダ")
    }

    func testMP4AV1SmokeExport() async throws {
        guard let ffmpeg = FFmpegLocator.find() else { throw XCTSkip("ffmpeg が無い環境") }
        let encoders = FFmpegLocator.availableEncoders(at: ffmpeg)
        try XCTSkipIf(WebVideoFormat.mp4AV1.unavailableReason(encoders: encoders, ffmpegFound: true) != nil, "AV1 エンコーダが無い環境")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("av1-smoke-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        try await FFmpegVideoExporter.export(project: tinyProject(), format: .mp4AV1, to: url)
        let data = try Data(contentsOf: url)
        XCTAssertGreaterThan(data.count, 100)
        // MP4 は 4 バイト目から "ftyp"
        XCTAssertEqual(String(decoding: data[4..<8], as: UTF8.self), "ftyp", "MP4 の ftyp ボックス")
    }

    func testWebPReportsUnavailableWhenEncoderMissing() async throws {
        guard let ffmpeg = FFmpegLocator.find() else { throw XCTSkip("ffmpeg が無い環境") }
        let encoders = FFmpegLocator.availableEncoders(at: ffmpeg)
        // ffmpeg の libwebp も img2webp も無い環境だけが対象(どちらかあれば書けてしまう)
        try XCTSkipIf(WebVideoFormat.animatedWebP.unavailableReason(encoders: encoders, ffmpegFound: true, img2webpFound: Img2WebPLocator.find() != nil) == nil, "WebP を書けるツールがある環境では対象外")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("webp-\(UUID().uuidString).webp")
        do {
            try await FFmpegVideoExporter.export(project: tinyProject(), format: .animatedWebP, to: url)
            XCTFail("エンコーダが無いのに成功した")
        } catch let e as FFmpegExportError {
            XCTAssertTrue((e.errorDescription ?? "").contains("WebP"), "理由に形式名が入る: \(e.errorDescription ?? "")")
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "失敗時にファイルは残らない")
        }
    }

    /// WebP スモーク専用: 途中で絵が変わるプロジェクト。
    /// img2webp は同一コマを 1 コマに畳む(静止したタイムラインだと静止画 WebP になる)ため、
    /// アニメーションとして成立するかを見るには中身が動くプロジェクトが要る。
    private func animatedWebPProject() -> Project {
        var p = Project.new()
        p.width = 320; p.height = 180; p.fps = 30
        var t1 = Clip(); t1.type = .text; t1.text = "前半"; t1.start = 0; t1.duration = 0.25; t1.fontSize = 48; t1.x = 0.5; t1.y = 0.5
        var t2 = Clip(); t2.type = .text; t2.text = "後半は別の絵"; t2.start = 0.25; t2.duration = 0.25; t2.fontSize = 48; t2.x = 0.5; t2.y = 0.5
        p.tracks[4].clips.append(contentsOf: [t1, t2])
        return p
    }

    func testAnimatedWebPSmokeExport() async throws {
        guard let ffmpeg = FFmpegLocator.find() else { throw XCTSkip("ffmpeg が無い環境") }
        let encoders = FFmpegLocator.availableEncoders(at: ffmpeg)
        // 対象 Mac では ffmpeg に libwebp が無いので、このスモークが img2webp 予備道の実書き出しになる
        try XCTSkipIf(WebVideoFormat.animatedWebP.unavailableReason(encoders: encoders, ffmpegFound: true, img2webpFound: Img2WebPLocator.find() != nil) != nil, "WebP を書けるツールが無い環境")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("webp-smoke-\(UUID().uuidString).webp")
        defer { try? FileManager.default.removeItem(at: url) }
        try await FFmpegVideoExporter.export(project: animatedWebPProject(), format: .animatedWebP, to: url)
        let data = try Data(contentsOf: url)
        XCTAssertGreaterThan(data.count, 100)
        // RIFF ヘッダ + WEBP フォームタイプ
        XCTAssertEqual(Array(data.prefix(4)), Array("RIFF".utf8))
        XCTAssertEqual(Array(data[8..<12]), Array("WEBP".utf8))
        // VP8X チャンク(オフセット 12)のフラグ(オフセット 20)にアニメーションビット(0x02)が立つ
        XCTAssertGreaterThan(data.count, 21)
        XCTAssertTrue(data[20] & 0x02 != 0, "アニメーション WebP として成立している")
    }

    /// AV1 の予備エンコーダ libaom-av1 には -preset が無い(起動エラーになる)ので、専用の引数になること。
    func testAV1ArgumentsForLibaom() {
        for format in [WebVideoFormat.webmAV1, WebVideoFormat.mp4AV1] {
            let args = format.ffmpegArguments(videoEncoder: "libaom-av1", crf: 30)
            XCTAssertFalse(args.contains("-preset"), "\(format): \(args)")
            XCTAssertTrue(args.contains("-cpu-used"), "\(format): \(args)")
            // CRF を効かせるには -b:v 0 が要る(VP9 と同じ)
            if let i = args.firstIndex(of: "-b:v") { XCTAssertEqual(args[i + 1], "0") } else { XCTFail("\(format): -b:v が無い") }
            let svt = format.ffmpegArguments(videoEncoder: "libsvtav1", crf: 30)
            XCTAssertTrue(svt.contains("-preset"), "\(format): SVT 側は従来どおり")
        }
    }
}
