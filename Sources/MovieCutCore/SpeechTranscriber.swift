import Foundation
import Speech

/// Apple の Speech フレームワーク(SFSpeechRecognizer)で音声ファイルをオンデバイスで文字にする本番の `Transcriber`。
/// 外部のサーバーには送らない(`requiresOnDeviceRecognition`)。許可・利用不可は `TranscriptionError` で返す。
public struct SpeechFrameworkTranscriber: Transcriber {
    public var localeIdentifier: String
    /// true なら、まだ許可を聞いていないときに OS の確認を出す(アプリ用)。false なら聞かずに `permissionNotChecked` を返す
    /// (アプリの外のプロセスは許可を求めると異常終了する。コマンドライン用)。
    public var requestsPermission: Bool

    public init(localeIdentifier: String = "ja-JP", requestsPermission: Bool = true) {
        self.localeIdentifier = localeIdentifier
        self.requestsPermission = requestsPermission
    }

    public func transcribe(audioURL: URL, duration: Double, onProgress: @escaping @Sendable (Double) -> Void) async throws -> [TranscriptSegment] {
        try Task.checkCancellation()
        try await Self.ensureAuthorized(requestIfNeeded: requestsPermission)
        try Task.checkCancellation()
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)) else { throw TranscriptionError.unsupportedLocale }
        guard recognizer.isAvailable else { throw TranscriptionError.unavailable }
        guard recognizer.supportsOnDeviceRecognition else { throw TranscriptionError.onDeviceUnavailable }

        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true

        let session = RecognitionSession()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[TranscriptSegment], Error>) in
                guard session.attach(continuation) else { return }
                let task = recognizer.recognitionTask(with: request) { result, error in
                    if let error {
                        // 音が一つも無いときの「発話なし」は、空の結果として扱う
                        if Self.isNoSpeech(error) { session.finish(.success([])); return }
                        session.finish(.failure(session.isCancelled ? CancellationError() : TranscriptionError.failed(error.localizedDescription)))
                        return
                    }
                    guard let result else { return }
                    let words = result.bestTranscription.segments.map {
                        TranscriptSegment(text: $0.substring, start: $0.timestamp, end: $0.timestamp + $0.duration)
                    }
                    if !result.isFinal {
                        if duration > 0, let last = words.last { onProgress(min(1, last.end / duration)) }
                        return
                    }
                    onProgress(1)
                    session.finish(.success(TranscriptGrouping.phrases(from: words)))
                }
                session.setTask(task)
            }
        } onCancel: {
            session.cancel()
        }
    }

    /// 許可を確かめる。まだ聞いていなければ聞く(OS の確認ダイアログ)。拒否・制限は `TranscriptionError`。
    static func ensureAuthorized(requestIfNeeded: Bool) async throws {
        var status = SFSpeechRecognizer.authorizationStatus()
        if status == .notDetermined && !requestIfNeeded { throw TranscriptionError.permissionNotChecked }
        if status == .notDetermined {
            status = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
                SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
            }
        }
        switch status {
        case .authorized: return
        case .restricted: throw TranscriptionError.permissionRestricted
        default: throw TranscriptionError.permissionDenied
        }
    }

    /// 「発話が聞こえなかった」(認識器のエラー 1110 の類)。
    static func isNoSpeech(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == "kAFAssistantErrorDomain" && ns.code == 1110
    }
}

/// 1 回の認識の受け皿。結果・キャンセル・認識タスクを、どの順で来ても一度だけ安全に片付ける。
private final class RecognitionSession: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[TranscriptSegment], Error>?
    private var task: SFSpeechRecognitionTask?
    private var cancelled = false

    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    /// 待ち先を登録する。すでにキャンセルされていれば false(認識を始めない)。
    func attach(_ c: CheckedContinuation<[TranscriptSegment], Error>) -> Bool {
        lock.lock()
        if cancelled { lock.unlock(); c.resume(throwing: CancellationError()); return false }
        continuation = c
        lock.unlock()
        return true
    }

    func setTask(_ t: SFSpeechRecognitionTask) {
        lock.lock(); task = t; let c = cancelled; lock.unlock()
        if c { t.cancel() }
    }

    func finish(_ r: Result<[TranscriptSegment], Error>) {
        lock.lock(); let c = continuation; continuation = nil; lock.unlock()
        c?.resume(with: r)
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let t = task, c = continuation
        continuation = nil
        lock.unlock()
        t?.cancel()
        c?.resume(throwing: CancellationError())
    }
}
