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
///   MP4(AV1)の実エンコードを確認済み。一方 libwebp 系エンコーダは入っていない(ffmpeg 9.0.2 で再確認)。
/// - アニメーション WebP の予備道(2026-11-19 追加): Homebrew の `webp` パッケージには、静止画を束ねて
///   アニメーション WebP に合成する `img2webp` があり、対象 Mac でも実エンコードを確認済み(10 コマ・
///   各 100ms・ループ 0 で書き、webpinfo の ANIM/ANMF チャンクと ffprobe の webp_anim で成立を確認)。
///   そのため WebP は「ffmpeg に libwebp 系がある」か「img2webp が見つかる(中間 MP4 から ffmpeg で
///   PNG 連番を取り出し、img2webp で合成する)」のどちらかで書ける。どちらも無ければ従来どおり理由つきで不可。
///   cwebp は静止画専用なので予備道には使わない。中間 MP4 経由のため、透明(アルファ)は保持されない
///   (従来の ffmpeg 経路と同じ)。img2webp は同一コマを 1 コマに畳む(表示時間は合算される)ため、
///   タイムライン全体が静止している場合は静止画 WebP になる。
/// - 描画は既存の `Exporter`(MP4・高画質の中間ファイル)に任せ、ffmpeg はコーデック変換だけを行う。
///   ラウドネス正規化など既存の書き出し経路はそのまま中間ファイルに反映される。
public enum FFmpegExportError: LocalizedError {
    case ffmpegNotFound
    case encoderMissing(format: String, encoder: String)
    case unavailable(format: String, reason: String)
    case ffmpegFailed(String)
    case img2webpFailed(String)
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
        case .img2webpFailed(let tail):
            return "img2webp でのアニメーション WebP 合成に失敗しました: \(tail)"
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
    case dnxhrLB
    case dnxhrSQ
    case dnxhrHQ
    case dnxhrHQX
    case dnxhr444

    public var title: String {
        switch self {
        case .webmVP9: return "WebM (VP9)"
        case .webmAV1: return "WebM (AV1)"
        case .mp4AV1: return "MP4 (AV1)"
        case .animatedWebP: return "アニメーション WebP"
        case .dnxhrLB: return "DNxHR LB"
        case .dnxhrSQ: return "DNxHR SQ"
        case .dnxhrHQ: return "DNxHR HQ"
        case .dnxhrHQX: return "DNxHR HQX"
        case .dnxhr444: return "DNxHR 444"
        }
    }

    /// DNxHR 形式のときのプロファイル。それ以外は nil(詳細は `DNxExport.swift`)。
    public var dnxProfile: DNxHRProfile? {
        switch self {
        case .dnxhrLB: return .lb
        case .dnxhrSQ: return .sq
        case .dnxhrHQ: return .hq
        case .dnxhrHQX: return .hqx
        case .dnxhr444: return .finishing444
        case .webmVP9, .webmAV1, .mp4AV1, .animatedWebP: return nil
        }
    }

    /// DNxHR 形式か。
    public var isDNx: Bool { dnxProfile != nil }

    public var fileExtension: String {
        switch self {
        case .webmVP9, .webmAV1: return "webm"
        case .mp4AV1: return "mp4"
        case .animatedWebP: return "webp"
        case .dnxhrLB, .dnxhrSQ, .dnxhrHQ, .dnxhrHQX, .dnxhr444: return "mov"
        }
    }

    /// 映像エンコーダの候補(先に見つかったものを使う)。
    public var videoEncoderCandidates: [String] {
        switch self {
        case .webmVP9: return ["libvpx-vp9"]
        case .webmAV1, .mp4AV1: return ["libsvtav1", "libaom-av1"]
        case .animatedWebP: return ["libwebp_anim", "libwebp"]
        case .dnxhrLB, .dnxhrSQ, .dnxhrHQ, .dnxhrHQX, .dnxhr444: return ["dnxhd"]
        }
    }

    /// 音声エンコーダ(WebP は音なし)。
    public var audioEncoder: String? {
        switch self {
        case .webmVP9, .webmAV1: return "libopus"
        case .mp4AV1: return "aac"
        case .animatedWebP: return nil
        case .dnxhrLB, .dnxhrSQ, .dnxhrHQ: return "pcm_s16le"
        case .dnxhrHQX, .dnxhr444: return "pcm_s24le"
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

    /// `img2webp` の有無も含めた可否判定。アニメーション WebP だけは、ffmpeg に libwebp 系が無くても
    /// img2webp があれば予備道で書ける(予備道でも PNG 連番の取り出しに ffmpeg 自体は要る)。
    /// 他の形式は従来の判定と完全に同じ。
    public func unavailableReason(encoders: Set<String>?, ffmpegFound: Bool, img2webpFound: Bool) -> String? {
        if self == .animatedWebP, ffmpegFound, img2webpFound { return nil }
        return unavailableReason(encoders: encoders, ffmpegFound: ffmpegFound)
    }

    /// ffmpeg の muxer 名(`-f`)。出力先が一時名でも形式を明示できるようにする。
    public var ffmpegFormat: String {
        switch self {
        case .webmVP9, .webmAV1: return "webm"
        case .mp4AV1: return "mp4"
        case .animatedWebP: return "webp"
        case .dnxhrLB, .dnxhrSQ, .dnxhrHQ, .dnxhrHQX, .dnxhr444: return "mov"
        }
    }

    /// ffmpeg の引数(入力・出力は呼び出し側が前後に付ける)。`crf` は画質(小さいほど高画質)。
    public func ffmpegArguments(videoEncoder: String, crf: Int) -> [String] {
        switch self {
        case .webmVP9:
            return ["-c:v", videoEncoder, "-b:v", "0", "-crf", "\(crf)", "-c:a", "libopus", "-b:a", "128k"]
        case .webmAV1:
            // libaom-av1 には -preset が無く(起動エラーになる)、速度は -cpu-used、CRF には -b:v 0 が要る
            if videoEncoder == "libaom-av1" {
                return ["-c:v", videoEncoder, "-b:v", "0", "-crf", "\(crf)", "-cpu-used", "5", "-c:a", "libopus", "-b:a", "128k"]
            }
            return ["-c:v", videoEncoder, "-crf", "\(crf)", "-preset", "8", "-c:a", "libopus", "-b:a", "128k"]
        case .mp4AV1:
            if videoEncoder == "libaom-av1" {
                return ["-c:v", videoEncoder, "-b:v", "0", "-crf", "\(crf)", "-cpu-used", "5", "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart"]
            }
            return ["-c:v", videoEncoder, "-crf", "\(crf)", "-preset", "8", "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart"]
        case .animatedWebP:
            return ["-c:v", videoEncoder, "-loop", "0", "-an"]
        case .dnxhrLB, .dnxhrSQ, .dnxhrHQ, .dnxhrHQX, .dnxhr444:
            // DNxHR: ビットレートはプロファイルとフレームサイズから ffmpeg が自動で決めるため、
            // -b:v も -crf も付けない(付けても効かないことが ASWF ガイドに明記されている)。
            guard let profile = dnxProfile, let audio = audioEncoder else { return ["-c:v", videoEncoder] }
            return ["-c:v", videoEncoder, "-profile:v", profile.ffmpegProfile, "-pix_fmt", profile.pixelFormat, "-c:a", audio]
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
            // フラグ文字には F(フレーム単位の並列化)も含まれる。dnxhd は "VFS..D" のため、
            // F を許さないと dnxhd 行を取りこぼして DNxHR が常時「エンコーダが無い」になる(2026-11-19 発覚)。
            guard parts.count >= 2, parts[0].count >= 2, parts[0].allSatisfy({ "VASFDIL.|=-".contains($0) }) else { continue }
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

/// `img2webp`(Homebrew `webp` パッケージ、同梱の合成ツール)の場所探し。ffmpeg の流儀に揃えた任意バックエンド。
public enum Img2WebPLocator {
    /// 探す場所(環境変数 `MOVIECUT_IMG2WEBP` が最優先)。
    public static func find() -> URL? {
        let fm = FileManager.default
        var candidates: [String] = []
        if let custom = ProcessInfo.processInfo.environment["MOVIECUT_IMG2WEBP"], !custom.isEmpty { candidates.append(custom) }
        candidates += ["/opt/homebrew/bin/img2webp", "/usr/local/bin/img2webp"]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map { String($0) + "/img2webp" }
        }
        for c in candidates where fm.isExecutableFile(atPath: c) { return URL(fileURLWithPath: c) }
        return nil
    }
}

/// img2webp へ渡す引数の計画(純粋関数・テスト対象)。
public enum Img2WebPComposer {
    /// 画質(0〜100)。従来の ffmpeg(libwebp)経路も crf を使っていないので、WebP では crf は使わず固定にする。
    public static let quality = 75

    /// 各コマの表示時間(ms)。1000/fps を 1 コマずつ丸めると合計がずれるので、累積時刻の差分で配る
    /// (例: 30fps → 33, 34, 33, 34, … で、30 コマの合計はちょうど 1000ms)。
    public static func frameDurationsMs(frameCount: Int, fps: Double) -> [Int] {
        guard frameCount > 0, fps > 0, fps.isFinite else { return [] }
        var out: [Int] = []
        out.reserveCapacity(frameCount)
        var prev = 0
        for i in 0..<frameCount {
            let t = Int(((Double(i + 1) * 1000) / fps).rounded())
            out.append(max(1, t - prev))
            prev = t
        }
        return out
    }

    /// img2webp の引数(出力先 `-o` は呼び出し側が足す)。`-d` は後続フレームの表示時間(ms)で、
    /// 値が変わるときだけ差し込む(フレームごとに指定できることを対象 Mac で確認済み)。
    public static func arguments(frameFiles: [String], durationsMs: [Int], loopCount: Int = 0) -> [String] {
        var args = ["-loop", "\(max(0, loopCount))", "-lossy", "-q", "\(quality)"]
        var lastDuration: Int? = nil
        for (i, file) in frameFiles.enumerated() {
            let d = i < durationsMs.count ? durationsMs[i] : (durationsMs.last ?? 100)
            if d != lastDuration { args += ["-d", "\(d)"]; lastDuration = d }
            args.append(file)
        }
        return args
    }
}

/// 追加形式の書き出し本体。中間 MP4(既存 `Exporter`)→ ffmpeg 変換の 2 段。
public enum FFmpegVideoExporter {
    /// 中間 MP4 のビットレート(再エンコード前提なので高め。最終画質は crf で決まる)。
    public static let intermediateBitrate = 40_000_000

    /// 書き出し。進み具合は中間書き出しが 0〜0.7、変換が 0.7〜1。
    /// `loudness` は通常書き出し(MP4 等)と同じ設定で、中間 MP4 の書き出しにそのまま渡す(F-3)。
    /// 既定は無効 = 従来どおり(中間ファイルに正規化をかけない)。
    public static func export(project: Project, assets: RenderAssets = RenderAssets(), range: ExportRange? = nil,
                              format: WebVideoFormat, crf: Int = 32, to url: URL,
                              loudness: LoudnessNormalizationSettings = .disabled,
                              pluginEffectProviders: [any VideoEffectProviding] = [],
                              vst3Provider: (any AudioEffectProviding)? = nil,
                              progress: ((Double) -> Void)? = nil) async throws {
        guard project.endTime > 0 else { throw FFmpegExportError.emptyProject }
        guard let ffmpeg = FFmpegLocator.find() else { throw FFmpegExportError.ffmpegNotFound }
        let encoders = FFmpegLocator.availableEncoders(at: ffmpeg)
        // アニメーション WebP の予備道: ffmpeg に libwebp 系が無くても img2webp があれば書ける
        let img2webp = format == .animatedWebP ? Img2WebPLocator.find() : nil
        let useImg2WebP = format == .animatedWebP
            && !(format.videoEncoderCandidates.contains { encoders?.contains($0) == true })
            && img2webp != nil
        if let reason = format.unavailableReason(encoders: encoders, ffmpegFound: true), !useImg2WebP {
            throw FFmpegExportError.unavailable(format: format.title, reason: reason)
        }
        let videoEncoder = format.videoEncoderCandidates.first(where: { encoders?.contains($0) == true }) ?? ""
        if !useImg2WebP && videoEncoder.isEmpty {
            throw FFmpegExportError.encoderMissing(format: format.title, encoder: format.videoEncoderCandidates.first ?? "?")
        }

        // DNxHR はフレームサイズの下限・上限があるため、中間書き出しの前に確かめる
        // (ffmpeg に進んでから断られると、理由が英語ログの末尾になって分かりにくい)。
        if format.dnxProfile != nil,
           let message = DNxHRProfile.validationError(width: project.width, height: project.height, fps: project.fps) {
            throw FFmpegExportError.unavailable(format: format.title, reason: message)
        }

        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("moviecut-ffmpeg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        // DNxHR の中間は ProRes(他の形式は従来どおり H.264 の MP4)。
        // H.264 中間だと HQX / 444 のビット深度・色差が変換前に落ちてしまうため。
        let intermediate = tmpDir.appendingPathComponent(format.dnxProfile == nil ? "intermediate.mp4" : "intermediate.\(DNxExport.intermediateFileExtension)")
        var intermediateProject = project
        intermediateProject.codec = format.dnxProfile.map { DNxExport.intermediateCodec(for: $0) } ?? "h264"
        try await Exporter(project: intermediateProject, assets: assets, range: range, videoBitrate: intermediateBitrate, loudness: loudness, pluginEffectProviders: pluginEffectProviders, vst3Provider: vst3Provider)
            .export(to: intermediate) { v in progress?(v * 0.7) }
        if Task.isCancelled { throw CancellationError() }

        let part = url.deletingLastPathComponent().appendingPathComponent(".moviecut-\(UUID().uuidString).part.\(format.fileExtension)")
        defer { try? FileManager.default.removeItem(at: part) }
        let duration = range?.duration ?? project.endTime
        if useImg2WebP, let img2webp {
            try await convertToAnimatedWebPViaImg2WebP(ffmpeg: ffmpeg, img2webp: img2webp, intermediate: intermediate,
                                                       tmpDir: tmpDir, fps: project.fps, duration: duration, part: part) { v in
                progress?(0.7 + v * 0.3)
            }
        } else {
            try await runFFmpeg(ffmpeg, arguments: ["-hide_banner", "-y", "-i", intermediate.path]
                + format.ffmpegArguments(videoEncoder: videoEncoder, crf: crf)
                + ["-f", format.ffmpegFormat, "-progress", "pipe:1", "-nostats", part.path], duration: duration) { v in
                progress?(0.7 + v * 0.3)
            }
        }
        try? FileManager.default.removeItem(at: url)
        do { try FileManager.default.moveItem(at: part, to: url) } catch { throw FFmpegExportError.ffmpegFailed(error.localizedDescription) }
        progress?(1.0)
    }

    /// アニメーション WebP の予備道: 中間 MP4 から ffmpeg で PNG 連番を取り出し、img2webp で合成する。
    /// 進み具合はこの関数の中では 0〜1(取り出しが 0〜0.8、合成は完了で 1)。
    private static func convertToAnimatedWebPViaImg2WebP(ffmpeg: URL, img2webp: URL, intermediate: URL, tmpDir: URL,
                                                         fps: Double, duration: Double, part: URL,
                                                         progress: @escaping (Double) -> Void) async throws {
        let framesDir = tmpDir.appendingPathComponent("frames")
        try FileManager.default.createDirectory(at: framesDir, withIntermediateDirectories: true)
        let pattern = framesDir.appendingPathComponent("frame%06d.png").path
        try await runFFmpeg(ffmpeg, arguments: ["-hide_banner", "-y", "-i", intermediate.path, "-an",
                                                "-progress", "pipe:1", "-nostats", pattern],
                            duration: duration) { v in progress(v * 0.8) }
        if Task.isCancelled { throw CancellationError() }
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: framesDir.path)) ?? [])
            .filter { $0.hasSuffix(".png") }.sorted()
        guard !names.isEmpty else { throw FFmpegExportError.img2webpFailed("中間 MP4 からフレームを取り出せませんでした") }
        let files = names.map { framesDir.appendingPathComponent($0).path }
        let durations = Img2WebPComposer.frameDurationsMs(frameCount: files.count, fps: fps)
        try await runImg2WebP(img2webp, arguments: Img2WebPComposer.arguments(frameFiles: files, durationsMs: durations) + ["-o", part.path])
        progress(1.0)
    }

    /// img2webp を実行する(進捗出力が無いので待つだけ)。失敗時は標準エラーの末尾つきで投げる。
    private static func runImg2WebP(_ tool: URL, arguments: [String]) async throws {
        let box = ProcessBox()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let proc = Process()
                box.process = proc
                proc.executableURL = tool
                proc.arguments = arguments
                let errPipe = Pipe()
                proc.standardOutput = Pipe()
                proc.standardError = errPipe
                let errBuffer = ErrorTail()
                errPipe.fileHandleForReading.readabilityHandler = { h in errBuffer.append(h.availableData) }
                proc.terminationHandler = { p in
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    if box.cancelled {
                        cont.resume(throwing: CancellationError())
                    } else if p.terminationStatus == 0 {
                        cont.resume()
                    } else {
                        cont.resume(throwing: FFmpegExportError.img2webpFailed(errBuffer.tail))
                    }
                }
                do {
                    guard try box.launch(proc) else {
                        errPipe.fileHandleForReading.readabilityHandler = nil
                        cont.resume(throwing: CancellationError()); return
                    }
                } catch { cont.resume(throwing: FFmpegExportError.img2webpFailed(error.localizedDescription)) }
            }
        } onCancel: {
            box.cancel()
        }
    }

    /// ffmpeg を実行し、`-progress` の `out_time_ms` から進み具合を出す。失敗時は標準エラーの末尾つきで投げる。
    static func runFFmpeg(_ ffmpeg: URL, arguments: [String], duration: Double, progress: @escaping (Double) -> Void) async throws {
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
                do {
                    // 起動前にキャンセル済みなら起動しない(終了通知を待たずここで戻る)
                    guard try box.launch(proc) else {
                        errPipe.fileHandleForReading.readabilityHandler = nil
                        outPipe.fileHandleForReading.readabilityHandler = nil
                        cont.resume(throwing: CancellationError()); return
                    }
                } catch { cont.resume(throwing: FFmpegExportError.ffmpegFailed(error.localizedDescription)) }
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
        private var launched = false
        func cancel() {
            // 未起動のプロセスに terminate を呼ぶと例外になるので、起動済みのときだけ止める
            let p: Process? = lock.withLock { _cancelled = true; return launched ? process : nil }
            p?.terminate()
        }
        /// キャンセル済みなら起動せず false。起動の判定とキャンセルを同じ鍵の中で行う(間に割り込まれない)。
        func launch(_ proc: Process) throws -> Bool {
            try lock.withLock {
                if _cancelled { return false }
                try proc.run()
                launched = true
                return true
            }
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
