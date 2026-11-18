import Foundation
import AVFoundation

/// whisper.cpp(外部の実行ファイル `whisper-cli`)で音声を文字にする第 2 のエンジン。
///
/// 安全は AquesTalk と同じ流儀: 実行するのは `WhisperLocator` が決まった場所から探して `ExecutableTrust` で検証したものだけ。
/// 引数は配列で渡し、シェルは通さない。プロジェクトファイルに書かれたパスは使わない。
/// モデルは同梱しない(利用者が `Application Support/MovieCut/Whisper/` に置くか、設定で選ぶ)。
public struct WhisperTranscriber: Transcriber {
    /// 検証を通った whisper-cli の実体(無ければ nil = 実行時に `whisperNotInstalled`)。
    public let executable: URL?
    /// 見つかったモデル(無ければ nil = 実行時に `whisperModelMissing`)。
    public let model: URL?
    public let language: String

    /// - `executablePath` / `modelPath`: 試験用に明示指定する(実行ファイルは検証を通す)。nil なら決まった場所から探す。
    /// - `language`: whisper の `-l`(例: ja)。
    /// - `forbiddenRoots`: この下の実行ファイルは使わない(プロジェクト・素材のフォルダ)。
    public init(executablePath: String? = nil, modelPath: String? = nil, language: String = "ja", forbiddenRoots: [URL] = []) {
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
        let prefix = tmp.appendingPathComponent("moviecut-whisper-\(id)")
        let json = tmp.appendingPathComponent("moviecut-whisper-\(id).json")
        defer {
            try? FileManager.default.removeItem(at: wav16)
            try? FileManager.default.removeItem(at: json)
        }

        let input: URL
        do {
            input = try await Task.detached(priority: .userInitiated) { try WhisperAudioConverter.prepare(input: audioURL, output: wav16) }.value
        } catch let e as TranscriptionError { throw e }
        catch { throw TranscriptionError.failed("音声を 16kHz に変換できませんでした: \(error.localizedDescription)") }
        try Task.checkCancellation()

        try await Self.run(executable: executable,
                           arguments: Self.arguments(model: model, wav: input, language: language, outputPrefix: prefix),
                           timeout: Self.timeout(forDuration: duration), onProgress: onProgress)
        try Task.checkCancellation()

        guard let data = try? Data(contentsOf: json) else {
            throw TranscriptionError.failed("whisper が結果(JSON)を出力しませんでした。")
        }
        let segments = try WhisperJSONParser.parse(data)
        onProgress(1)
        return segments
    }

    /// プロセスを起こして終わるまで待つ。キャンセルで terminate、タイムアウトでも terminate。
    /// 非 0 終了は `TranscriptionError.failed`(stderr の末尾つき)。
    static func run(executable: URL, arguments: [String], timeout: TimeInterval,
                    onProgress: @escaping @Sendable (Double) -> Void) async throws {
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
                if state.lock.withLock({ state.cancelled }), p.isRunning { p.terminate() }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if p.isRunning { state.lock.withLock { state.timedOut = true }; p.terminate() }
                }
            }
        } onCancel: {
            let p: Process? = state.lock.withLock { state.cancelled = true; return state.process }
            if let p, p.isRunning { p.terminate() }
        }
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
                    let words = usable.compactMap { t -> TranscriptSegment? in
                        guard let text = t.text, let o = t.offsets, o.from.isFinite, o.to.isFinite else { return nil }
                        return TranscriptSegment(text: text, start: o.from / 1000, end: o.to / 1000)
                    }
                    let phrases = TranscriptGrouping.phrases(from: words)
                    if !phrases.isEmpty { out += phrases; continue }
                }
            }
            out.append(TranscriptSegment(text: body, start: start, end: end))
        }
        return out
    }
}
