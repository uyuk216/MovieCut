import XCTest
@testable import MovieCutCore

/// 追加出力形式(ffmpeg 任意バックエンド)の検証。
/// 純粋部分(エンコーダ一覧のパース・可否判定・引数)は常時、実書き出しは ffmpeg と
/// 必要なエンコーダがある環境でのみ実行する(無い環境では理由を確認してスキップ)。
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
        try XCTSkipIf(WebVideoFormat.animatedWebP.unavailableReason(encoders: encoders, ffmpegFound: true) == nil, "WebP エンコーダがある環境では対象外")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("webp-\(UUID().uuidString).webp")
        do {
            try await FFmpegVideoExporter.export(project: tinyProject(), format: .animatedWebP, to: url)
            XCTFail("エンコーダが無いのに成功した")
        } catch let e as FFmpegExportError {
            XCTAssertTrue((e.errorDescription ?? "").contains("WebP"), "理由に形式名が入る: \(e.errorDescription ?? "")")
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "失敗時にファイルは残らない")
        }
    }
}
