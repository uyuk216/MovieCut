import Foundation

/// VOICEVOX エンジンの HTTP クライアント(プラグイン専用)。
///
/// 内蔵 `VoicevoxClient` のロジックの「複製」。内蔵側は変更せずそのまま残してあり、
/// 手順・既定値・キャッシュキーの組み立ては内蔵と同一にしてある(等価性はテストで確認する)。
/// 型(`VoicevoxSpeaker` / `VoiceError` / `VoiceCache` / `VoiceEndpointPolicy`)は Core 既存のものを使う。
public struct VoicevoxPluginClient {
    public var baseURL: String
    public var cache: VoiceCache
    public var session: URLSession
    public var policy: VoiceEndpointPolicy

    public init(baseURL: String = "http://127.0.0.1:50021", cache: VoiceCache = .standard, session: URLSession = .shared, policy: VoiceEndpointPolicy = .current) {
        self.policy = policy
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.cache = cache
        self.session = session
    }

    /// encodeURIComponent 相当(英数と - . _ ~ 以外は %XX)。
    static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? s
    }

    /// 送信先の検査(ローカル以外は、設定で許可したホストだけ)。
    public func validatedBaseURL() throws -> URL { try policy.validate(baseURL) }

    private func url(_ path: String) throws -> URL {
        try policy.validate(baseURL)
        guard let u = URL(string: baseURL + path) else { throw VoiceError.message("VOICEVOX の URL が正しくありません: \(baseURL)") }
        return u
    }

    private func send(_ req: URLRequest, _ what: String) async throws -> Data {
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw VoiceError.http(what, code) }
        return data
    }

    /// GET /speakers
    public func speakers() async throws -> [VoicevoxSpeaker] {
        let data = try await send(URLRequest(url: try url("/speakers")), "speakers")
        guard let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw VoiceError.badResponse("speakers") }
        return arr.map { s in
            let styles = (s["styles"] as? [[String: Any]] ?? []).compactMap { st -> VoicevoxStyle? in
                guard let id = (st["id"] as? NSNumber)?.intValue else { return nil }
                return VoicevoxStyle(id: id, name: st["name"] as? String ?? "")
            }
            return VoicevoxSpeaker(name: s["name"] as? String ?? "", styles: styles)
        }
    }

    public static let defaultPrePhonemeLength = 0.03
    public static let defaultPostPhonemeLength = 0.03
    public static let defaultPauseLengthScale = 0.65

    /// POST /audio_query → パラメータ設定 → POST /synthesis → キャッシュへ書く。
    public func synthesize(text: String, speaker: Int, speed: Double? = nil, pitch: Double? = nil, intonation: Double? = nil, volume: Double? = nil, prePhonemeLength: Double? = nil, postPhonemeLength: Double? = nil, pauseLengthScale: Double? = nil) async throws -> URL {
        let pre = prePhonemeLength ?? Self.defaultPrePhonemeLength
        let post = postPhonemeLength ?? Self.defaultPostPhonemeLength
        let pause = pauseLengthScale ?? Self.defaultPauseLengthScale
        let key = VoiceCache.key([.string("vv"), .string(baseURL), .string(text), .number(Double(speaker)), .opt(speed), .opt(pitch), .opt(intonation), .opt(volume), .number(pre), .number(post), .number(pause)])
        if let hit = cache.hit(forKey: key) { return hit }
        let out = try cache.url(forKey: key)

        var qreq = URLRequest(url: try url("/audio_query?text=\(Self.encode(text))&speaker=\(speaker)"))
        qreq.httpMethod = "POST"
        let qdata = try await send(qreq, "audio_query")
        guard var query = try JSONSerialization.jsonObject(with: qdata) as? [String: Any] else { throw VoiceError.badResponse("audio_query") }
        query["speedScale"] = speed ?? 1
        query["pitchScale"] = pitch ?? 0
        query["intonationScale"] = intonation ?? 1
        query["volumeScale"] = volume ?? 1
        query["prePhonemeLength"] = pre
        query["postPhonemeLength"] = post
        query["pauseLengthScale"] = pause

        var sreq = URLRequest(url: try url("/synthesis?speaker=\(speaker)"))
        sreq.httpMethod = "POST"
        sreq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        sreq.httpBody = try JSONSerialization.data(withJSONObject: query)
        let wav = try await send(sreq, "synthesis")
        let tmp = out.appendingPathExtension("part")
        try wav.write(to: tmp)
        _ = try? FileManager.default.removeItem(at: out)
        try FileManager.default.moveItem(at: tmp, to: out)
        return out
    }
}

/// VOICEVOX プラグインの `VoiceProvider`。処理手順は `RealVoiceProvider` の voicevox 分岐と同一。
public final class VoicevoxPluginProvider: VoiceProvider {
    public let baseURL: String
    public let client: VoicevoxPluginClient
    public let engine: VoicevoxEngine
    /// 可用性チェックの差し替え点(テスト用)。nil なら `engine.ensureRunning(baseURL:)` を使う。
    var engineAvailabilityOverride: (@Sendable (String) async -> Bool)?

    public init(baseURL: String, cache: VoiceCache = .standard, engine: VoicevoxEngine = VoicevoxEngine(), session: URLSession = .shared, policy: VoiceEndpointPolicy = .current) {
        self.baseURL = baseURL
        self.client = VoicevoxPluginClient(baseURL: baseURL, cache: cache, session: session, policy: policy)
        self.engine = engine
    }

    public convenience init(project: Project, cache: VoiceCache = .standard, engine: VoicevoxEngine = VoicevoxEngine(), session: URLSession = .shared, policy: VoiceEndpointPolicy = .current) {
        self.init(baseURL: project.voicevoxUrl, cache: cache, engine: engine, session: session, policy: policy)
    }

    public func synthesize(character: Character, text: String, in directory: URL) async throws -> VoiceResult {
        _ = try client.validatedBaseURL()   // 送ってよい先か(だめなら日本語の理由で止める)
        let available: Bool
        if let override = engineAvailabilityOverride {
            available = await override(baseURL)
        } else {
            available = await engine.ensureRunning(baseURL: baseURL)
        }
        guard available else {
            throw VoiceError.message("VOICEVOX に接続できません。VOICEVOX をインストールして起動するか、インスペクタでこのキャラの音声エンジンを「ゆっくり (AquesTalk)」に切り替えてください(\(DependencyStatus.voicevoxURL))。")
        }
        let url = try await client.synthesize(text: text, speaker: character.speaker ?? 3, speed: character.speed, pitch: character.pitch, intonation: character.intonation, prePhonemeLength: character.prePhonemeLength, postPhonemeLength: character.postPhonemeLength, pauseLengthScale: character.pauseLengthScale)
        return VoiceResult(url: url, duration: try WavFile.duration(of: url))
    }
}

/// VOICEVOX プラグインの名前空間(マニフェスト)。
public enum VoicevoxPlugin {
    public static let pluginID = "jp.local.moviecut.plugin.voicevox"

    public static var manifest: PluginManifest {
        PluginManifest(id: pluginID,
                       name: "VOICEVOX",
                       version: "1.0.0",
                       hooks: [.voice],
                       entryPoint: "VoicevoxPlugin",
                       minimumAppVersion: nil,
                       voiceEngineIDs: ["voicevox"],
                       requiresLicense: false,
                       description: "VOICEVOX エンジンで音声合成するプラグイン(組み込み)")
    }

    /// `manifest.json` の中身(PluginDiscovery で読める形)。
    public static func manifestJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(manifest), as: UTF8.self)
    }
}

/// アプリに組み込まれたプラグインを実体化するローダ(キー = プラグイン id)。
public final class BuiltinPluginLoader: PluginLoader {
    private let factories: [String: () throws -> LoadedPlugin]

    public init(_ factories: [String: () throws -> LoadedPlugin]) { self.factories = factories }

    public func loadPlugin(manifest: PluginManifest, directory: URL) throws -> LoadedPlugin {
        guard let factory = factories[manifest.id] else { throw PluginError.notRegistered(pluginID: manifest.id) }
        return try factory()
    }
}
