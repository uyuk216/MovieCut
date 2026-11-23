import Foundation
import AVFoundation

/// whisper.cpp(外部の実行ファイル `whisper-cli`)で音声を文字にする第 2 のエンジン。
///
/// 安全は AquesTalk と同じ流儀: 実行するのは `WhisperLocator` が決まった場所から探して `ExecutableTrust` で検証したものだけ。
/// 引数は配列で渡し、シェルは通さない。プロジェクトファイルに書かれたパスは使わない。
/// モデルは同梱しない(利用者が `Application Support/MovieCut/Whisper/` に置くか、設定で選ぶ)。
/// Silero VAD(無音区間を先に落とす)の設定。モデルは `ggml-silero-*.bin`(実物は ggml-silero-v5.1.2.bin)。
public struct WhisperVADOptions: Equatable, Sendable {
    public var model: URL
    public var threshold: Double
    public var minSpeechMs: Int
    public var minSilenceMs: Int
    public var speechPadMs: Int

    public init(model: URL, threshold: Double = 0.5, minSpeechMs: Int = 250, minSilenceMs: Int = 100, speechPadMs: Int = 30) {
        self.model = model
        self.threshold = threshold
        self.minSilenceMs = minSilenceMs
        self.minSpeechMs = minSpeechMs
        self.speechPadMs = speechPadMs
    }
}

/// whisper のデコード設定。既定は「精度優先」(ビーム探索 5、温度 0、記号・音楽記号の抑止)。
public struct WhisperOptions: Equatable, Sendable {
    public var beamSize: Int
    public var bestOf: Int
    public var temperature: Double
    public var suppressNonSpeechTokens: Bool
    /// nil なら VAD を使わない。`WhisperTranscriber.init` は VAD モデルが見つかれば自動で入れる。
    public var vad: WhisperVADOptions?

    public init(beamSize: Int = 5, bestOf: Int = 5, temperature: Double = 0.0,
                suppressNonSpeechTokens: Bool = true, vad: WhisperVADOptions? = nil) {
        self.beamSize = beamSize
        self.bestOf = bestOf
        self.temperature = temperature
        self.suppressNonSpeechTokens = suppressNonSpeechTokens
        self.vad = vad
    }
}

public struct WhisperTranscriber: Transcriber {
    /// 検証を通った whisper-cli の実体(無ければ nil = 実行時に `whisperNotInstalled`)。
    public let executable: URL?
    /// 見つかったモデル(無ければ nil = 実行時に `whisperModelMissing`)。
    public let model: URL?
    public let language: String
    /// 実際に使うデコード設定(VAD は init で決まった結果が入っている)。
    public let options: WhisperOptions
    /// true なら、認識の前に音量正規化とノイズ除去をかける(`WhisperPreprocessing`)。
    public let preprocessing: Bool

    /// - `executablePath` / `modelPath`: 試験用に明示指定する(実行ファイルは検証を通す)。nil なら決まった場所から探す。
    /// - `language`: whisper の `-l`。既定は `auto`(whisper の言語自動判定)。日英が混ざった音声でも、各言語のまま出る。
    ///   明示指定(例: ja)はそのまま尊重する。
    /// - `forbiddenRoots`: この下の実行ファイルは使わない(プロジェクト・素材のフォルダ)。
    /// - `options`: デコード設定。`options.vad` が nil でも、VAD モデルが見つかれば自動で有効にする。
    /// - `vadModelPath`: VAD モデルを明示指定する(nil なら決まった場所から探す。見つからなければ VAD なし)。
    /// - `preprocessing`: false なら音量正規化・ノイズ除去をしない。
    public init(executablePath: String? = nil, modelPath: String? = nil, language: String = "auto", forbiddenRoots: [URL] = [],
                options: WhisperOptions = WhisperOptions(), vadModelPath: String? = nil, preprocessing: Bool = true) {
        if let p = executablePath {
            executable = WhisperLocator.validate(path: p, forbiddenRoots: forbiddenRoots)
        } else {
            executable = WhisperLocator.resolve(forbiddenRoots: forbiddenRoots)
        }
        if let m = modelPath {
            model = WhisperLocator.validateModel(path: m)
        } else {
            model = WhisperLocator.resolveModel()
        }
        self.language = language
        self.preprocessing = preprocessing

        var resolved = options
        if resolved.vad == nil {
            let vadURL = vadModelPath.flatMap(WhisperLocator.validateModel(path:)) ?? WhisperLocator.resolveVADModel()
            if let vadURL { resolved.vad = WhisperVADOptions(model: vadURL) }
        }
        self.options = resolved
    }

    /// 進みの目印(stderr の `progress = NN%`)。
    static func progress(inStderrLine line: String) -> Double? {
        guard let r = line.range(of: "progress =") else { return nil }
        let digits = line[r.upperBound...].drop { $0 == " " }.prefix { $0.isNumber }
        guard let n = Double(digits), (0...100).contains(n) else { return nil }
        return n / 100
    }

    /// 実行ファイルに渡す引数(シェルを通さない配列)。
    static func arguments(model: URL, wav: URL, language: String, outputPrefix: URL) -> [String] {
        ["-m", model.path, "-f", wav.path, "-l", language, "-ojf", "-of", outputPrefix.path, "-t", "4", "-pp"]
    }

    /// `options` 付きの引数。先頭 8 要素(`arguments` と同じ並び)はそのまま、後ろにデコード設定と VAD を足す。
    static func arguments(model: URL, wav: URL, language: String, outputPrefix: URL, options: WhisperOptions) -> [String] {
        var a = arguments(model: model, wav: wav, language: language, outputPrefix: outputPrefix)
        a += ["-bs", String(options.beamSize), "-bo", String(options.bestOf), "-tp", String(options.temperature)]
        if options.suppressNonSpeechTokens { a.append("-sns") }
        if let v = options.vad {
            a += ["--vad", "-vm", v.model.path, "-vt", String(v.threshold),
                  "-vspd", String(v.minSpeechMs), "-vsd", String(v.minSilenceMs), "-vp", String(v.speechPadMs)]
        }
        return a
    }

    static func timeout(forDuration d: Double) -> TimeInterval {
        min(3600, max(600, (d.isFinite ? d : 0) * 20))
    }

    public func transcribe(audioURL: URL, duration: Double, onProgress: @escaping @Sendable (Double) -> Void) async throws -> [TranscriptSegment] {
        guard let executable else { throw TranscriptionError.whisperNotInstalled }
        guard let model else { throw TranscriptionError.whisperModelMissing }
        onProgress(0.05)

        let tmp = FileManager.default.temporaryDirectory
        let id = UUID().uuidString
        let wav16 = tmp.appendingPathComponent("moviecut-whisper-\(id).wav")
        let pre = tmp.appendingPathComponent("moviecut-whisper-\(id)-pre.wav")
        let prefix = tmp.appendingPathComponent("moviecut-whisper-\(id)")
        let json = tmp.appendingPathComponent("moviecut-whisper-\(id).json")
        defer {
            try? FileManager.default.removeItem(at: wav16)
            try? FileManager.default.removeItem(at: pre)
            try? FileManager.default.removeItem(at: json)
        }

        let input: URL
        do {
            input = try await Task.detached(priority: .userInitiated) { try WhisperAudioConverter.prepare(input: audioURL, output: wav16) }.value
        } catch let e as TranscriptionError { throw e }
        catch { throw TranscriptionError.failed("音声を 16kHz に変換できませんでした: \(error.localizedDescription)") }
        try Task.checkCancellation()

        // 前処理は精度を上げるための補助。失敗したら元の音声のまま認識する(止めない)。
        // 変換が入力をそのまま返した場合も、入力は書き換えず別の一時ファイルへ書く。
        var whisperInput = input
        if preprocessing {
            do {
                whisperInput = try await Task.detached(priority: .userInitiated) { try WhisperPreprocessing.prepare(input: input, output: pre) }.value
            } catch {
                whisperInput = input
            }
            try Task.checkCancellation()
        }

        // 発話区間ごとに認識し直す。whisper は 1 ファイル 1 言語でデコードするため、途中で言語が変わると後半が欠けるのを避ける。
        // 読めない・区間が 1 つだけのときは、従来どおり 1 回で認識する。
        let decoded = try? await Task.detached(priority: .userInitiated) { try WhisperChunking.readMono(whisperInput) }.value
        let chunks = decoded.map { d in
            WhisperChunking.plan(speechRanges: WhisperChunking.speechRanges(samples: d.samples, sampleRate: d.sampleRate),
                                 duration: Double(d.samples.count) / d.sampleRate)
        } ?? []

        let segments: [TranscriptSegment]
        if let decoded, chunks.count > 1 {
            segments = try await transcribeChunks(executable: executable, model: model, samples: decoded.samples, sampleRate: decoded.sampleRate,
                                                  chunks: chunks, id: id, tmp: tmp, onProgress: onProgress)
        } else {
            try await Self.run(executable: executable,
                               arguments: Self.arguments(model: model, wav: whisperInput, language: language, outputPrefix: prefix, options: options),
                               timeout: Self.timeout(forDuration: duration), onProgress: onProgress)
            try Task.checkCancellation()

            guard let data = try? Data(contentsOf: json) else {
                throw TranscriptionError.failed("whisper が結果(JSON)を出力しませんでした。")
            }
            segments = try WhisperJSONParser.parse(data)
        }
        onProgress(1)
        return segments
    }

    /// 発話区間を 1 つずつ切り出して認識し、全体の時刻に直して開始順に連結する。
    /// 各区間は前後に `WhisperChunking.padSeconds` の余白を付けて認識し、結果は「中心の時刻が自分の持ち分にある」ものだけ採る(隣との重複を避ける)。
    private func transcribeChunks(executable: URL, model: URL, samples: [Float], sampleRate rate: Double,
                                  chunks: [(start: Double, end: Double)], id: String, tmp: URL,
                                  onProgress: @escaping @Sendable (Double) -> Void) async throws -> [TranscriptSegment] {
        let owned = WhisperChunking.ownership(chunks)
        var out: [TranscriptSegment] = []
        for (i, c) in chunks.enumerated() {
            try Task.checkCancellation()
            let a = max(0, Int(((c.start - WhisperChunking.padSeconds) * rate).rounded()))
            let b = min(samples.count, Int(((c.end + WhisperChunking.padSeconds) * rate).rounded()))
            guard b > a else { continue }

            let base = tmp.appendingPathComponent("moviecut-whisper-\(id)-\(i)")
            let wav = base.appendingPathExtension("wav")
            let json = base.appendingPathExtension("json")
            defer {
                try? FileManager.default.removeItem(at: wav)
                try? FileManager.default.removeItem(at: json)
            }
            try WhisperPreprocessing.writeWAV(channels: [Array(samples[a..<b])], sampleRate: rate, to: wav)
            try await Self.run(executable: executable,
                               arguments: Self.arguments(model: model, wav: wav, language: language, outputPrefix: base, options: options),
                               timeout: Self.timeout(forDuration: Double(b - a) / rate),
                               onProgress: { p in onProgress(WhisperChunking.progress(index: i, count: chunks.count, inner: p)) })
            try Task.checkCancellation()

            guard let data = try? Data(contentsOf: json) else {
                throw TranscriptionError.failed("whisper が結果(JSON)を出力しませんでした。")
            }
            let segs = try WhisperJSONParser.parse(data)
            out += WhisperChunking.keep(WhisperChunking.shift(segs, by: Double(a) / rate), owned: owned[i])
            onProgress(WhisperChunking.progress(index: i + 1, count: chunks.count, inner: 0))
        }
        return out
    }

    /// プロセスを起こして終わるまで待つ。キャンセルで terminate、タイムアウトでも terminate。
    /// terminate(SIGTERM)を無視するプロセスは 2 秒後に SIGKILL する(終了ハンドラが必ず呼ばれ、待ちが戻るように)。
    /// 非 0 終了は `TranscriptionError.failed`(stderr の末尾つき)。
    static func run(executable: URL, arguments: [String], timeout: TimeInterval,
                    onProgress: @escaping @Sendable (Double) -> Void) async throws {
        /// SIGTERM → 猶予 2 秒 → SIGKILL の順で確実に止める。
        func terminateForcefully(_ p: Process) {
            guard p.isRunning else { return }
            p.terminate()
            let pid = p.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if p.isRunning { kill(pid, SIGKILL) }
            }
        }
        final class State: @unchecked Sendable {
            let lock = NSLock()
            var process: Process?
            var cancelled = false
            var timedOut = false
            var stderrTail = ""
            var pending = ""
        }
        let state = State()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let p = Process()
                p.executableURL = executable
                p.arguments = arguments
                let err = Pipe()
                p.standardError = err
                p.standardOutput = FileHandle.nullDevice
                p.standardInput = FileHandle.nullDevice

                let consume: @Sendable (Data) -> Void = { data in
                    guard !data.isEmpty else { return }
                    let text = String(decoding: data, as: UTF8.self)
                    var found: Double?
                    state.lock.withLock {
                        state.stderrTail = String((state.stderrTail + text).suffix(2000))
                        state.pending += text
                        // 改行(または \r)までそろった行だけ見る。
                        var lines = state.pending.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r" }).map(String.init)
                        state.pending = lines.removeLast()
                        for l in lines { if let v = progress(inStderrLine: l) { found = v } }
                    }
                    if let v = found { onProgress(min(max(v, 0.05), 0.99)) }
                }
                err.fileHandleForReading.readabilityHandler = { h in consume(h.availableData) }

                p.terminationHandler = { proc in
                    err.fileHandleForReading.readabilityHandler = nil
                    consume(err.fileHandleForReading.readDataToEndOfFile())
                    let (cancelled, late, tail) = state.lock.withLock { (state.cancelled, state.timedOut, state.stderrTail) }
                    if cancelled { cont.resume(throwing: CancellationError()) }
                    else if late { cont.resume(throwing: TranscriptionError.failed("whisper が \(Int(timeout)) 秒以内に終わらなかったので止めました。")) }
                    else if proc.terminationStatus == 0 { cont.resume() }
                    else {
                        let msg = tail.trimmingCharacters(in: .whitespacesAndNewlines).suffix(400)
                        cont.resume(throwing: TranscriptionError.failed("whisper が失敗しました(終了コード \(proc.terminationStatus)): \(msg)"))
                    }
                }
                // 起動前にキャンセルされていたら起こさない。
                let alreadyCancelled: Bool = state.lock.withLock {
                    if state.cancelled { return true }
                    state.process = p
                    return false
                }
                if alreadyCancelled { cont.resume(throwing: CancellationError()); return }
                do { try p.run() } catch {
                    err.fileHandleForReading.readabilityHandler = nil
                    cont.resume(throwing: TranscriptionError.failed("whisper を起動できませんでした: \(error.localizedDescription)"))
                    return
                }
                // run() とキャンセルのすれ違い対策(起動後にもう一度確かめる)。
                if state.lock.withLock({ state.cancelled }), p.isRunning { terminateForcefully(p) }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if p.isRunning { state.lock.withLock { state.timedOut = true }; terminateForcefully(p) }
                }
            }
        } onCancel: {
            let p: Process? = state.lock.withLock { state.cancelled = true; return state.process }
            if let p, p.isRunning { terminateForcefully(p) }
        }
    }
}

// MARK: - 区間ごとの認識(区間計画・時刻のずらし)

/// 発話区間ごとに認識するための計画。無音で区切り、区間ごとに言語を自動判定させる(日英混在でも後半が欠けない)。
/// 区間の計画・時刻のずらし・持ち分の判定は純粋関数で、音声の読み込みだけが I/O。
public enum WhisperChunking {
    /// これより短い区間は次の区間と連結する(短すぎる断片は認識が不安定)。
    public static let minChunkSeconds = 1.5
    /// これを超える区間は、この長さごとに分割する。
    public static let maxChunkSeconds = 30.0
    /// 認識に渡すとき、区間の前後に足す余白(秒)。語頭・語尾を欠かさないため。
    public static let padSeconds = 0.15
    /// 発話区間を取るための無音の設定(最短無音 0.25 秒。文間ポーズ 0.23〜0.34 秒の下限に合わせて、短い間は切らない)。
    public static let speechParams = SilenceParams(thresholdDb: -40, minSilence: 0.25, pad: 0.1)

    /// 発話区間から認識の区間を決める。`speechRanges` は開始順の発話区間(無音を除いた残り)。
    /// 発話が無いとき・計画が空になるときは [(0, duration)] を返す(呼び出し側は 1 区間なら従来どおり 1 回で認識する)。
    public static func plan(speechRanges: [SilenceRange], duration: Double) -> [(start: Double, end: Double)] {
        let whole = [(start: 0.0, end: max(0, duration))]
        guard duration > 0 else { return whole }

        var merged: [(start: Double, end: Double)] = []
        for r in speechRanges {
            let s = max(0, r.start), e = min(duration, r.end)
            guard e > s else { continue }
            if let last = merged.last, last.end - last.start < minChunkSeconds {
                merged[merged.count - 1].end = max(last.end, e)
            } else {
                merged.append((start: s, end: e))
            }
        }

        var out: [(start: Double, end: Double)] = []
        for c in merged {
            var s = c.start
            while c.end - s > maxChunkSeconds {
                out.append((start: s, end: s + maxChunkSeconds))
                s += maxChunkSeconds
            }
            out.append((start: s, end: c.end))
        }
        return out.isEmpty ? whole : out
    }

    /// 音のサンプルから発話区間を求める(無音を除いた残り。前後 `speechParams.pad` の余白が入る)。
    public static func speechRanges(samples: [Float], sampleRate: Double) -> [SilenceRange] {
        let duration = Double(samples.count) / sampleRate
        return SilenceDetector.profile(left: samples, sampleRate: sampleRate, duration: duration).keepRanges(speechParams)
    }

    /// 区間の持ち分。隣との境目は区間の間の中点にして、区間どうしで隙間も重なりも残さない。最初は 0 から、最後は無限大まで。
    public static func ownership(_ plan: [(start: Double, end: Double)]) -> [(start: Double, end: Double)] {
        plan.indices.map { i in
            let lo = i == 0 ? 0 : (plan[i - 1].end + plan[i].start) / 2
            let hi = i == plan.count - 1 ? Double.infinity : (plan[i].end + plan[i + 1].start) / 2
            return (start: lo, end: hi)
        }
    }

    /// 中心の時刻が持ち分 [start, end) に入る結果だけ残す(余白で二重に認識された語を捨てる)。
    public static func keep(_ segs: [TranscriptSegment], owned: (start: Double, end: Double)) -> [TranscriptSegment] {
        segs.filter { s in
            let mid = (s.start + s.end) / 2
            return mid >= owned.start && mid < owned.end
        }
    }

    /// 区間の認識結果の時刻を全体の時刻へ直す(文と単語の両方)。
    public static func shift(_ segs: [TranscriptSegment], by offset: Double) -> [TranscriptSegment] {
        segs.map { s in
            var t = s
            t.start += offset
            t.end += offset
            t.words = shift(s.words, by: offset)
            return t
        }
    }

    /// 全体の進み。区間 `index` の中の進み `inner`(0〜1)を、0.05〜1 に区間数で按分する。
    public static func progress(index: Int, count: Int, inner: Double) -> Double {
        guard count > 0 else { return 0.05 }
        let f = min(max(inner, 0), 1)
        return 0.05 + 0.95 * (Double(index) + f) / Double(count)
    }

    /// 音声を 16kHz 想定の 1 チャンネル(先頭チャンネル)の Float サンプルとして読む。
    public static func readMono(_ url: URL) throws -> (samples: [Float], sampleRate: Double) {
        let file = try AVAudioFile(forReading: url)
        let rate = file.processingFormat.sampleRate
        // フレーム数が AVAudioFrameCount(UInt32)に収まらない音声は、変換で落とさずエラーにする。
        guard let total = Int(exactly: file.length), total <= Int(AVAudioFrameCount.max) else {
            throw TranscriptionError.failed("音声が長すぎて読み込めません。")
        }
        guard total > 0 else { return ([], rate) }
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(total)),
              let data = buf.floatChannelData else {
            throw TranscriptionError.failed("認識用の音声バッファを作れませんでした。")
        }
        try file.read(into: buf, frameCount: AVAudioFrameCount(total))
        return (Array(UnsafeBufferPointer(start: data[0], count: Int(buf.frameLength))), rate)
    }
}

// MARK: - 実行ファイル・モデルの探索

/// whisper.cpp の実行ファイルとモデルを、決まった場所だけから探す。
public enum WhisperLocator {
    public static let executableName = "whisper-cli"
    /// Application Support 配下では旧名も候補にする。
    public static let legacyExecutableNames = ["whisper-cpp", "main"]
    /// 案内文用の配置先(表示用)。
    public static let supportFolderDisplayPath = "Application Support/MovieCut/Whisper/"
    /// モデルの優先順(前ほど優先)。それ以外は名前順でこの後。
    public static let modelPreference = ["large-v3", "large-v3-turbo", "medium", "small", "base", "tiny"]

    /// 実行ファイルの候補(優先順): 利用者が設定で選んだもの → アプリ内 → Application Support → Homebrew(/opt/homebrew → /usr/local)。
    public static func candidates(userSetting: String? = SecuritySettings.whisperPath(),
                                  bundleResources: URL? = Bundle.main.resourceURL,
                                  supportRoot: URL = DataLocations.current.root) -> [String] {
        var list: [String] = []
        if let u = userSetting, !u.isEmpty { list.append(u) }
        if let b = bundleResources { list.append(b.appendingPathComponent("Whisper/\(executableName)").path) }
        for name in [executableName] + legacyExecutableNames {
            list.append(supportRoot.appendingPathComponent("Whisper/\(name)").path)
        }
        list.append("/opt/homebrew/bin/whisper-cli")
        list.append("/usr/local/bin/whisper-cli")
        list.append("/opt/homebrew/bin/whisper-cpp")
        list.append("/usr/local/bin/whisper-cpp")
        return list
    }

    /// 1 つのパスを実体に直してから検証する。
    ///
    /// Homebrew のバイナリ(/opt/homebrew/bin/whisper-cli)は Cellar へのシンボリックリンクで、
    /// `ExecutableTrust.validate` はリンクそのものを拒否する。そこで先に `resolvingSymlinksInPath` で実体のパスにし、
    /// その実体を検証する(実体が利用者(または root)所有で他者に書き換えられず、置き場のフォルダも同様なら通る。
    /// 拒否の方針は緩めていない。リンクの先がプロジェクト・素材のフォルダ内なら `forbiddenRoots` で落とす)。
    /// 利用者が設定で選んだパスも同じ扱い。
    public static func validate(path: String, forbiddenRoots: [URL] = []) -> URL? {
        guard path.hasPrefix("/") else { return nil }
        // 「..」を含むパスは resolvingSymlinksInPath が畳んでしまうので、先に元のパスで弾く。
        if path.split(separator: "/").contains("..") { return nil }
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        if case .success(let u) = ExecutableTrust.validate(path: real, forbiddenRoots: forbiddenRoots) { return u }
        return nil
    }

    /// 検証を通った最初の実行ファイル。無ければ nil。
    public static func resolve(userSetting: String? = SecuritySettings.whisperPath(),
                               bundleResources: URL? = Bundle.main.resourceURL,
                               supportRoot: URL = DataLocations.current.root,
                               forbiddenRoots: [URL] = []) -> URL? {
        for p in candidates(userSetting: userSetting, bundleResources: bundleResources, supportRoot: supportRoot) {
            if let u = validate(path: p, forbiddenRoots: forbiddenRoots) { return u }
        }
        return nil
    }

    // MARK: モデル

    /// `ggml-*.bin` を優先順に並べる(ファイル名だけで決める)。
    public static func sortedModelNames(_ names: [String]) -> [String] {
        func rank(_ file: String) -> Int {
            var n = file
            if n.hasPrefix("ggml-") { n.removeFirst(5) }
            if n.hasSuffix(".bin") { n.removeLast(4) }
            // 最も長く一致する種別(large-v3-turbo は large-v3 より turbo として数える)
            var best: (len: Int, idx: Int)?
            for (i, k) in modelPreference.enumerated() where n == k || n.hasPrefix(k + "-") || n.hasPrefix(k + ".") {
                if best == nil || k.count > best!.len { best = (k.count, i) }
            }
            return best?.idx ?? modelPreference.count
        }
        return names
            .filter { $0.hasPrefix("ggml-") && $0.hasSuffix(".bin") }
            // VAD(音声区間検出)専用モデルは文字起こしに使えないので、認識用モデルの候補から除く。
            .filter { let l = $0.lowercased(); return !l.contains("silero") && !l.contains("vad") }
            .sorted { (rank($0), $0) < (rank($1), $1) }
    }

    /// モデルの候補(優先順): 利用者が設定で選んだもの → Application Support/MovieCut/Whisper/ 内の ggml-*.bin。
    public static func modelCandidates(userSetting: String? = SecuritySettings.whisperModelPath(),
                                       supportRoot: URL = DataLocations.current.root) -> [String] {
        var list: [String] = []
        if let u = userSetting, !u.isEmpty { list.append(u) }
        let dir = supportRoot.appendingPathComponent("Whisper")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        list += sortedModelNames(names).map { dir.appendingPathComponent($0).path }
        return list
    }

    /// モデルは実行ファイルではないので ExecutableTrust は使わず、通常ファイルの存在と .bin だけ確かめる。
    public static func validateModel(path: String) -> URL? {
        let u = URL(fileURLWithPath: path)
        guard u.pathExtension.lowercased() == "bin" else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else { return nil }
        return u
    }

    public static func resolveModel(userSetting: String? = SecuritySettings.whisperModelPath(),
                                    supportRoot: URL = DataLocations.current.root) -> URL? {
        for p in modelCandidates(userSetting: userSetting, supportRoot: supportRoot) {
            if let u = validateModel(path: p) { return u }
        }
        return nil
    }

    /// VAD(音声区間検出)モデルを Application Support/MovieCut/Whisper/ から探す。
    /// `ggml-silero-v5.1.2.bin` のように名前に silero を含むものを優先し、無ければ vad を含む `ggml-*.bin`。見つからなければ nil。
    public static func resolveVADModel(supportRoot: URL = DataLocations.current.root) -> URL? {
        let dir = supportRoot.appendingPathComponent("Whisper")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let vadNames = names.filter { n in
            let l = n.lowercased()
            return l.hasPrefix("ggml-") && l.hasSuffix(".bin") && (l.contains("silero") || l.contains("vad"))
        }
        let ranked = vadNames.sorted { a, b in
            let sa = a.lowercased().contains("silero"), sb = b.lowercased().contains("silero")
            return sa == sb ? a < b : sa
        }
        for n in ranked {
            if let u = validateModel(path: dir.appendingPathComponent(n).path) { return u }
        }
        return nil
    }
}

// MARK: - 16kHz 変換

/// whisper.cpp は 16kHz モノラルの WAV を要求する。`TranscriptionAudio` が書く 48kHz モノラルを 16kHz・モノラル・16 ビットへ直す。
public enum WhisperAudioConverter {
    public static let targetSampleRate = 16000.0

    /// 既に 16kHz モノラルなら変換せず入力をそのまま返す。そうでなければ `output` に書いて `output` を返す。
    public static func prepare(input: URL, output: URL) throws -> URL {
        let file = try AVAudioFile(forReading: input)
        let f = file.processingFormat
        if f.sampleRate == targetSampleRate && f.channelCount == 1 { return input }
        try convert(file: file, to: output)
        return output
    }

    static func convert(file: AVAudioFile, to output: URL) throws {
        guard let outFmt = AVAudioFormat(standardFormatWithSampleRate: targetSampleRate, channels: 1),
              let conv = AVAudioConverter(from: file.processingFormat, to: outFmt) else {
            throw TranscriptionError.failed("16kHz への変換器を作れませんでした。")
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: targetSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let out = try AVAudioFile(forWriting: output, settings: settings)
        let inChunk: AVAudioFrameCount = 32768
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: inChunk),
              let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: AVAudioFrameCount(Double(inChunk) * targetSampleRate / file.processingFormat.sampleRate) + 1024) else {
            throw TranscriptionError.failed("変換用のバッファを作れませんでした。")
        }
        var readError: Error?
        var finished = false
        while true {
            outBuf.frameLength = 0
            var convError: NSError?
            let status = conv.convert(to: outBuf, error: &convError) { _, inStatus in
                if finished { inStatus.pointee = .endOfStream; return nil }
                // EOF で read すると eofErr(-39) が投げられるため、読む前に終端を判定する。
                if file.framePosition >= file.length { finished = true; inStatus.pointee = .endOfStream; return nil }
                do {
                    inBuf.frameLength = 0
                    try file.read(into: inBuf, frameCount: inChunk)
                } catch { readError = error; finished = true; inStatus.pointee = .endOfStream; return nil }
                if inBuf.frameLength == 0 { finished = true; inStatus.pointee = .endOfStream; return nil }
                inStatus.pointee = .haveData
                return inBuf
            }
            if let readError { throw readError }
            if status == .error { throw convError ?? TranscriptionError.failed("16kHz への変換に失敗しました。") }
            if outBuf.frameLength > 0 { try out.write(from: outBuf) }
            if status == .endOfStream { break }
        }
    }
}

// MARK: - 前処理(ノイズ除去・音量正規化)

/// whisper に渡す前に音を整える。静かな録音・雑音の多い録音で認識が落ちるのを減らすのが目的。
/// 時刻がずれないよう、サンプルレート・チャンネル数・フレーム数(長さ)は入力と同じに保つ。
public enum WhisperPreprocessing {
    /// ノイズ除去の強さ(`SpectralDenoise` の strength)。
    public static let denoiseStrength = 0.5
    /// 正規化の目標ピーク(-1 dBFS ≒ 0.891)。
    public static let targetPeak: Float = 0.891
    /// 増幅の上限(+24 dB ≒ 15.85 倍)。無音に近い音を大きくしすぎない。
    public static let maxGain: Float = 15.85
    /// これを超える長さ(30 分)はノイズ除去を省き、正規化だけにする(処理時間とメモリを抑える)。
    public static let denoiseMaxSeconds = 1800.0

    /// `input` を読み、(a) 30 分以下ならノイズ除去、(b) ピークを -1 dBFS に合わせる(増幅は +24 dB まで)、を掛けて
    /// 16bit PCM WAV として `output` に書く。ピークが 0(完全な無音)なら正規化は掛けない。
    public static func prepare(input: URL, output: URL) throws -> URL {
        let file = try AVAudioFile(forReading: input)
        let fmt = file.processingFormat
        let sr = fmt.sampleRate
        let ch = Int(fmt.channelCount)
        var channels = [[Float]](repeating: [], count: ch)

        // フレーム数が AVAudioFrameCount(UInt32)に収まらない音声は、変換で落とさずエラーにする。
        guard let total = Int(exactly: file.length), total <= Int(AVAudioFrameCount.max) else {
            throw TranscriptionError.failed("音声が長すぎて読み込めません。")
        }
        if total > 0 {
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(total)),
                  let data = buf.floatChannelData else {
                throw TranscriptionError.failed("前処理用のバッファを作れませんでした。")
            }
            try file.read(into: buf, frameCount: AVAudioFrameCount(total))
            let n = Int(buf.frameLength)
            channels = (0..<ch).map { Array(UnsafeBufferPointer(start: data[$0], count: n)) }
        }
        let n = channels.first?.count ?? 0

        if n > 0, Double(n) <= sr * denoiseMaxSeconds {
            let den = SpectralDenoise.process(left: channels[0], right: channels[ch > 1 ? 1 : 0], sampleRate: sr, strength: denoiseStrength)
            if den.left.count == n { channels[0] = den.left }
            if ch > 1, den.right.count == n { channels[1] = den.right }
        }

        var peak: Float = 0
        for c in channels { for v in c { peak = max(peak, abs(v)) } }
        if peak > 0 {
            let gain = min(targetPeak / peak, maxGain)
            channels = channels.map { $0.map { $0 * gain } }
        }

        try writeWAV(channels: channels, sampleRate: sr, to: output)
        return output
    }

    /// 16bit PCM の WAV を書く(`channels` は同じ長さの配列。0 フレームなら空のファイル)。
    static func writeWAV(channels: [[Float]], sampleRate sr: Double, to url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sr, AVNumberOfChannelsKey: channels.count,
                                       AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        let out = try AVAudioFile(forWriting: url, settings: settings)
        let n = channels.first?.count ?? 0
        guard n > 0 else { return }
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: AVAudioChannelCount(channels.count)),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n)),
              let data = buf.floatChannelData else {
            throw TranscriptionError.failed("前処理の出力バッファを作れませんでした。")
        }
        buf.frameLength = AVAudioFrameCount(n)
        for c in channels.indices {
            channels[c].withUnsafeBufferPointer { src in data[c].update(from: src.baseAddress!, count: n) }
        }
        try out.write(from: buf)
    }
}

// MARK: - モデルのカタログ(純粋データ・ダウンロードはしない)

/// whisper.cpp の既知モデル。案内文の表示と、ダウンロード先 URL を決めるだけ(取得はアプリが URL を開く)。
public enum WhisperModelCatalog {
    public struct Model: Equatable, Sendable {
        public let id: String
        public let fileName: String
        /// 目安のサイズ(MB)。
        public let approximateMB: Int
        public let downloadURL: URL

        public init(id: String, fileName: String, approximateMB: Int) {
            self.id = id
            self.fileName = fileName
            self.approximateMB = approximateMB
            self.downloadURL = URL(string: WhisperModelCatalog.baseURL + fileName)!
        }
    }

    public static let baseURL = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/"
    public static let tiny = Model(id: "tiny", fileName: "ggml-tiny.bin", approximateMB: 75)
    public static let base = Model(id: "base", fileName: "ggml-base.bin", approximateMB: 142)
    public static let small = Model(id: "small", fileName: "ggml-small.bin", approximateMB: 466)
    public static let medium = Model(id: "medium", fileName: "ggml-medium.bin", approximateMB: 1500)
    public static let largeV3Turbo = Model(id: "large-v3-turbo", fileName: "ggml-large-v3-turbo.bin", approximateMB: 1600)
    public static let largeV3 = Model(id: "large-v3", fileName: "ggml-large-v3.bin", approximateMB: 3100)

    public static let models: [Model] = [tiny, base, small, medium, largeV3Turbo, largeV3]
    /// 精度優先の推奨(日本語・日英混在の認識が一番安定する)。
    public static let recommended = largeV3

    public static func model(forFileName fileName: String) -> Model? {
        models.first { $0.fileName == fileName }
    }

    public static func downloadURL(forFileName fileName: String) -> URL? {
        model(forFileName: fileName)?.downloadURL
    }
}

// MARK: - JSON パース(純粋関数)

/// whisper.cpp の `-ojf`(full JSON)を `TranscriptSegment` の列にする。
/// 形: `{"transcription":[{"offsets":{"from":ms,"to":ms},"text":"…","tokens":[{"text":"…","offsets":{…}}]}]}`。
public enum WhisperJSONParser {
    private struct Offsets: Decodable { var from: Double; var to: Double }
    private struct Token: Decodable { var text: String?; var offsets: Offsets? }
    private struct Seg: Decodable { var offsets: Offsets; var text: String; var tokens: [Token]? }
    private struct Root: Decodable { var transcription: [Seg] }

    public static func parse(_ data: Data) throws -> [TranscriptSegment] {
        let root: Root
        do { root = try JSONDecoder().decode(Root.self, from: data) }
        catch { throw TranscriptionError.failed("whisper の結果(JSON)を読めませんでした: \(error.localizedDescription)") }

        var out: [TranscriptSegment] = []
        for seg in root.transcription {
            guard seg.offsets.from.isFinite, seg.offsets.to.isFinite else { throw TranscriptionError.failed("whisper の結果に不正な時刻があります。") }
            let start = seg.offsets.from / 1000
            let end = max(start, seg.offsets.to / 1000)
            let body = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }

            // 日本語は 1 文字が複数トークンに割れて、トークン単体では文字化け(U+FFFD)することがある。
            // その区間は単語の時刻を使わず、セグメントをそのまま使う。
            if let tokens = seg.tokens {
                let usable = tokens.filter { !($0.text ?? "").hasPrefix("[_") }
                if !usable.contains(where: { ($0.text ?? "").contains("\u{FFFD}") || $0.offsets == nil }) {
                    let phrases = TranscriptGrouping.phrases(from: words(fromTokens: usable))
                    if !phrases.isEmpty { out += phrases; continue }
                }
            }
            out.append(TranscriptSegment(text: body, start: start, end: end))
        }
        return out
    }

    /// トークン列を単語の列にする。whisper のトークンは単語の途中でも割れる(サブワード)ため、
    /// そのまま連結すると "trans cription" のように単語内に空白が入る。
    /// 先頭に空白が無く、直前が欧文で始まりも欧文・句読点のトークンは直前の単語の続きとしてくっつける。
    /// 日本語のトークンは従来どおりトークン単位のまま(文の区切り・間隔での分割を保つ)。
    private static func words(fromTokens tokens: [Token]) -> [TranscriptSegment] {
        var out: [TranscriptSegment] = []
        for t in tokens {
            guard let text = t.text, let o = t.offsets, o.from.isFinite, o.to.isFinite else { continue }
            let start = o.from / 1000, end = o.to / 1000
            if let last = out.last, isContinuation(text, after: last.text) {
                out[out.count - 1] = TranscriptSegment(text: last.text + text, start: last.start, end: max(last.end, end))
            } else {
                out.append(TranscriptSegment(text: text, start: start, end: end))
            }
        }
        return out
    }

    /// トークンが直前の単語の続きかどうか(英文のサブワード・直前に付く句読点)。
    private static func isContinuation(_ token: String, after prev: String) -> Bool {
        guard let f = token.first, let l = prev.last else { return false }
        if f.isWhitespace { return false }
        if TranscriptGrouping.isCJK(f) || TranscriptGrouping.isCJK(l) { return false }
        return f.isLetter || f.isNumber || ",.!?;:'%)".contains(f)
    }
}
