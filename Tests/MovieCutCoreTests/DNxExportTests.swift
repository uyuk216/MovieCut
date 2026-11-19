import XCTest
@testable import MovieCutCore

/// DNxHR 書き出し(ffmpeg 任意バックエンドへの追加形式)の検証。
/// 純粋部分(プロファイル定義・引数生成・可否判定・サイズ検証)は常時、
/// 実書き出しは ffmpeg と dnxhd エンコーダがある環境でのみ実行する(無い環境ではスキップ)。
/// 引数の根拠は対象 Mac の ffmpeg 9.0.2 の `ffmpeg -h encoder=dnxhd` 実測と
/// ASWF Encoding Guidelines「DNxHD Encoding」(docs/DNxHR書き出し.md 参照)。
final class DNxExportTests: XCTestCase {

    // MARK: プロファイル定義

    func testProfileMetadata() {
        // ffmpegProfile は `-profile:v` の値そのもの(ffmpeg -h encoder=dnxhd の実測と一致すること)
        XCTAssertEqual(DNxHRProfile.lb.ffmpegProfile, "dnxhr_lb")
        XCTAssertEqual(DNxHRProfile.sq.ffmpegProfile, "dnxhr_sq")
        XCTAssertEqual(DNxHRProfile.hq.ffmpegProfile, "dnxhr_hq")
        XCTAssertEqual(DNxHRProfile.hqx.ffmpegProfile, "dnxhr_hqx")
        XCTAssertEqual(DNxHRProfile.finishing444.ffmpegProfile, "dnxhr_444")
        XCTAssertEqual(DNxHRProfile.allCases.count, 5)
        // ピクセル形式はエンコーダ対応形式(yuv422p / yuv422p10le / yuv444p10le / gbrp10le)の中から選ぶ
        XCTAssertEqual(DNxHRProfile.lb.pixelFormat, "yuv422p")
        XCTAssertEqual(DNxHRProfile.sq.pixelFormat, "yuv422p")
        XCTAssertEqual(DNxHRProfile.hq.pixelFormat, "yuv422p")
        XCTAssertEqual(DNxHRProfile.hqx.pixelFormat, "yuv422p10le")
        XCTAssertEqual(DNxHRProfile.finishing444.pixelFormat, "yuv444p10le")
        // ビット深度・色差
        XCTAssertEqual(DNxHRProfile.lb.bitDepth, 8)
        XCTAssertEqual(DNxHRProfile.hq.bitDepth, 8)
        XCTAssertEqual(DNxHRProfile.hqx.bitDepth, 10)
        XCTAssertEqual(DNxHRProfile.finishing444.bitDepth, 10)
        XCTAssertEqual(DNxHRProfile.hq.chromaSubsampling, "4:2:2")
        XCTAssertEqual(DNxHRProfile.finishing444.chromaSubsampling, "4:4:4")
        // 音声は無圧縮 PCM(映像のビット深度に合わせる)
        XCTAssertEqual(DNxHRProfile.lb.audioEncoder, "pcm_s16le")
        XCTAssertEqual(DNxHRProfile.hq.audioEncoder, "pcm_s16le")
        XCTAssertEqual(DNxHRProfile.hqx.audioEncoder, "pcm_s24le")
        XCTAssertEqual(DNxHRProfile.finishing444.audioEncoder, "pcm_s24le")
        // 表示名
        XCTAssertEqual(DNxHRProfile.hq.title, "DNxHR HQ")
        XCTAssertEqual(DNxHRProfile.lb.title, "DNxHR LB")
    }

    func testParseEncodersIncludesDNxHD() {
        // 対象 Mac の ffmpeg 9.0.2 の実出力の形(dnxhd はフラグに F を含む "VFS..D")
        let sample = """
         Encoders:
         V..... = Video
         A..... = Audio
         ------
         VFS..D dnxhd                VC3/DNxHD
         A..... pcm_s16le            PCM signed 16-bit little-endian
         A..... pcm_s24le            PCM signed 24-bit little-endian
         V....D libvpx-vp9           libvpx VP9 (codec vp9)
        """
        let encoders = FFmpegLocator.parseEncoders(sample)
        XCTAssertTrue(encoders.contains("dnxhd"), "F フラグ付きの dnxhd 行を取りこぼさない")
        XCTAssertTrue(encoders.contains("pcm_s16le"))
        XCTAssertTrue(encoders.contains("pcm_s24le"))
        XCTAssertTrue(encoders.contains("libvpx-vp9"), "従来の行も従来どおり")
    }

    // MARK: 形式(WebVideoFormat)側の定義

    func testFormatMetadata() {
        XCTAssertEqual(WebVideoFormat.allCases.count, 9, "従来 4 形式 + DNxHR 5 プロファイル")
        for (format, profile) in [(WebVideoFormat.dnxhrLB, DNxHRProfile.lb), (.dnxhrSQ, .sq), (.dnxhrHQ, .hq), (.dnxhrHQX, .hqx), (.dnxhr444, .finishing444)] {
            XCTAssertEqual(format.dnxProfile, profile)
            XCTAssertTrue(format.isDNx)
            XCTAssertEqual(format.title, profile.title)
            XCTAssertEqual(format.fileExtension, "mov", "DNxHR は MOV コンテナ")
            XCTAssertEqual(format.ffmpegFormat, "mov")
            XCTAssertEqual(format.videoEncoderCandidates, ["dnxhd"])
            XCTAssertEqual(format.audioEncoder, profile.audioEncoder, "形式とプロファイルで音声エンコーダが一致する")
        }
        // 従来形式は DNx ではない(挙動を変えていないことの確認)
        for format in [WebVideoFormat.webmVP9, .webmAV1, .mp4AV1, .animatedWebP] {
            XCTAssertNil(format.dnxProfile)
            XCTAssertFalse(format.isDNx)
        }
    }

    func testFFmpegArguments() {
        XCTAssertEqual(WebVideoFormat.dnxhrHQ.ffmpegArguments(videoEncoder: "dnxhd", crf: 32),
                       ["-c:v", "dnxhd", "-profile:v", "dnxhr_hq", "-pix_fmt", "yuv422p", "-c:a", "pcm_s16le"])
        XCTAssertEqual(WebVideoFormat.dnxhrLB.ffmpegArguments(videoEncoder: "dnxhd", crf: 32),
                       ["-c:v", "dnxhd", "-profile:v", "dnxhr_lb", "-pix_fmt", "yuv422p", "-c:a", "pcm_s16le"])
        XCTAssertEqual(WebVideoFormat.dnxhrHQX.ffmpegArguments(videoEncoder: "dnxhd", crf: 32),
                       ["-c:v", "dnxhd", "-profile:v", "dnxhr_hqx", "-pix_fmt", "yuv422p10le", "-c:a", "pcm_s24le"])
        XCTAssertEqual(WebVideoFormat.dnxhr444.ffmpegArguments(videoEncoder: "dnxhd", crf: 32),
                       ["-c:v", "dnxhd", "-profile:v", "dnxhr_444", "-pix_fmt", "yuv444p10le", "-c:a", "pcm_s24le"])
        // DNxHR のビットレートはプロファイルから自動決定されるため、-b:v / -crf は付けない(crf 引数は無視される)
        for format in [WebVideoFormat.dnxhrLB, .dnxhrSQ, .dnxhrHQ, .dnxhrHQX, .dnxhr444] {
            let args = format.ffmpegArguments(videoEncoder: "dnxhd", crf: 10)
            XCTAssertFalse(args.contains("-b:v"), "\(format.title) に -b:v を付けない")
            XCTAssertFalse(args.contains("-crf"), "\(format.title) に -crf を付けない")
        }
    }

    func testExistingFormatArgumentsUnchanged() {
        // 追加にあたって従来形式の引数が変わっていないこと
        XCTAssertEqual(WebVideoFormat.webmVP9.ffmpegArguments(videoEncoder: "libvpx-vp9", crf: 30),
                       ["-c:v", "libvpx-vp9", "-b:v", "0", "-crf", "30", "-c:a", "libopus", "-b:a", "128k"])
        XCTAssertEqual(WebVideoFormat.animatedWebP.ffmpegArguments(videoEncoder: "libwebp_anim", crf: 30),
                       ["-c:v", "libwebp_anim", "-loop", "0", "-an"])
    }

    // MARK: 可否判定

    func testUnavailableReasons() {
        XCTAssertNotNil(WebVideoFormat.dnxhrHQ.unavailableReason(encoders: nil, ffmpegFound: false), "ffmpeg が無い")
        XCTAssertNotNil(WebVideoFormat.dnxhrHQ.unavailableReason(encoders: ["libvpx-vp9", "pcm_s16le"], ffmpegFound: true), "dnxhd エンコーダが無い")
        XCTAssertNotNil(WebVideoFormat.dnxhrHQ.unavailableReason(encoders: ["dnxhd"], ffmpegFound: true), "PCM エンコーダが無い")
        XCTAssertNil(WebVideoFormat.dnxhrHQ.unavailableReason(encoders: ["dnxhd", "pcm_s16le"], ffmpegFound: true))
        XCTAssertNil(WebVideoFormat.dnxhrHQX.unavailableReason(encoders: ["dnxhd", "pcm_s24le"], ffmpegFound: true))
        XCTAssertNotNil(WebVideoFormat.dnxhrHQX.unavailableReason(encoders: ["dnxhd", "pcm_s16le"], ffmpegFound: true), "HQX は pcm_s24le が要る")
    }

    // MARK: サイズ・fps の対応範囲

    func testValidation() {
        XCTAssertNil(DNxHRProfile.validationError(width: 1920, height: 1080, fps: 29.97))
        XCTAssertNil(DNxHRProfile.validationError(width: 3840, height: 2160, fps: 59.94))
        XCTAssertNil(DNxHRProfile.validationError(width: 256, height: 120, fps: 24), "下限ちょうどは可")
        XCTAssertNil(DNxHRProfile.validationError(width: 320, height: 180, fps: 30))
        XCTAssertNotNil(DNxHRProfile.validationError(width: 254, height: 120, fps: 30), "幅が下限未満")
        XCTAssertNotNil(DNxHRProfile.validationError(width: 256, height: 118, fps: 30), "高さが下限未満")
        // 奇数サイズは偶数化してから判定する(中間書き出しの挙動に合わせる)
        XCTAssertNil(DNxHRProfile.validationError(width: 257, height: 121, fps: 30), "偶数化後は 256×120 で可")
        XCTAssertNotNil(DNxHRProfile.validationError(width: 255, height: 121, fps: 30), "偶数化後は 254×120 で不可")
        // fps の範囲(MovieCut の入力範囲 1〜240)
        XCTAssertNil(DNxHRProfile.validationError(width: 1920, height: 1080, fps: 23.976))
        XCTAssertNotNil(DNxHRProfile.validationError(width: 1920, height: 1080, fps: 0))
        XCTAssertNotNil(DNxHRProfile.validationError(width: 1920, height: 1080, fps: 300))
        XCTAssertNotNil(DNxHRProfile.validationError(width: 1920, height: 1080, fps: .nan))
        // 大きすぎるサイズは MovieCut の書き出し上限で止める
        XCTAssertNotNil(DNxHRProfile.validationError(width: 8192, height: 8192, fps: 30))
    }

    // MARK: 中間ファイルの計画

    func testIntermediateCodec() {
        XCTAssertEqual(DNxExport.intermediateCodec(for: .finishing444), OutputPlan.proRes4444, "4:4:4 は ProRes 4444 中間")
        XCTAssertEqual(DNxExport.intermediateCodec(for: .hqx), OutputPlan.proRes422, "10ビット 4:2:2 は ProRes 422 中間")
        XCTAssertEqual(DNxExport.intermediateCodec(for: .hq), OutputPlan.proRes422)
        XCTAssertEqual(DNxExport.intermediateCodec(for: .lb), OutputPlan.proRes422)
        XCTAssertEqual(DNxExport.intermediateFileExtension, "mov")
    }

    // MARK: 実書き出しスモーク(環境があるときだけ)

    private func tinyProject() -> Project {
        var p = Project.new()
        p.width = 320; p.height = 180; p.fps = 30
        var t = Clip(); t.type = .text; t.text = "DNx"; t.start = 0; t.duration = 0.5; t.fontSize = 48; t.x = 0.5; t.y = 0.5
        p.tracks[4].clips.append(t)
        return p
    }

    private func findFFprobe() -> URL? {
        let fm = FileManager.default
        var candidates = ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe"]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map { String($0) + "/ffprobe" }
        }
        for c in candidates where fm.isExecutableFile(atPath: c) { return URL(fileURLWithPath: c) }
        return nil
    }

    private func probeVideo(_ url: URL) -> String? {
        guard let ffprobe = findFFprobe() else { return nil }
        let proc = Process()
        proc.executableURL = ffprobe
        proc.arguments = ["-v", "error", "-select_streams", "v:0",
                          "-show_entries", "stream=codec_name,profile,pix_fmt,width,height",
                          "-of", "default=noprint_wrappers=1", url.path]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do { try proc.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private func smokeExport(format: WebVideoFormat, expectedPixFmt: String) async throws {
        guard let ffmpeg = FFmpegLocator.find() else { throw XCTSkip("ffmpeg が無い環境") }
        let encoders = FFmpegLocator.availableEncoders(at: ffmpeg)
        try XCTSkipIf(format.unavailableReason(encoders: encoders, ffmpegFound: true) != nil, "dnxhd / PCM エンコーダが無い環境")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dnx-smoke-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        try await FFmpegVideoExporter.export(project: tinyProject(), format: format, to: url)
        let data = try Data(contentsOf: url)
        XCTAssertGreaterThan(data.count, 1000, "DNxHR は中間コーデックのため小さな素材でも相応の大きさになる")
        // MOV は 4 バイト目から "ftyp"
        XCTAssertEqual(String(decoding: data[4..<8], as: UTF8.self), "ftyp", "MOV の ftyp ボックス")
        if let probe = probeVideo(url) {
            XCTAssertTrue(probe.contains("codec_name=dnxhd"), "映像コーデックは dnxhd: \(probe)")
            XCTAssertTrue(probe.contains("pix_fmt=\(expectedPixFmt)"), "ピクセル形式: \(probe)")
            XCTAssertTrue(probe.contains("DNXHR"), "プロファイルは DNXHR 系: \(probe)")
            XCTAssertTrue(probe.contains("width=320"), "幅: \(probe)")
            XCTAssertTrue(probe.contains("height=180"), "高さ: \(probe)")
        }
    }

    func testDNxHRHQSmokeExport() async throws {
        try await smokeExport(format: .dnxhrHQ, expectedPixFmt: "yuv422p")
    }

    func testDNxHRLBSmokeExport() async throws {
        try await smokeExport(format: .dnxhrLB, expectedPixFmt: "yuv422p")
    }

    func testDNxHRHQXSmokeExport() async throws {
        try await smokeExport(format: .dnxhrHQX, expectedPixFmt: "yuv422p10le")
    }

    func testDNxRejectsTooSmallProject() async throws {
        guard let ffmpeg = FFmpegLocator.find() else { throw XCTSkip("ffmpeg が無い環境") }
        let encoders = FFmpegLocator.availableEncoders(at: ffmpeg)
        try XCTSkipIf(WebVideoFormat.dnxhrHQ.unavailableReason(encoders: encoders, ffmpegFound: true) != nil, "dnxhd / PCM エンコーダが無い環境")
        var p = tinyProject()
        p.width = 160; p.height = 90
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dnx-small-\(UUID().uuidString).mov")
        do {
            try await FFmpegVideoExporter.export(project: p, format: .dnxhrHQ, to: url)
            XCTFail("小さすぎるサイズで成功した")
        } catch let e as FFmpegExportError {
            XCTAssertTrue((e.errorDescription ?? "").contains("DNxHR"), "理由に DNxHR が入る: \(e.errorDescription ?? "")")
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "失敗時にファイルは残らない")
        }
    }
}
