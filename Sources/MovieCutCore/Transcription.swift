import Foundation
import AVFoundation

/// 音声認識の結果の 1 件(秒。入力の音声の頭からの時刻)。
public struct TranscriptSegment: Equatable, Sendable {
    public var text: String
    public var start: Double
    public var end: Double
    /// 文にまとめた結果が持つ、元の単語ごとの時刻(カラオケ字幕用。単語そのものは空)。比較には使わない。
    public var words: [TranscriptSegment] = []
    public init(text: String, start: Double, end: Double, words: [TranscriptSegment] = []) {
        self.text = text; self.start = start; self.end = end; self.words = words
    }
    public static func == (a: TranscriptSegment, b: TranscriptSegment) -> Bool {
        a.text == b.text && a.start == b.start && a.end == b.end
    }
}

/// 音声ファイルを文字にする(画面にも Undo にも依存しない)。本番は `SpeechFrameworkTranscriber`、テストは偽物。
/// キャンセルはタスクのキャンセルで伝える(`CancellationError` を投げて終わる)。
public protocol Transcriber: Sendable {
    /// `duration` は音声の長さ(秒)。`onProgress` は 0〜1 の進み(目安。途中で呼ばれてよい)。
    func transcribe(audioURL: URL, duration: Double, onProgress: @escaping @Sendable (Double) -> Void) async throws -> [TranscriptSegment]
}

/// 音声認識の失敗。メッセージは日本語(そのまま画面に出す)。
public enum TranscriptionError: Error, LocalizedError, Equatable {
    /// 音声認識の許可がない(拒否した、またはシステム設定で切ってある)
    case permissionDenied
    /// まだ許可を聞いていない(コマンドラインからは聞けない。アプリで一度実行して許可する)
    case permissionNotChecked
    /// この Mac の管理設定で制限されている
    case permissionRestricted
    /// 日本語の認識器を作れなかった
    case unsupportedLocale
    /// 認識器が今使えない(設定で無効、など)
    case unavailable
    /// この Mac に日本語のオンデバイス認識の言語データが無い
    case onDeviceUnavailable
    /// 選んだクリップに音が無い(映像だけ、など)
    case noAudio
    /// 認識の途中で失敗した(詳細は画面用の文)
    case failed(String)
    /// whisper.cpp の実行ファイルが見つからない
    case whisperNotInstalled
    /// Whisper のモデル(ggml-*.bin)が見つからない
    case whisperModelMissing

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "音声認識の許可がありません。システム設定 ▸ プライバシーとセキュリティ ▸ 音声認識 で Movie Cut を許可してから、もう一度お試しください。"
        case .permissionNotChecked:
            return "音声認識の許可をまだ聞いていません。Movie Cut のアプリで「音声から字幕を作る」を一度実行して許可してから、もう一度お試しください。"
        case .permissionRestricted:
            return "この Mac では音声認識が制限されています(管理者の設定)。"
        case .unsupportedLocale:
            return "日本語の音声認識を用意できませんでした。"
        case .unavailable:
            return "音声認識が今は使えません。システム設定で「Siri と音声入力」を有効にしてから、もう一度お試しください。"
        case .onDeviceUnavailable:
            return "この Mac では日本語の音声認識(オンデバイス)が使えません。システム設定で日本語の音声認識の言語を追加してから、もう一度お試しください。"
        case .noAudio:
            return "このクリップには音がありません。音のある素材か、音声のクリップを選んでください。"
        case .failed(let detail):
            return "音声を文字にできませんでした: \(detail)"
        case .whisperNotInstalled:
            return "whisper.cpp(whisper-cli)が見つかりません。設定の「Whisper(文字起こし)」で実行ファイルを選ぶか、\(WhisperLocator.supportFolderDisplayPath) に置いてください(Homebrew なら brew install whisper-cpp)。手順は docs/Whisper文字起こし.md を参照してください。"
        case .whisperModelMissing:
            return "Whisper のモデル(ggml-*.bin)が見つかりません。\(WhisperLocator.supportFolderDisplayPath) に置くか、設定の「Whisper(文字起こし)」でモデルを選んでください。精度を重視するなら ggml-large-v3.bin(約3.1GB)がおすすめです。"
        }
    }
}

/// 音声から字幕を作る対象か。音のある素材(音声・ボイス・動画)で、速度・逆再生・フリーズが無いもの
/// (タイムラインの時間と素材の時間が 1 対 1 になるので、認識の時刻をそのまま配置できる)。
public enum TranscriptionSupport {
    public static func supports(_ c: Clip) -> Bool { SilenceDetector.supportsOneToOne(c) }
}

// MARK: - 文の組み立て(単語の列 → 字幕の 1 件)

/// 認識器が返す単語(または細かい区切り)を、字幕 1 件分の文にまとめる。
public enum TranscriptGrouping {
    /// これより長く無音が続いたら、文を切る(秒)。
    public static let maxGap = 0.8
    /// 1 件の最大の文字数(空白を除いた数ではなく、連結後の文字数)。
    public static let maxChars = 30
    static let sentenceEnders: Set<Swift.Character> = ["。", "！", "？", "!", "?"]

    /// 空の単語は捨てる。無音が `maxGap` を超える・文末の記号の後・`maxChars` を超える、のどれかで切る。
    public static func phrases(from words: [TranscriptSegment]) -> [TranscriptSegment] {
        var out: [TranscriptSegment] = []
        var cur: TranscriptSegment?
        for w in words {
            let t = w.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, w.start.isFinite, w.end.isFinite else { continue }
            let end = max(w.start, w.end)
            let one = TranscriptSegment(text: t, start: w.start, end: end)
            if let c = cur {
                let gap = w.start - c.end
                let endsSentence = c.text.last.map { sentenceEnders.contains($0) } ?? false
                let joined = join(c.text, t)
                // 最大文字数は「連結後の文字数」で見る(join が入れる空白も数える)。
                if gap > maxGap || endsSentence || joined.count > maxChars {
                    out.append(c)
                    cur = TranscriptSegment(text: t, start: w.start, end: end, words: [one])
                } else {
                    cur = TranscriptSegment(text: joined, start: c.start, end: max(c.end, end), words: c.words + [one])
                }
            } else {
                cur = TranscriptSegment(text: t, start: w.start, end: end, words: [one])
            }
        }
        if let c = cur { out.append(c) }
        return out
    }

    /// 単語の境界に空白を入れるか決める。日本語(かな・漢字・和文記号)に接する境界は詰める。
    /// それ以外は、英字・数字・ラテン文字・欧文句読点に単語が続けば空白を入れる
    /// ("Hello," + "world" や "café" + "noir" で空白が消えないように)。
    /// ただし数字どうしの小数点・桁区切りは詰める("3." + "5" → "3.5"、"1," + "000" → "1,000")。
    static func join(_ a: String, _ b: String) -> String {
        guard let l = a.last, let f = b.first else { return a + b }
        if isCJK(l) || isCJK(f) { return a + b }
        if f.isNumber && (l == "." || l == ",") { return a + b }
        let leftPunct: Set<Swift.Character> = [",", ".", "!", "?", ";", ":", "'", "\"", ")", "]"]
        let leftOK = l.isLetter || l.isNumber || leftPunct.contains(l)
        let rightOK = f.isLetter || f.isNumber
        return (leftOK && rightOK) ? a + " " + b : a + b
    }

    /// かな・漢字・和文記号かどうか(最初のスカラで判定)。
    static func isCJK(_ c: Swift.Character) -> Bool {
        guard let v = c.unicodeScalars.first?.value else { return false }
        return (0x3000...0x30FF).contains(v) || (0x3400...0x4DBF).contains(v)
            || (0x4E00...0x9FFF).contains(v) || (0xF900...0xFAFF).contains(v)
            || (0xFF66...0xFF9D).contains(v)
    }
}

// MARK: - 認識結果 → 字幕(タイムラインの時刻へ)

public enum TranscriptSubtitles {
    /// 認識結果を、クリップの中の字幕(秒。タイムライン上の時刻)に直す。
    /// 時刻は クリップの開始 + 認識の時刻。クリップの長さの外へは出さない(はみ出しは切る)。本文が空・長さが 0 のものは捨てる。開始順。
    public static func cues(from segments: [TranscriptSegment], clip: Clip) -> [SubtitleCue] {
        let dur = clip.duration
        var out: [SubtitleCue] = []
        for s in segments {
            let body = SubtitleFile.cleanBody(s.text)
            guard !body.isEmpty, s.start.isFinite, s.end.isFinite, dur > 0 else { continue }
            let a = min(max(0, s.start), dur)
            let b = min(max(a, s.end), dur)
            guard b - a > 1e-3 else { continue }
            out.append(SubtitleCue(start: clip.start + a, end: clip.start + b, text: body))
        }
        return out.enumerated().sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }.map(\.element)
    }
}

// MARK: - 音声の書き出し(認識器に渡す一時ファイル)

public enum TranscriptionAudio {
    /// クリップが使う範囲([offset, offset + 長さ])の音を、モノラル 16 ビット WAV(48 kHz)に書く。
    /// ミキサーと同じ経路で読むので、動画の音声も音声クリップと同じに扱える。音が無ければ `TranscriptionError.noAudio`。
    public static func writeWAV(clip c: Clip, to url: URL, isCancelled: @Sendable () -> Bool = { false }) throws {
        guard let src = try? AudioMixer.openSource(c, offset: c.offset, span: c.duration) else { throw TranscriptionError.noAudio }
        let sr = AudioMixer.sampleRate
        let total = Int((c.duration * sr).rounded())
        let chunk = Int(sr)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sr,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1) else { throw TranscriptionError.noAudio }
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let l = UnsafeMutablePointer<Float>.allocate(capacity: chunk), r = UnsafeMutablePointer<Float>.allocate(capacity: chunk)
        defer { l.deallocate(); r.deallocate() }
        var done = 0
        var wrote = 0
        while done < total {
            // 抽出は素材が長いと時間がかかるため、チャンクごとにキャンセルを見る。
            if isCancelled() { throw CancellationError() }
            let want = min(chunk, total - done)
            let got = src.read(left: l, right: r, frames: want)
            if got <= 0 { break }
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(got)), let ch = buf.floatChannelData else { throw TranscriptionError.noAudio }
            for i in 0..<got { ch[0][i] = (l[i] + r[i]) * 0.5 }
            buf.frameLength = AVAudioFrameCount(got)
            try file.write(from: buf)
            done += got
            wrote += got
        }
        guard wrote > 0 else { throw TranscriptionError.noAudio }
    }
}

/// キャンセルを detached タスクへ伝えるためのフラグ。
private final class TranscriptionCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

// MARK: - 実行(音を書き出す → 認識する → 字幕レイヤーへ)

public enum SubtitleTranscription {
    /// 選んだクリップの音声を書き出して認識するだけ(プロジェクトは変えない)。
    /// 対象外のクリップは空配列。キャンセルは `CancellationError`。一時ファイルは終わったら消す。
    public static func segments(clip: Clip, transcriber: Transcriber,
                                tempDirectory: URL = FileManager.default.temporaryDirectory,
                                onProgress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> [TranscriptSegment] {
        guard TranscriptionSupport.supports(clip) else { return [] }
        let url = tempDirectory.appendingPathComponent("moviecut-transcribe-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        // detached タスクにはキャンセルが伝わらないため、フラグ経由で抽出ループへ伝える。
        let flag = TranscriptionCancelFlag()
        try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try TranscriptionAudio.writeWAV(clip: clip, to: url, isCancelled: { flag.isSet })
            }.value
        } onCancel: { flag.set() }
        try Task.checkCancellation()
        let segments = try await transcriber.transcribe(audioURL: url, duration: clip.duration, onProgress: onProgress)
        try Task.checkCancellation()
        return segments
    }

    /// 選んだクリップの音声を文字にして、「字幕」レイヤーに文字クリップとして足す(見た目は `style`。字幕の自動生成と同じ)。
    /// 認識結果が無ければ nil(何も変えない)。キャンセルは `CancellationError`。一時ファイルは終わったら消す。
    public static func run(clip: Clip, project: Project, transcriber: Transcriber, style: TextLook?,
                           tempDirectory: URL = FileManager.default.temporaryDirectory,
                           onProgress: @escaping @Sendable (Double) -> Void = { _ in },
                           onSegments: @escaping @Sendable ([TranscriptSegment]) -> Void = { _ in }) async throws -> SubtitleGeneration.Result? {
        guard TranscriptionSupport.supports(clip) else { return nil }
        let segments = try await segments(clip: clip, transcriber: transcriber, tempDirectory: tempDirectory, onProgress: onProgress)
        onSegments(segments)
        let cues = TranscriptSubtitles.cues(from: segments, clip: clip)
        // 単語の時刻があるときだけ、カラオケ字幕の単位ごとの開始秒を入れる(スタイルにカラオケが無ければ何もしない)
        let words = segments.flatMap(\.words)
        let clipStart = clip.start
        return SubtitleGeneration.appendCues(cues, to: project, style: style) { cue, highlight in
            KaraokeTiming.times(text: cue.text, words: words, windowStart: cue.start - clipStart,
                                duration: cue.end - cue.start, wordMode: highlight.isWordMode)
        }
    }
}
