import Foundation

/// 追加の出力形式(WebM / AV1 / アニメーション WebP)のための、**任意**の外部エンコーダ(ffmpeg)バックエンド。
///
/// ## 調査結果と方針(2026-11-19、対象 Mac で実測)
/// - AVFoundation には VP9 / AV1 のエンコーダも WebM の muxer も無い(`AVFileType.webM` 自体が無い)。
/// - ImageIO の書き出し先にも WebP が無い(対応一覧に `org.webmproject.webp` が含まれない)。
/// - そのため、これらの形式は OS 標準の枠組みだけでは書けない。MovieCut 本体は「ffmpeg 不要」が原則なので、
///   ここでは **ffmpeg が見つかったときだけ使える任意バックエンド**とし、無ければ理由つきのエラーを返す
///   (本体の起動・MP4 等の既存書き出しには一切影響しない)。
/// - 対象 Mac の Homebrew ffmpeg は libvpx-vp9 / libsvtav1(AV1)/ libopus を持ち、WebM(VP9)・WebM(AV1)・
///   MP4(AV1)の実エンコードを確認済み。一方 libwebp 系エンコーダは入っていないため、アニメーション WebP は
///   この Mac では書けない(エンコーダが見つかれば自動で有効になる)。
/// - 描画は既存の `Exporter`(MP4・高画質の中間ファイル)に任せ、ffmpeg はコーデック変換だけを行う。
///   ラウドネス正規化など既存の書き出し経路はそのまま中間ファイルに反映される。
public enum FFmpegExportError: LocalizedError {
    case ffmpegNotFound
    case encoderMissing(format: String, encoder: String)
    case unavailable(format: String, reason: String)
    case ffmpegFailed(String)
    case emptyProject

    public var errorDescription: String? {
        switch self {
        case .ffmpegNotFound:
            return "ffmpeg が見つかりません。この形式の書き出しには ffmpeg が必要です(Homebrew なら brew install ffmpeg)。MP4 / MOV / GIF / APNG は ffmpeg なしで書き出せます"
        case .unavailable(let format, let reason):
            return "\(format) は書けません: \(reason)"
        case .encoderMissing(let format, let encoder):
            return "\(format) に必要なエンコーダ(\(encoder))が、お使いの ffmpeg に入っていません"
        case .ffmpegFailed(let tail):
            return "ffmpeg での変換に失敗しました: \(tail)"
        case .emptyProject:
            return "タイムラインが空です"
        }
    }
}

/// 追加形式の定義と、必要なエンコーダ。
public enum WebVideoFormat: String, CaseIterable, Sendable {
    case webmVP9
    case webmAV1
    case mp4AV1
    case animatedWebP

    public var title: String {
        switch self {
        case .webmVP9: return "WebM (VP9)"
        case .webmAV1: return "WebM (AV1)"
        case .mp4AV1: return "MP4 (AV1)"
        case .animatedWebP: return "アニメーション WebP"
        }
    }

    public var fileExtension: String {
        switch self {
        case .webmVP9, .webmAV1: return "webm"
        case .mp4AV1: return "mp4"
        case .animatedWebP: return "webp"
        }
    }

    /// 映像エンコーダの候補(先に見つかったものを使う)。
    public var videoEncoderCandidates: [String] {
        switch self {
        case .webmVP9: return ["libvpx-vp9"]
        case .webmAV1, .mp4AV1: return ["libsvtav1", "libaom-av1"]
        case .animatedWebP: return ["libwebp_anim", "libwebp"]
        }
    }

    /// 音声エンコーダ(WebP は音なし)。
    public var audioEncoder: String? {
        switch self {
        case .webmVP9, .webmAV1: return "libopus"
        case .mp4AV1: return "aac"
        case .animatedWebP: return nil
        }
    }

    /// この形式が今の環境で書けるか。書けないときは理由(日本語)を返す。書けるときは nil。
    public func unavailableReason(encoders: Set<String>?, ffmpegFound: Bool) -> String? {
        guard ffmpegFound else { return "ffmpeg が見つからないため" }
        guard let encoders else { return "ffmpeg のエンコーダ一覧を取得できないため" }
        if !videoEncoderCandidates.contains(where: { encoders.contains($0) }) {
            return "ffmpeg に \(videoEncoderCandidates.joined(separator: " / ")) エンコーダが無いため"
        }
        if let audio = audioEncoder, !encoders.contains(audio) {
            return "ffmpeg に \(audio) エンコーダが無いため"
        }
        return nil
    }

    /// ffmpeg の muxer 名(`-f`)。出力先が一時名でも形式を明示できるようにする。
    public var ffmpegFormat: String {
        switch self {
        case .webmVP9, .webmAV1: return "webm"
        case .mp4AV1: return "mp4"
        case .animatedWebP: return "webp"
        }
    }

    /// ffmpeg の引数(入力・出力は呼び出し側が前後に付ける)。`crf` は画質(小さいほど高画質)。
    public func ffmpegArguments(videoEncoder: String, crf: Int) -> [String] {
        switch self {
        case .webmVP9:
            return ["-c:v", videoEncoder, "-b:v", "0", "-crf", "\(crf)", "-c:a", "libopus", "-b:a", "128k"]
        case .webmAV1:
            return ["-c:v", videoEncoder, "-crf", "\(crf)", "-preset", "8", "-c:a", "libopus", "-b:a", "128k"]
        case .mp4AV1:
            return ["-c:v", videoEncoder, "-crf", "\(crf)", "-preset", "8", "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart"]
        case .animatedWebP:
            return ["-c:v", videoEncoder, "-loop", "0", "-an"]
        }
    }
}

/// ffmpeg の場所探しと能力確認。
public enum FFmpegLocator {
    /// 探す場所(環境変数 `MOVIECUT_FFMPEG` が最優先)。
    public static func find() -> URL? {
        let fm = FileManager.default
        var candidates: [String] = []
        if let custom = ProcessInfo.processInfo.environment["MOVIECUT_FFMPEG"], !custom.isEmpty { candidates.append(custom) }
        candidates += ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map { String($0) + "/ffmpeg" }
        }
        for c in candidates where fm.isExecutableFile(atPath: c) { return URL(fileURLWithPath: c) }
        return nil
    }

    /// `ffmpeg -encoders` の出力からエンコーダ名の集合を取り出す(純粋関数・テスト対象)。
    public static func parseEncoders(_ output: String) -> Set<String> {
        var names = Set<String>()
        for line in output.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            // 行の形: " V....D libvpx-vp9  説明..."(先頭は種別フラグ)
            guard parts.count >= 2, parts[0].count >= 2, parts[0].allSatisfy({ "VASDIL.|=-".contains($0) }) else { continue }
            names.insert(parts[1])
        }
        return names
    }

    /// 実行してエンコーダ集合を得る。失敗したら nil。
    public static func availableEncoders(at ffmpeg: URL) -> Set<String>? {
        let proc = Process()
        proc.executableURL = ffmpeg
        proc.arguments = ["-hide_banner", "-encoders"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do { try proc.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        return parseEncoders(String(decoding: data, as: UTF8.self))
    }
}

/// 追加形式の書き出し本体。中間 MP4(既存 `Exporter`)→ ffmpeg 変換の 2 段。
public enum FFmpegVideoExporter {
    /// 中間 MP4 のビットレート(再エンコード前提なので高め。最終画質は crf で決まる)。
    public static let intermediateBitrate = 40_000_000

    /// 書き出し。進み具合は中間書き出しが 0〜0.7、変換が 0.7〜1。
    public static func export(project: Project, assets: RenderAssets = RenderAssets(), range: ExportRange? = nil,
                              format: WebVideoFormat, crf: Int = 32, to url: URL,
                              progress: ((Double) -> Void)? = nil) async throws {
        guard project.endTime > 0 else { throw FFmpegExportError.emptyProject }
        guard let ffmpeg = FFmpegLocator.find() else { throw FFmpegExportError.ffmpegNotFound }
        let encoders = FFmpegLocator.availableEncoders(at: ffmpeg)
        if let reason = format.unavailableReason(encoders: encoders, ffmpegFound: true) {
            throw FFmpegExportError.unavailable(format: format.title, reason: reason)
        }
        guard let videoEncoder = format.videoEncoderCandidates.first(where: { encoders?.contains($0) == true }) else {
            throw FFmpegExportError.encoderMissing(format: format.title, encoder: format.videoEncoderCandidates.first ?? "?")
        }

        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("moviecut-ffmpeg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let intermediate = tmpDir.appendingPathComponent("intermediate.mp4")
        var intermediateProject = project
        intermediateProject.codec = "h264"
        try await Exporter(project: intermediateProject, assets: assets, range: range, videoBitrate: intermediateBitrate)
            .export(to: intermediate) { v in progress?(v * 0.7) }
        if Task.isCancelled { throw CancellationError() }

        let part = url.deletingLastPathComponent().appendingPathComponent(".moviecut-\(UUID().uuidString).part.\(format.fileExtension)")
        defer { try? FileManager.default.removeItem(at: part) }
        let duration = range?.duration ?? project.endTime
        try await runFFmpeg(ffmpeg, arguments: ["-hide_banner", "-y", "-i", intermediate.path]
            + format.ffmpegArguments(videoEncoder: videoEncoder, crf: crf)
            + ["-f", format.ffmpegFormat, "-progress", "pipe:1", "-nostats", part.path], duration: duration) { v in
            progress?(0.7 + v * 0.3)
        }
        try? FileManager.default.removeItem(at: url)
        do { try FileManager.default.moveItem(at: part, to: url) } catch { throw FFmpegExportError.ffmpegFailed(error.localizedDescription) }
        progress?(1.0)
    }

    /// ffmpeg を実行し、`-progress` の `out_time_ms` から進み具合を出す。失敗時は標準エラーの末尾つきで投げる。
    private static func runFFmpeg(_ ffmpeg: URL, arguments: [String], duration: Double, progress: @escaping (Double) -> Void) async throws {
        let box = ProcessBox()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let proc = Process()
                box.process = proc
                proc.executableURL = ffmpeg
                proc.arguments = arguments
                let outPipe = Pipe()
                let errPipe = Pipe()
                proc.standardOutput = outPipe
                proc.standardError = errPipe
                let errBuffer = ErrorTail()
                errPipe.fileHandleForReading.readabilityHandler = { h in errBuffer.append(h.availableData) }
                outPipe.fileHandleForReading.readabilityHandler = { h in
                    let data = h.availableData
                    guard !data.isEmpty, duration > 0 else { return }
                    let text = String(decoding: data, as: UTF8.self)
                    for line in text.split(separator: "\n") where line.hasPrefix("out_time_ms=") {
                        if let us = Double(line.dropFirst("out_time_ms=".count)) {
                            progress(min(0.99, max(0, us / 1_000_000 / duration)))
                        }
                    }
                }
                proc.terminationHandler = { p in
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    if box.cancelled {
                        cont.resume(throwing: CancellationError())
                    } else if p.terminationStatus == 0 {
                        cont.resume()
                    } else {
                        cont.resume(throwing: FFmpegExportError.ffmpegFailed(errBuffer.tail))
                    }
                }
                do { try proc.run() } catch { cont.resume(throwing: FFmpegExportError.ffmpegFailed(error.localizedDescription)) }
            }
        } onCancel: {
            box.cancel()
        }
    }

    private final class ProcessBox: @unchecked Sendable {
        private let lock = NSLock()
        var process: Process?
        private var _cancelled = false
        var cancelled: Bool { lock.withLock { _cancelled } }
        func cancel() {
            lock.withLock { _cancelled = true }
            process?.terminate()
        }
    }

    /// 標準エラーの末尾(2KB)だけを持つ。
    private final class ErrorTail: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ chunk: Data) {
            lock.withLock {
                data.append(chunk)
                if data.count > 2048 { data = data.suffix(2048) }
            }
        }
        var tail: String { lock.withLock { String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) } }
    }
}
