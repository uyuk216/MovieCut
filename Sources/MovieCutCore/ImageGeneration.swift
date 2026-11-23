import Foundation

// MARK: - 画像生成の API 直接連携(生成メディア共通連携口の最初の実装)
//
// ユーザーが自分の API キーを設定すると、プロンプトから画像を生成して
// 画像クリップとして配置できる。対応形式は OpenAI 互換の画像生成
// エンドポイント(images generations 形式)で、特定ベンダーには固定しない:
// エンドポイント URL・モデル名はユーザーが設定で自由に指定する。
//
// 作法は AI テキスト生成(`TextGeneration.swift`)とそろえてある:
// - 接続情報はユーザー自身がアプリの設定で入れる(`ImageGenerationSettings`。
//   保存先はこの Mac のアプリ設定(UserDefaults)だけで、プロジェクトには書かない)。
// - API キーは Authorization ヘッダーにだけ使う。コード・ログ・プロジェクト・
//   送信前確認の文には出さない。
// - 未設定のときは機能が無効になる(`isConfigured` が false、
//   `makeProvider()` は `GenerativeMediaError.notConfigured` を投げる)。
// - http で送れるのはこの Mac 自身(localhost)宛てだけ。外部は https 必須。
// - 通信は `ImageGenerationTransport` 境界の後ろにあり、テストでは差し替えられる
//   (実キーでの疎通は未検証。検証はモック応答まで)。
//
// 既存の AI 画像生成フック(ローカルコマンド方式 `AIImage.swift`)とは独立した
// 追加で、その挙動は変えない。生成ファイルの置き場所は同じ
// `AIImageStore`(Application Support/MovieCut/AIImages)。

/// 画像の大きさの候補(OpenAI 互換で広く使われる 3 種)。設定では文字列で持ち、
/// この候補以外の文字列もそのまま送れる(サービス側の指定に従う)。
public enum ImageGenerationSize: String, CaseIterable, Sendable {
    case square = "1024x1024"
    case landscape = "1792x1024"
    case portrait = "1024x1792"

    public var title: String {
        switch self {
        case .square: return "正方形 (1024×1024)"
        case .landscape: return "横長 (1792×1024)"
        case .portrait: return "縦長 (1024×1792)"
        }
    }
}

/// HTTP 通信の差し替え口(テストでは実通信をせずに済む)。
public protocol ImageGenerationTransport: Sendable {
    /// 応答の本文と HTTP 状態コードを返す。通信失敗は throw。
    func send(_ request: URLRequest) async throws -> (Data, Int)
}

/// URLSession による実通信。
public struct URLSessionImageTransport: ImageGenerationTransport {
    public init() {}
    public func send(_ request: URLRequest) async throws -> (Data, Int) {
        do {
            let (stream, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw GenerativeMediaError.transport("HTTP の応答ではありませんでした")
            }
            let cap = MediaDownloadPolicy.maxBytes
            if http.expectedContentLength > Int64(cap) { throw GenerativeMediaError.downloadTooLarge(limit: cap) }
            var data = Data()
            var chunk = [UInt8](); chunk.reserveCapacity(65_536)
            for try await b in stream {
                chunk.append(b)
                if chunk.count == 65_536 {
                    data.append(contentsOf: chunk); chunk.removeAll(keepingCapacity: true)
                    if data.count > cap { throw GenerativeMediaError.downloadTooLarge(limit: cap) }
                }
            }
            data.append(contentsOf: chunk)
            if data.count > cap { throw GenerativeMediaError.downloadTooLarge(limit: cap) }
            return (data, http.statusCode)
        } catch let e as GenerativeMediaError {
            throw e
        } catch is CancellationError {
            throw GenerativeMediaError.cancelled
        } catch {
            throw GenerativeMediaError.transport(error.localizedDescription)
        }
    }
}

/// ユーザーが設定したエンドポイントへ送る汎用クライアント
/// (OpenAI 互換 images generations 形式)。
/// 送り先の URL は設定そのまま(例: `https://…/v1/images/generations`、
/// `http://127.0.0.1:…/v1/images/generations`)。
public struct OpenAICompatibleImageProvider: GenerativeMediaProvider {
    public let endpoint: URL
    public let model: String
    private let apiKey: String
    public let timeout: TimeInterval
    public let transport: ImageGenerationTransport
    /// 生成ファイルの置き場所(テストでは一時フォルダに差し替える)。
    public let outputDirectory: URL

    public init(endpoint: URL, model: String, apiKey: String = "", timeout: TimeInterval = 120,
                transport: ImageGenerationTransport = URLSessionImageTransport(),
                outputDirectory: URL = AIImageStore.directory()) {
        self.endpoint = endpoint
        self.model = model
        self.apiKey = apiKey
        self.timeout = timeout
        self.transport = transport
        self.outputDirectory = outputDirectory
    }

    public var supportedKinds: [GenerativeMediaKind] { [.image] }

    public var destinationDescription: String { "\(endpoint.absoluteString) / モデル: \(model)" }

    /// 送る URLRequest(テストで中身を確認できるよう公開)。キーはヘッダーにだけ入る。
    public func makeRequest(_ request: GenerativeMediaRequest) throws -> URLRequest {
        try request.validate()
        let body: [String: Any] = [
            "model": model,
            "prompt": request.trimmedPrompt,
            "size": request.size ?? ImageGenerationSize.square.rawValue,
            "n": 1,
            "response_format": "b64_json",
        ]
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    /// 応答 JSON から、Base64 の画像データを取り出す(images generations の
    /// `data[0].b64_json`)。純粋関数。
    public static func base64ImageData(from data: Data) throws -> Data? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = obj["data"] as? [[String: Any]] else {
            throw GenerativeMediaError.unparsable("生成結果")
        }
        guard let first = items.first else { throw GenerativeMediaError.emptyResponse }
        guard let b64 = first["b64_json"] as? String, !b64.isEmpty else { return nil }
        guard let decoded = Data(base64Encoded: b64) else {
            throw GenerativeMediaError.unparsable("生成結果の画像データ")
        }
        return decoded
    }

    /// 応答 JSON から、画像の URL を取り出す(`data[0].url`。Base64 を返さない
    /// サービス向けの受け皿)。純粋関数。
    public static func imageURL(from data: Data) -> URL? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = obj["data"] as? [[String: Any]], let first = items.first,
              let s = first["url"] as? String, !s.isEmpty else { return nil }
        return URL(string: s)
    }

    public func generate(_ request: GenerativeMediaRequest) async throws -> GenerativeMediaResult {
        guard request.kind == .image else { throw GenerativeMediaError.unsupportedKind(request.kind) }
        let url = try await generateImageFile(request)
        return GenerativeMediaResult(kind: .image, fileURL: url, duration: 0)
    }

    /// 画像を生成してファイルに書き、その URL を返す。書かれた内容が画像として
    /// 読めなければ、ファイルを残さず失敗する(ローカルコマンド方式と同じ作法)。
    public func generateImageFile(_ request: GenerativeMediaRequest) async throws -> URL {
        let urlRequest = try makeRequest(request)
        let (data, status) = try await transport.send(urlRequest)
        guard (200..<300).contains(status) else {
            throw GenerativeMediaError.http(status, String(decoding: data, as: UTF8.self))
        }
        var imageData = try Self.base64ImageData(from: data)
        if imageData == nil, let remote = Self.imageURL(from: data) {
            // Base64 が無いサービスは、返された URL から画像を取りに行く
            let get = try MediaDownloadPolicy.downloadRequest(url: remote, endpoint: endpoint, apiKey: apiKey, timeout: timeout)
            let (downloaded, dlStatus) = try await transport.send(get)
            guard (200..<300).contains(dlStatus) else {
                throw GenerativeMediaError.http(dlStatus, String(decoding: downloaded, as: UTF8.self))
            }
            try MediaDownloadPolicy.checkSize(downloaded)
            imageData = downloaded
        }
        guard let bytes = imageData, !bytes.isEmpty else { throw GenerativeMediaError.emptyResponse }
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let out = AIImageStore.newOutputURL(in: outputDirectory)
        do { try bytes.write(to: out) } catch {
            throw GenerativeMediaError.transport("生成した画像を保存できませんでした: \(error.localizedDescription)")
        }
        guard AIImageStore.isReadableImage(out) else {
            try? FileManager.default.removeItem(at: out)
            throw GenerativeMediaError.notAnImage
        }
        return out
    }
}

// MARK: - 設定(ユーザーがアプリ設定で入れる。プロジェクトには書かない)

public struct ImageGenerationSettings: Equatable, Sendable {
    /// 接続先の完全な URL(例: `https://api.example.com/v1/images/generations`)。
    public var endpoint: String = ""
    /// モデル名(サービス側の名前をそのまま)。
    public var model: String = ""
    /// APIキー。ユーザー自身が設定画面で入れたものだけが入る。この Mac のアプリ
    /// 設定にだけ保存し、プロジェクトファイル・ログ・送信前の確認文には出さない。
    /// ローカルなサービスでは空でよい。
    public var apiKey: String = ""
    public var timeoutSeconds: Int = 120
    /// 既定の大きさ(ImageGenerationSize の rawValue、または任意の文字列)。
    public var size: String = ImageGenerationSize.square.rawValue

    public static let timeoutRange = 5...900
    static let endpointKey = "imagegen.endpoint", modelKey = "imagegen.model"
    static let apiKeyKey = "imagegen.apiKey", timeoutKey = "imagegen.timeout", sizeKey = "imagegen.size"

    public init() {}

    public static func load(from d: UserDefaults = DataLocations.current.defaults, secrets: SecretStore = .shared) -> ImageGenerationSettings {
        var s = ImageGenerationSettings()
        s.endpoint = d.string(forKey: endpointKey) ?? ""
        s.model = d.string(forKey: modelKey) ?? ""
        s.apiKey = secrets.load(account: apiKeyKey, migratingFrom: d)
        let t = d.integer(forKey: timeoutKey)
        s.timeoutSeconds = t == 0 ? 120 : min(max(t, timeoutRange.lowerBound), timeoutRange.upperBound)
        s.size = d.string(forKey: sizeKey) ?? ImageGenerationSize.square.rawValue
        return s
    }

    public func save(to d: UserDefaults = DataLocations.current.defaults, secrets: SecretStore = .shared) {
        d.set(endpoint, forKey: Self.endpointKey)
        d.set(model, forKey: Self.modelKey)
        secrets.set(apiKey, account: Self.apiKeyKey)
        d.removeObject(forKey: Self.apiKeyKey)
        d.set(timeoutSeconds, forKey: Self.timeoutKey)
        d.set(size, forKey: Self.sizeKey)
    }

    /// エンドポイントが使える形か(検証結果)。判定は AI テキスト生成と共通
    /// (https は可。http はこの Mac 自身(localhost)宛てだけ可)。
    public static func endpointProblem(_ raw: String) -> String? {
        TextGenerationSettings.endpointProblem(raw)
    }

    /// 設定がそろっていて機能が有効か。未設定・不正なら false で、画面はその旨を出す。
    public var isConfigured: Bool {
        !model.trimmingCharacters(in: .whitespaces).isEmpty && Self.endpointProblem(endpoint) == nil
    }

    /// 設定からプロバイダを作る。未設定・不正なら日本語のエラー。
    public func makeProvider(transport: ImageGenerationTransport = URLSessionImageTransport(),
                             outputDirectory: URL = AIImageStore.directory()) throws -> OpenAICompatibleImageProvider {
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
        return OpenAICompatibleImageProvider(endpoint: url,
                                             model: model.trimmingCharacters(in: .whitespaces),
                                             apiKey: apiKey,
                                             timeout: TimeInterval(timeoutSeconds),
                                             transport: transport,
                                             outputDirectory: outputDirectory)
    }

    /// 送信先の説明(画面に出す。キーは含めない)。
    public var destinationDescription: String {
        guard isConfigured else { return "(未設定)" }
        return "\(endpoint) / モデル: \(model)"
    }

    /// 送信前確認の内容を作る(キーは含めない)。
    public func confirmation(prompt: String, size: String? = nil) -> GenerativeMediaConfirmation {
        let useSize = size ?? self.size
        let sizeText = ImageGenerationSize(rawValue: useSize)?.title ?? useSize
        return GenerativeMediaConfirmation(kind: .image, destination: destinationDescription,
                                           prompt: prompt, model: model, sizeDescription: sizeText)
    }
}

// MARK: - テスト用モック

/// 用意した画像データをファイルに書いて返す(または失敗させる)偽のプロバイダ。
/// 実サービスとの疎通なしに、生成 → 配置の流れを確認するために使う。
public final class FakeImageGenerationProvider: GenerativeMediaProvider, @unchecked Sendable {
    public enum Behavior: Sendable {
        case succeed(Data)
        case fail(GenerativeMediaError)
        case delay(seconds: Double, Data)
    }
    private let lock = NSLock()
    private var _requests: [GenerativeMediaRequest] = []
    public let behavior: Behavior
    public let outputDirectory: URL
    public let destinationDescription: String

    public init(_ behavior: Behavior, outputDirectory: URL = AIImageStore.directory(),
                destinationDescription: String = "モックの画像生成サービス") {
        self.behavior = behavior
        self.outputDirectory = outputDirectory
        self.destinationDescription = destinationDescription
    }

    public var supportedKinds: [GenerativeMediaKind] { [.image] }
    public var requests: [GenerativeMediaRequest] { lock.lock(); defer { lock.unlock() }; return _requests }

    public func generate(_ request: GenerativeMediaRequest) async throws -> GenerativeMediaResult {
        lock.withLock { _requests.append(request) }
        try request.validate()
        guard request.kind == .image else { throw GenerativeMediaError.unsupportedKind(request.kind) }
        let bytes: Data
        switch behavior {
        case .succeed(let d): bytes = d
        case .fail(let e): throw e
        case .delay(let sec, let d):
            do { try await Task.sleep(nanoseconds: UInt64((sec.isFinite ? max(0, min(sec, 3600)) : 0) * 1_000_000_000)) } catch { throw GenerativeMediaError.cancelled }
            bytes = d
        }
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let out = AIImageStore.newOutputURL(in: outputDirectory)
        try bytes.write(to: out)
        guard AIImageStore.isReadableImage(out) else {
            try? FileManager.default.removeItem(at: out)
            throw GenerativeMediaError.notAnImage
        }
        return GenerativeMediaResult(kind: .image, fileURL: out, duration: 0)
    }
}
