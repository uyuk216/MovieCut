import Foundation

// MARK: - 生成メディア: 動画 / 音声・音楽プロバイダと生成延長の口(W5-4)
//
// 画像生成(`ImageGeneration.swift`)に続く、生成メディア共通口
// (`GenerativeMedia.swift`)の残りの実装。
//
// - 動画生成: OpenAI 互換スタイルの汎用エンドポイントへジョブを投げ、
//   非同期ジョブをポーリングして、完了後に素材ファイルとして配置する。
// - 音声(効果音)/音楽/サウンドスケープ生成: 同スタイルの汎用エンドポイント
//   から、同期応答(音声データそのもの / Base64 / URL)を受けて配置する。
// - 生成延長: クリップの前後に生成セグメントを足す操作の Core 計画
//   (`GenerativeExtensionPlanner`)と配置(`GenerativeExtensionPlacement`)。
//   実生成は上の動画/音声プロバイダ経由で、元クリップは書き換えない。
//
// 設計方針は画像生成とまったく同じ(ユーザー決定 2026-11-19):
// - 生成はユーザー自身の API キー/アカウントで実行され、費用もユーザー
//   のもの。MovieCut のサーバは経由しない。
// - キーはこの Mac のアプリ設定(UserDefaults)にだけ保存し、プロジェクト・
//   ログ・送信前確認の文には出さない。送信時は Authorization ヘッダーだけ。
// - 未設定のときは機能が無効になる(`isConfigured` false、
//   `makeProvider()` は `GenerativeMediaError.notConfigured`)。
// - http で送れるのは localhost 宛てだけ。外部は https 必須
//   (判定は `TextGenerationSettings.endpointProblem` と共通)。
// - 通信は既存の `ImageGenerationTransport` 境界の後ろにあり、テストでは
//   差し替えられる(実キーでの疎通は未検証。検証はモック応答まで)。
// - 汎用エンドポイントの形式はベンダーごとに差があるため、ここで対応する
//   形式は docs(生成メディア連携と画像生成API.md)に明記した範囲に限る。
//   元素材そのものをサービスへ送る形式(本当の続き生成)は対象外で、
//   生成延長もプロンプトから前後のセグメントを作る口として実装する。
//
// 内蔵音声合成スタックと既存 AIImage(ローカルコマンド方式)には触らない。

// MARK: - 生成ファイルの置き場所

/// 生成した動画・音声ファイルの置き場所(Application Support/MovieCut/GeneratedMedia)。
/// 画像は従来どおり `AIImageStore` の場所を使う(ここでは扱わない)。
public enum GeneratedMediaStore {
    public static func directory() -> URL {
        DataLocations.current.generatedMedia
    }

    /// 種類ごとの既定の拡張子(形式指定が無い/不正なとき)。
    public static func defaultFormat(for kind: GenerativeMediaKind) -> String {
        switch kind {
        case .image: return "png"
        case .video: return "mp4"
        case .audio, .music, .soundscape: return "mp3"
        }
    }

    /// 形式文字列を拡張子として安全な形にする(先頭の "." を外し、小文字の
    /// 英数字だけを残す。不正なら種類の既定)。パス区切り等は絶対に入らない。
    public static func sanitizedFormat(_ raw: String?, for kind: GenerativeMediaKind) -> String {
        guard let raw else { return defaultFormat(for: kind) }
        let cleaned = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .drop(while: { $0 == "." })
            .filter { $0.isLetter || $0.isNumber }
        let s = String(cleaned.prefix(5))
        return s.isEmpty ? defaultFormat(for: kind) : s
    }

    public static func newOutputURL(kind: GenerativeMediaKind, format: String?, in dir: URL = directory()) -> URL {
        dir.appendingPathComponent(UUID().uuidString + "." + sanitizedFormat(format, for: kind))
    }

    /// 生成データをファイルに書いて URL を返す。空データは失敗。
    public static func write(_ data: Data, kind: GenerativeMediaKind, format: String?,
                             in dir: URL = directory()) throws -> URL {
        guard !data.isEmpty else { throw GenerativeMediaError.emptyResponse }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = newOutputURL(kind: kind, format: format, in: dir)
        do { try data.write(to: out) } catch {
            throw GenerativeMediaError.transport("生成したファイルを保存できませんでした: \(error.localizedDescription)")
        }
        return out
    }
}

// MARK: - 応答 JSON の共通の読み取り(純粋関数)

/// 生成サービス応答 JSON の、よくある形の読み取り。画像生成の
/// `data[0].b64_json` / `data[0].url` と同じ流儀で、トップレベルと
/// `data[0]` の両方を見る。キーの値はここには一切現れない。
public enum GenerativeResponseParsing {
    public static func object(from data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// 文字列フィールドを探す(トップレベル → `data[0]` の順)。
    public static func stringField(_ obj: [String: Any], keys: [String]) -> String? {
        for k in keys {
            if let s = obj[k] as? String, !s.isEmpty { return s }
        }
        if let items = obj["data"] as? [[String: Any]], let first = items.first {
            for k in keys {
                if let s = first[k] as? String, !s.isEmpty { return s }
            }
        }
        return nil
    }

    /// Base64 のメディアデータ(`b64_json` 等)を取り出す。
    public static func base64MediaData(from data: Data) throws -> Data? {
        guard let obj = object(from: data) else { return nil }
        guard let b64 = stringField(obj, keys: ["b64_json", "b64", "audio", "content"]) else { return nil }
        guard let decoded = Data(base64Encoded: b64) else {
            throw GenerativeMediaError.unparsable("生成結果のデータ")
        }
        return decoded
    }

    /// メディアの URL(`url` / `video_url` / `audio_url` / `file_url`)を取り出す。
    public static func mediaURL(from data: Data) -> URL? {
        guard let obj = object(from: data),
              let s = stringField(obj, keys: ["url", "video_url", "audio_url", "file_url"]) else { return nil }
        return URL(string: s)
    }

    /// 非同期ジョブの ID(`id` / `job_id`)。
    public static func jobID(from data: Data) -> String? {
        guard let obj = object(from: data) else { return nil }
        return stringField(obj, keys: ["id", "job_id"])
    }

    /// 非同期ジョブの状態(小文字化して返す。無ければ nil)。
    public static func jobStatus(from data: Data) -> String? {
        guard let obj = object(from: data) else { return nil }
        return stringField(obj, keys: ["status", "state"])?.lowercased()
    }

    /// ジョブ失敗時の説明文(`error.message` / `error` / `message`)。
    public static func failureDetail(from data: Data) -> String {
        guard let obj = object(from: data) else { return "" }
        if let e = obj["error"] as? [String: Any], let m = e["message"] as? String { return m }
        if let e = obj["error"] as? String { return e }
        if let m = obj["message"] as? String { return m }
        return ""
    }

    public static let completedStatuses: Set<String> = ["completed", "succeeded", "success", "done", "finished"]
    public static let failedStatuses: Set<String> = ["failed", "error", "cancelled", "canceled"]
    /// 完了でも失敗でもない状態(継続ポーリング)。未知の状態も継続として扱う。
    public static func isInProgress(_ status: String?) -> Bool {
        guard let s = status, !s.isEmpty else { return true }
        return !completedStatuses.contains(s) && !failedStatuses.contains(s)
    }
}

// MARK: - 動画生成

/// 動画の大きさの候補(任意の文字列もそのまま送れる)。
public enum VideoGenerationSize: String, CaseIterable, Sendable {
    case landscape = "1280x720"
    case fullHD = "1920x1080"
    case portrait = "720x1280"
    case square = "1024x1024"

    public var title: String {
        switch self {
        case .landscape: return "横長 (1280×720)"
        case .fullHD: return "横長 Full HD (1920×1080)"
        case .portrait: return "縦長 (720×1280)"
        case .square: return "正方形 (1024×1024)"
        }
    }
}

/// 動画生成プロバイダ(OpenAI 互換スタイルの汎用エンドポイント)。
/// 作成 POST → (必要なら)ジョブのポーリング GET → 結果の取得、までを行う。
/// 対応する応答形式は docs に明記した範囲:
/// - 同期完了: `data[0].b64_json` / `data[0].url` / トップレベルの `url` 等
/// - 非同期: `id` + `status` を返し、`{endpoint}/{id}` の GET で状態が進む。
///   完了時に URL/Base64 が無ければ `{endpoint}/{id}/content` から取得する。
public struct OpenAICompatibleVideoProvider: GenerativeMediaProvider {
    public let endpoint: URL
    public let model: String
    private let apiKey: String
    public let timeout: TimeInterval
    /// ポーリングの間隔(秒)と上限回数。テストでは間隔 0・回数小で使う。
    public let pollIntervalSeconds: Double
    public let maxPollAttempts: Int
    public let transport: ImageGenerationTransport
    public let outputDirectory: URL

    public init(endpoint: URL, model: String, apiKey: String = "", timeout: TimeInterval = 300,
                pollIntervalSeconds: Double = 5, maxPollAttempts: Int = 60,
                transport: ImageGenerationTransport = URLSessionImageTransport(),
                outputDirectory: URL = GeneratedMediaStore.directory()) {
        self.endpoint = endpoint
        self.model = model
        self.apiKey = apiKey
        self.timeout = timeout
        self.pollIntervalSeconds = max(0, pollIntervalSeconds)
        self.maxPollAttempts = max(1, maxPollAttempts)
        self.transport = transport
        self.outputDirectory = outputDirectory
    }

    public var supportedKinds: [GenerativeMediaKind] { [.video] }
    public var destinationDescription: String { "\(endpoint.absoluteString) / モデル: \(model)" }

    private func authorized(_ req: inout URLRequest) {
        if !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
    }

    /// 作成リクエスト(テストで中身を確認できるよう公開)。キーはヘッダーにだけ入る。
    public func makeRequest(_ request: GenerativeMediaRequest) throws -> URLRequest {
        try request.validate()
        var body: [String: Any] = [
            "model": model,
            "prompt": request.trimmedPrompt,
            "size": request.size ?? VideoGenerationSize.landscape.rawValue,
        ]
        if let d = request.targetDuration, d > 0 { body["seconds"] = d; body["duration"] = d }
        if let f = request.outputFormat, !f.isEmpty { body["output_format"] = GeneratedMediaStore.sanitizedFormat(f, for: .video) }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorized(&req)
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    /// ジョブ参照用の URL(`{endpoint}/{id}`)。id はパス用にエンコードする。
    public func jobURL(id: String) -> URL {
        let base = endpoint.absoluteString.hasSuffix("/") ? String(endpoint.absoluteString.dropLast()) : endpoint.absoluteString
        let enc = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        return URL(string: base + "/" + enc) ?? endpoint
    }

    public func contentURL(id: String) -> URL { jobURL(id: id).appendingPathComponent("content") }

    private func get(_ url: URL) async throws -> (Data, Int) {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = timeout
        // 取得先が作成先と同じホストのときだけキーを付ける(画像生成と同じ作法)。
        if url.host == endpoint.host { authorized(&req) }
        return try await transport.send(req)
    }

    /// 応答データからメディア本体を取り出す。URL しか無ければ取りに行く。
    /// まだメディアが無い(ジョブ継続中)なら nil。
    private func mediaData(from data: Data, jobID: String?) async throws -> Data? {
        if let b64 = try GenerativeResponseParsing.base64MediaData(from: data) { return b64 }
        if let remote = GenerativeResponseParsing.mediaURL(from: data) {
            let (downloaded, status) = try await get(remote)
            guard (200..<300).contains(status) else {
                throw GenerativeMediaError.http(status, String(decoding: downloaded, as: UTF8.self))
            }
            return downloaded
        }
        if let jobID {
            // 完了応答に本体も URL も無い形式は、content エンドポイントから取る。
            let (downloaded, status) = try await get(contentURL(id: jobID))
            if (200..<300).contains(status), !downloaded.isEmpty {
                if GenerativeResponseParsing.object(from: downloaded) == nil { return downloaded }
                if let inner = try GenerativeResponseParsing.base64MediaData(from: downloaded) { return inner }
            }
        }
        return nil
    }

    public func generate(_ request: GenerativeMediaRequest) async throws -> GenerativeMediaResult {
        guard request.kind == .video else { throw GenerativeMediaError.unsupportedKind(request.kind) }
        let createReq = try makeRequest(request)
        let (data, status) = try await transport.send(createReq)
        guard (200..<300).contains(status) else {
            throw GenerativeMediaError.http(status, String(decoding: data, as: UTF8.self))
        }
        let format = request.outputFormat
        let duration = request.targetDuration ?? GenerativeMediaKind.video.defaultDuration

        // 同期完了の形: その場でメディアが返る。
        let jobID = GenerativeResponseParsing.jobID(from: data)
        let jobStatus = GenerativeResponseParsing.jobStatus(from: data)
        if let st = jobStatus, GenerativeResponseParsing.failedStatuses.contains(st) {
            throw GenerativeMediaError.jobFailed(GenerativeResponseParsing.failureDetail(from: data))
        }
        if jobID == nil || (jobStatus.map { GenerativeResponseParsing.completedStatuses.contains($0) } ?? false) {
            if let bytes = try await mediaData(from: data, jobID: jobID) {
                let out = try GeneratedMediaStore.write(bytes, kind: .video, format: format, in: outputDirectory)
                return GenerativeMediaResult(kind: .video, fileURL: out, duration: duration)
            }
            if jobID == nil { throw GenerativeMediaError.unparsable("生成結果") }
        }

        // 非同期の形: ジョブをポーリングする。
        guard let id = jobID else { throw GenerativeMediaError.unparsable("生成ジョブの ID") }
        for _ in 0..<maxPollAttempts {
            if Task.isCancelled { throw GenerativeMediaError.cancelled }
            if pollIntervalSeconds > 0 {
                do { try await Task.sleep(nanoseconds: UInt64(pollIntervalSeconds * 1_000_000_000)) }
                catch { throw GenerativeMediaError.cancelled }
            }
            let (pollData, pollStatus) = try await get(jobURL(id: id))
            guard (200..<300).contains(pollStatus) else {
                throw GenerativeMediaError.http(pollStatus, String(decoding: pollData, as: UTF8.self))
            }
            let st = GenerativeResponseParsing.jobStatus(from: pollData)
            if let st, GenerativeResponseParsing.failedStatuses.contains(st) {
                throw GenerativeMediaError.jobFailed(GenerativeResponseParsing.failureDetail(from: pollData))
            }
            if let st, GenerativeResponseParsing.completedStatuses.contains(st) {
                guard let bytes = try await mediaData(from: pollData, jobID: id) else {
                    throw GenerativeMediaError.unparsable("生成結果")
                }
                let out = try GeneratedMediaStore.write(bytes, kind: .video, format: format, in: outputDirectory)
                return GenerativeMediaResult(kind: .video, fileURL: out, duration: duration)
            }
            // 状態が無い応答にメディアが直接入っている形も拾う。
            if st == nil, let bytes = try await mediaData(from: pollData, jobID: id) {
                let out = try GeneratedMediaStore.write(bytes, kind: .video, format: format, in: outputDirectory)
                return GenerativeMediaResult(kind: .video, fileURL: out, duration: duration)
            }
        }
        throw GenerativeMediaError.jobTimedOut
    }
}

// MARK: - 音声 / 音楽生成

/// 音声(効果音)・音楽・サウンドスケープ生成プロバイダ(同スタイル)。
/// 同期応答で音声データが返る形式に対応する:
/// - 音声データそのもの(mp3/wav 等のバイナリを直接返す)
/// - JSON の Base64(`data[0].b64_json` / `b64_json` / `audio` 等)
/// - JSON の URL(`data[0].url` / `url` / `audio_url` 等。取りに行く)
public struct OpenAICompatibleAudioProvider: GenerativeMediaProvider {
    public let endpoint: URL
    public let model: String
    private let apiKey: String
    public let timeout: TimeInterval
    public let transport: ImageGenerationTransport
    public let outputDirectory: URL

    public init(endpoint: URL, model: String, apiKey: String = "", timeout: TimeInterval = 300,
                transport: ImageGenerationTransport = URLSessionImageTransport(),
                outputDirectory: URL = GeneratedMediaStore.directory()) {
        self.endpoint = endpoint
        self.model = model
        self.apiKey = apiKey
        self.timeout = timeout
        self.transport = transport
        self.outputDirectory = outputDirectory
    }

    public var supportedKinds: [GenerativeMediaKind] { [.audio, .music, .soundscape] }
    public var destinationDescription: String { "\(endpoint.absoluteString) / モデル: \(model)" }

    /// 送る URLRequest(テストで中身を確認できるよう公開)。キーはヘッダーにだけ入る。
    /// 音声読み上げ系が使う `input` と、音楽/効果音系が使う `prompt` の両方に
    /// 同じ文を入れる(汎用口としての互換のため。docs に明記)。
    public func makeRequest(_ request: GenerativeMediaRequest) throws -> URLRequest {
        try request.validate()
        let format = GeneratedMediaStore.sanitizedFormat(request.outputFormat, for: request.kind)
        var body: [String: Any] = [
            "model": model,
            "prompt": request.trimmedPrompt,
            "input": request.trimmedPrompt,
            "kind": request.kind.rawValue,
            "response_format": format,
            "format": format,
        ]
        if let d = request.targetDuration, d > 0 { body["duration"] = d; body["seconds"] = d }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    public func generate(_ request: GenerativeMediaRequest) async throws -> GenerativeMediaResult {
        guard supportedKinds.contains(request.kind) else { throw GenerativeMediaError.unsupportedKind(request.kind) }
        let urlRequest = try makeRequest(request)
        let (data, status) = try await transport.send(urlRequest)
        guard (200..<300).contains(status) else {
            throw GenerativeMediaError.http(status, String(decoding: data, as: UTF8.self))
        }
        guard !data.isEmpty else { throw GenerativeMediaError.emptyResponse }
        let bytes: Data
        if GenerativeResponseParsing.object(from: data) != nil {
            // JSON の形: Base64 か URL のどちらかが必要。
            if let b64 = try GenerativeResponseParsing.base64MediaData(from: data) {
                bytes = b64
            } else if let remote = GenerativeResponseParsing.mediaURL(from: data) {
                var get = URLRequest(url: remote)
                get.timeoutInterval = timeout
                if !apiKey.isEmpty, remote.host == endpoint.host {
                    get.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                }
                let (downloaded, dlStatus) = try await transport.send(get)
                guard (200..<300).contains(dlStatus) else {
                    throw GenerativeMediaError.http(dlStatus, String(decoding: downloaded, as: UTF8.self))
                }
                bytes = downloaded
            } else {
                throw GenerativeMediaError.unparsable("生成結果")
            }
        } else {
            // JSON でない応答は、音声データそのものとして扱う。
            bytes = data
        }
        let out = try GeneratedMediaStore.write(bytes, kind: request.kind, format: request.outputFormat, in: outputDirectory)
        return GenerativeMediaResult(kind: request.kind, fileURL: out,
                                     duration: request.targetDuration ?? request.kind.defaultDuration)
    }
}

// MARK: - 設定(動画)

public struct VideoGenerationSettings: Equatable, Sendable {
    public var endpoint: String = ""
    public var model: String = ""
    /// APIキー。この Mac のアプリ設定にだけ保存し、プロジェクト・ログ・確認文には出さない。
    public var apiKey: String = ""
    public var timeoutSeconds: Int = 300
    public var pollIntervalSeconds: Int = 5
    public var maxPollAttempts: Int = 60
    public var size: String = VideoGenerationSize.landscape.rawValue
    public var durationSeconds: Double = 5
    public var outputFormat: String = "mp4"

    public static let timeoutRange = 5...900
    public static let pollIntervalRange = 0...60
    public static let pollAttemptsRange = 1...600
    static let endpointKey = "videogen.endpoint", modelKey = "videogen.model"
    static let apiKeyKey = "videogen.apiKey", timeoutKey = "videogen.timeout"
    static let pollIntervalKey = "videogen.pollInterval", pollAttemptsKey = "videogen.pollAttempts"
    static let sizeKey = "videogen.size", durationKey = "videogen.duration", formatKey = "videogen.format"

    public init() {}

    public static func load(from d: UserDefaults = DataLocations.current.defaults, secrets: SecretStore = .shared) -> VideoGenerationSettings {
        var s = VideoGenerationSettings()
        s.endpoint = d.string(forKey: endpointKey) ?? ""
        s.model = d.string(forKey: modelKey) ?? ""
        s.apiKey = secrets.load(account: apiKeyKey, migratingFrom: d)
        let t = d.integer(forKey: timeoutKey)
        s.timeoutSeconds = t == 0 ? 300 : min(max(t, timeoutRange.lowerBound), timeoutRange.upperBound)
        if d.object(forKey: pollIntervalKey) != nil {
            s.pollIntervalSeconds = min(max(d.integer(forKey: pollIntervalKey), pollIntervalRange.lowerBound), pollIntervalRange.upperBound)
        }
        let a = d.integer(forKey: pollAttemptsKey)
        s.maxPollAttempts = a == 0 ? 60 : min(max(a, pollAttemptsRange.lowerBound), pollAttemptsRange.upperBound)
        s.size = d.string(forKey: sizeKey) ?? VideoGenerationSize.landscape.rawValue
        let dur = d.double(forKey: durationKey)
        s.durationSeconds = dur > 0 ? dur : 5
        s.outputFormat = d.string(forKey: formatKey) ?? "mp4"
        return s
    }

    public func save(to d: UserDefaults = DataLocations.current.defaults, secrets: SecretStore = .shared) {
        d.set(endpoint, forKey: Self.endpointKey)
        d.set(model, forKey: Self.modelKey)
        secrets.set(apiKey, account: Self.apiKeyKey)
        d.removeObject(forKey: Self.apiKeyKey)
        d.set(timeoutSeconds, forKey: Self.timeoutKey)
        d.set(pollIntervalSeconds, forKey: Self.pollIntervalKey)
        d.set(maxPollAttempts, forKey: Self.pollAttemptsKey)
        d.set(size, forKey: Self.sizeKey)
        d.set(durationSeconds, forKey: Self.durationKey)
        d.set(outputFormat, forKey: Self.formatKey)
    }

    public static func endpointProblem(_ raw: String) -> String? {
        TextGenerationSettings.endpointProblem(raw)
    }

    public var isConfigured: Bool {
        !model.trimmingCharacters(in: .whitespaces).isEmpty && Self.endpointProblem(endpoint) == nil
    }

    public func makeProvider(transport: ImageGenerationTransport = URLSessionImageTransport(),
                             outputDirectory: URL = GeneratedMediaStore.directory()) throws -> OpenAICompatibleVideoProvider {
        if let problem = Self.endpointProblem(endpoint) {
            if endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw GenerativeMediaError.notConfigured
            }
            throw GenerativeMediaError.invalidEndpoint(problem)
        }
        guard !model.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw GenerativeMediaError.notConfigured
        }
        guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw GenerativeMediaError.invalidEndpoint("URL の形になっていません")
        }
        return OpenAICompatibleVideoProvider(endpoint: url,
                                             model: model.trimmingCharacters(in: .whitespaces),
                                             apiKey: apiKey,
                                             timeout: TimeInterval(timeoutSeconds),
                                             pollIntervalSeconds: Double(pollIntervalSeconds),
                                             maxPollAttempts: maxPollAttempts,
                                             transport: transport,
                                             outputDirectory: outputDirectory)
    }

    public var destinationDescription: String {
        guard isConfigured else { return "(未設定)" }
        return "\(endpoint) / モデル: \(model)"
    }

    /// 送信前確認の内容を作る(キーは含めない)。費用の注意文は共通の
    /// `GenerativeMediaConfirmation.costNote`(あなたの API アカウントに
    /// 課金され、MovieCut のサーバは経由しない)が summaryText に入る。
    public func confirmation(prompt: String, size: String? = nil, duration: Double? = nil, format: String? = nil) -> GenerativeMediaConfirmation {
        let useSize = size ?? self.size
        let sizeText = VideoGenerationSize(rawValue: useSize)?.title ?? useSize
        let dur = duration ?? durationSeconds
        let fmt = GeneratedMediaStore.sanitizedFormat(format ?? outputFormat, for: .video)
        return GenerativeMediaConfirmation(kind: .video, destination: destinationDescription,
                                           prompt: prompt, model: model,
                                           sizeDescription: "\(sizeText) / \(Self.secondsText(dur))秒 / \(fmt)")
    }

    public static func secondsText(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(v)
    }
}

// MARK: - 設定(音声 / 音楽)

public struct AudioGenerationSettings: Equatable, Sendable {
    public var endpoint: String = ""
    public var model: String = ""
    /// APIキー。この Mac のアプリ設定にだけ保存し、プロジェクト・ログ・確認文には出さない。
    public var apiKey: String = ""
    public var timeoutSeconds: Int = 300
    public var durationSeconds: Double = 10
    public var outputFormat: String = "mp3"

    public static let timeoutRange = 5...900
    static let endpointKey = "audiogen.endpoint", modelKey = "audiogen.model"
    static let apiKeyKey = "audiogen.apiKey", timeoutKey = "audiogen.timeout"
    static let durationKey = "audiogen.duration", formatKey = "audiogen.format"

    public init() {}

    public static func load(from d: UserDefaults = DataLocations.current.defaults, secrets: SecretStore = .shared) -> AudioGenerationSettings {
        var s = AudioGenerationSettings()
        s.endpoint = d.string(forKey: endpointKey) ?? ""
        s.model = d.string(forKey: modelKey) ?? ""
        s.apiKey = secrets.load(account: apiKeyKey, migratingFrom: d)
        let t = d.integer(forKey: timeoutKey)
        s.timeoutSeconds = t == 0 ? 300 : min(max(t, timeoutRange.lowerBound), timeoutRange.upperBound)
        let dur = d.double(forKey: durationKey)
        s.durationSeconds = dur > 0 ? dur : 10
        s.outputFormat = d.string(forKey: formatKey) ?? "mp3"
        return s
    }

    public func save(to d: UserDefaults = DataLocations.current.defaults, secrets: SecretStore = .shared) {
        d.set(endpoint, forKey: Self.endpointKey)
        d.set(model, forKey: Self.modelKey)
        secrets.set(apiKey, account: Self.apiKeyKey)
        d.removeObject(forKey: Self.apiKeyKey)
        d.set(timeoutSeconds, forKey: Self.timeoutKey)
        d.set(durationSeconds, forKey: Self.durationKey)
        d.set(outputFormat, forKey: Self.formatKey)
    }

    public static func endpointProblem(_ raw: String) -> String? {
        TextGenerationSettings.endpointProblem(raw)
    }

    public var isConfigured: Bool {
        !model.trimmingCharacters(in: .whitespaces).isEmpty && Self.endpointProblem(endpoint) == nil
    }

    public func makeProvider(transport: ImageGenerationTransport = URLSessionImageTransport(),
                             outputDirectory: URL = GeneratedMediaStore.directory()) throws -> OpenAICompatibleAudioProvider {
        if let problem = Self.endpointProblem(endpoint) {
            if endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw GenerativeMediaError.notConfigured
            }
            throw GenerativeMediaError.invalidEndpoint(problem)
        }
        guard !model.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw GenerativeMediaError.notConfigured
        }
        guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw GenerativeMediaError.invalidEndpoint("URL の形になっていません")
        }
        return OpenAICompatibleAudioProvider(endpoint: url,
                                             model: model.trimmingCharacters(in: .whitespaces),
                                             apiKey: apiKey,
                                             timeout: TimeInterval(timeoutSeconds),
                                             transport: transport,
                                             outputDirectory: outputDirectory)
    }

    public var destinationDescription: String {
        guard isConfigured else { return "(未設定)" }
        return "\(endpoint) / モデル: \(model)"
    }

    /// 送信前確認の内容を作る(キーは含めない)。費用の注意文は共通の costNote。
    public func confirmation(kind: GenerativeMediaKind, prompt: String, duration: Double? = nil, format: String? = nil) -> GenerativeMediaConfirmation {
        let dur = duration ?? durationSeconds
        let fmt = GeneratedMediaStore.sanitizedFormat(format ?? outputFormat, for: kind)
        return GenerativeMediaConfirmation(kind: kind, destination: destinationDescription,
                                           prompt: prompt, model: model,
                                           sizeDescription: "\(fmt) / \(VideoGenerationSettings.secondsText(dur))秒")
    }
}

// MARK: - 生成延長の口(Core 計画と配置)

/// 生成延長で作る 1 区間(元のクリップの前か後ろ)。
public struct GenerativeExtensionSegment: Equatable, Sendable {
    public var isHead: Bool
    public var start: Double
    public var duration: Double
    public init(isHead: Bool, start: Double, duration: Double) {
        self.isHead = isHead
        self.start = start
        self.duration = duration
    }
}

/// 生成延長の計画(純粋な値)。元のクリップは書き換えず、前後の区間に
/// 生成セグメントを置くための計画だけを持つ。実生成は
/// `generationRequests(prompt:)` を動画/音声プロバイダへ渡して行う。
public struct GenerativeExtensionPlan: Equatable, Sendable {
    public var clipID: String
    /// 生成する種類(動画クリップなら .video、音声クリップなら .audio)。
    public var kind: GenerativeMediaKind
    public var originalStart: Double
    public var originalDuration: Double
    public var headSeconds: Double
    public var tailSeconds: Double

    public init(clipID: String, kind: GenerativeMediaKind, originalStart: Double, originalDuration: Double,
                headSeconds: Double, tailSeconds: Double) {
        self.clipID = clipID
        self.kind = kind
        self.originalStart = originalStart
        self.originalDuration = originalDuration
        self.headSeconds = headSeconds
        self.tailSeconds = tailSeconds
    }

    /// 延長後の全体の範囲(前セグメントの頭 〜 後セグメントの尻)。
    public var extendedStart: Double { max(0, originalStart - headSeconds) }
    public var extendedDuration: Double { originalDuration + headSeconds + tailSeconds }

    public var headSegment: GenerativeExtensionSegment? {
        headSeconds > 0 ? GenerativeExtensionSegment(isHead: true, start: extendedStart, duration: headSeconds) : nil
    }
    public var tailSegment: GenerativeExtensionSegment? {
        tailSeconds > 0 ? GenerativeExtensionSegment(isHead: false, start: originalStart + originalDuration, duration: tailSeconds) : nil
    }
    public var segments: [GenerativeExtensionSegment] { [headSegment, tailSegment].compactMap { $0 } }

    /// 説明文(確認画面用。例: 「前に 2 秒、後ろに 3 秒」)。
    public var summaryDescription: String {
        var parts: [String] = []
        if headSeconds > 0 { parts.append("前に \(VideoGenerationSettings.secondsText(headSeconds)) 秒") }
        if tailSeconds > 0 { parts.append("後ろに \(VideoGenerationSettings.secondsText(tailSeconds)) 秒") }
        return parts.joined(separator: "、")
    }

    /// 実生成のための依頼列(前 → 後ろの順)。配置時刻と長さは計画どおり。
    public func generationRequests(prompt: String, size: String? = nil, outputFormat: String? = nil) -> [GenerativeMediaRequest] {
        segments.map {
            GenerativeMediaRequest(kind: kind, prompt: prompt, targetStart: $0.start,
                                   targetDuration: $0.duration, size: size, outputFormat: outputFormat)
        }
    }
}

/// 生成延長の計画を作る。対象は動画・音声クリップだけ。前後どちらかは
/// 0 より大きく、片側は `maxSeconds` まで。元クリップは変更しない。
public enum GenerativeExtensionPlanner {
    public static let maxSeconds: Double = 30

    public static func supports(_ clip: Clip) -> Bool {
        clip.type == .video || clip.type == .audio
    }

    public static func kind(for clip: Clip) -> GenerativeMediaKind? {
        switch clip.type {
        case .video: return .video
        case .audio: return .audio
        default: return nil
        }
    }

    public static func plan(clip: Clip, headSeconds: Double, tailSeconds: Double) throws -> GenerativeExtensionPlan {
        guard let kind = kind(for: clip) else {
            throw GenerativeMediaError.invalidExtension("動画か音声のクリップを選んでください")
        }
        guard clip.duration > 0 else {
            throw GenerativeMediaError.invalidExtension("クリップの長さがありません")
        }
        for (label, v) in [("前", headSeconds), ("後ろ", tailSeconds)] {
            guard v.isFinite, v >= 0 else {
                throw GenerativeMediaError.invalidExtension("\(label)の秒数が正しくありません")
            }
            guard v <= maxSeconds else {
                throw GenerativeMediaError.invalidExtension("\(label)は \(VideoGenerationSettings.secondsText(maxSeconds)) 秒までです")
            }
        }
        guard headSeconds > 0 || tailSeconds > 0 else {
            throw GenerativeMediaError.invalidExtension("前か後ろのどちらかを 0 より大きくしてください")
        }
        // 前セグメントはタイムラインの 0 より前には置けないため、頭が 0 未満に
        // なる指定は、置ける分だけに切り詰めず明示的に止める。
        guard clip.start - headSeconds >= 0 else {
            throw GenerativeMediaError.invalidExtension("前の延長がタイムラインの先頭(0 秒)より前に出ます。前の秒数を \(VideoGenerationSettings.secondsText(clip.start)) 秒以下にしてください")
        }
        return GenerativeExtensionPlan(clipID: clip.id, kind: kind, originalStart: clip.start,
                                       originalDuration: clip.duration,
                                       headSeconds: headSeconds, tailSeconds: tailSeconds)
    }
}

/// 生成延長の結果配置(純粋関数)。前後の結果を計画の区間へ置く。
/// 元のクリップは一切書き換えない(Undo 登録は呼び出し側)。
public enum GenerativeExtensionPlacement {
    @discardableResult
    public static func place(plan: GenerativeExtensionPlan, headResult: GenerativeMediaResult?,
                             tailResult: GenerativeMediaResult?, in project: inout Project) -> [String] {
        var ids: [String] = []
        if let seg = plan.headSegment, let r = headResult {
            let fixed = GenerativeMediaResult(kind: plan.kind, fileURL: r.fileURL, duration: seg.duration)
            ids += GenerativeMediaPlacement.place(fixed, at: seg.start, in: &project)
        }
        if let seg = plan.tailSegment, let r = tailResult {
            let fixed = GenerativeMediaResult(kind: plan.kind, fileURL: r.fileURL, duration: seg.duration)
            ids += GenerativeMediaPlacement.place(fixed, at: seg.start, in: &project)
        }
        return ids
    }
}
