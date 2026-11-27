import Foundation

/// VOICEVOX 系エンジン(COEIROINK v1 / SHAREVOX など)の共通定義。
///
/// COEIROINK(v1 系。v2 については `CoeiroinkPlugin` の注記参照)と SHAREVOX は、VOICEVOX と
/// 同系統のローカル HTTP API(GET /speakers、POST /audio_query、POST /synthesis、GET /version)を
/// 持ち、接続先ポートだけが違う。そのため合成手順は本ファイルの共通クライアント 1 つに寄せ、
/// エンジンごとの差(識別子・表示名・既定 URL・キャッシュタグ・プラグイン id)は
/// `VoicevoxFamilyEngineSpec` の値でだけ表す(二重実装を避けるため)。
///
/// 内蔵 `VoicevoxClient` / プラグイン `VoicevoxPluginClient` には一切手を入れない。
/// 手順・既定値(pre/post/pause)・パラメータ変換(speedScale 等)は VOICEVOX プラグインと同一にしてある。
/// キャッシュキーだけは先頭タグをエンジン別にしてあり、VOICEVOX のキャッシュと混ざらない。
public struct VoicevoxFamilyEngineSpec: Equatable, Sendable {
    /// `Character.engine` の値。
    public var engineID: String
    /// 表示名(エラーメッセージ・案内用)。
    public var displayName: String
    /// 既定の接続先。
    public var defaultBaseURL: String
    /// キャッシュキーの先頭タグ(エンジンごとに分ける)。
    public var cacheTag: String
    /// プラグイン id。
    public var pluginID: String

    public init(engineID: String, displayName: String, defaultBaseURL: String, cacheTag: String, pluginID: String) {
        self.engineID = engineID
        self.displayName = displayName
        self.defaultBaseURL = defaultBaseURL
        self.cacheTag = cacheTag
        self.pluginID = pluginID
    }
}

/// 追加 TTS エンジン(COEIROINK / SHAREVOX)の名前空間。
public enum VoicevoxFamily {
    /// VOICEVOX 本体を除く、VOICEVOX 系プラグインが担当するエンジン識別子。
    public static let additionalEngineIDs: [String] = ["coeiroink", "sharevox"]

    public static func isAdditionalEngine(_ engine: String) -> Bool {
        additionalEngineIDs.contains(engine)
    }

    /// VOICEVOX と同じパラメータ体系(話速は倍率、話者は数値 ID)を持つエンジンか。
    /// VOICEVOX 本体も含む。キャラ編集(速さの単位・話者の既定値)や「声を選んだか」の判定で使う。
    public static func isVoicevoxStyleEngine(_ engine: String) -> Bool {
        engine == "voicevox" || isAdditionalEngine(engine)
    }

    /// エンジン識別子から仕様を引く。追加エンジン以外は nil。
    public static func spec(forEngine engine: String) -> VoicevoxFamilyEngineSpec? {
        switch engine {
        case CoeiroinkPlugin.engineID: return CoeiroinkPlugin.spec
        case SharevoxPlugin.engineID: return SharevoxPlugin.spec
        default: return nil
        }
    }

    /// エンジン識別子の表示名(VOICEVOX 本体を含む)。未知のエンジンは nil。
    public static func displayName(forEngine engine: String) -> String? {
        if engine == "voicevox" { return "VOICEVOX" }
        return spec(forEngine: engine)?.displayName
    }
}

/// VOICEVOX 系エンジンが生きているか(GET /version)。
///
/// VOICEVOX プラグインと違い、こちらはエンジンの自動起動をしない。
/// 理由: COEIROINK / SHAREVOX は単体のアプリで、VOICEVOX のような
/// 「同梱エンジンバイナリを決まった引数で起動する」公式な手順が確認できていないため。
/// ユーザーがアプリを起動した状態で使う前提とし、接続できないときはその旨を案内する。
public enum VoicevoxFamilyAvailability {
    public static func isAlive(baseURL: String, timeout: TimeInterval = 0.8, session: URLSession = .shared, policy: VoiceEndpointPolicy = .current) async -> Bool {
        guard (try? policy.validate(baseURL)) != nil else { return false }
        guard let u = URL(string: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/version") else { return false }
        var req = URLRequest(url: u)
        req.timeoutInterval = timeout
        req.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (_, resp) = try await session.data(for: req)
            return (resp as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
        } catch { return false }
    }
}

/// VOICEVOX 系エンジンの HTTP クライアント(プラグイン専用・共通実装)。
///
/// `VoicevoxPluginClient` の複製を土台に、エンジン差分だけを `spec` で差し替えたもの。
/// 内蔵側・VOICEVOX プラグイン側は変更せずそのまま残してある。
public struct VoicevoxFamilyPluginClient {
    public var spec: VoicevoxFamilyEngineSpec
    public var baseURL: String
    public var cache: VoiceCache
    public var session: URLSession
    public var policy: VoiceEndpointPolicy

    public init(spec: VoicevoxFamilyEngineSpec, baseURL: String? = nil, cache: VoiceCache = .standard, session: URLSession = .shared, policy: VoiceEndpointPolicy = .current) {
        self.spec = spec
        let raw = baseURL ?? spec.defaultBaseURL
        self.baseURL = raw.hasSuffix("/") ? String(raw.dropLast()) : raw
        self.cache = cache
        self.session = session
        self.policy = policy
    }

    /// 送信先の検査(ローカル以外は、設定で許可したホストだけ)。VOICEVOX と同じ方針をそのまま使う。
    public func validatedBaseURL() throws -> URL { try policy.validate(baseURL) }

    private func url(_ path: String) throws -> URL {
        try policy.validate(baseURL)
        guard let u = URL(string: baseURL + path) else { throw VoiceError.message("\(spec.displayName) の URL が正しくありません: \(baseURL)") }
        return u
    }

    private func send(_ req: URLRequest, _ what: String) async throws -> Data {
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw VoiceError.http(what, code) }
        return data
    }

    /// 任意パスの GET(話者一覧の別形式など、エンジン固有の読み取りに使う)。
    func getData(_ path: String, _ what: String) async throws -> Data {
        try await send(URLRequest(url: try url(path)), what)
    }

    /// GET /speakers(VOICEVOX 系共通の形式: name + styles[{id, name}])。
    public func speakers() async throws -> [VoicevoxSpeaker] {
        let data = try await getData("/speakers", "speakers")
        guard let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw VoiceError.badResponse("speakers") }
        return arr.map { s in
            let styles = (s["styles"] as? [[String: Any]] ?? []).compactMap { st -> VoicevoxStyle? in
                guard let id = (st["id"] as? NSNumber)?.intValue else { return nil }
                return VoicevoxStyle(id: id, name: st["name"] as? String ?? "")
            }
            return VoicevoxSpeaker(name: s["name"] as? String ?? "", styles: styles)
        }
    }

    /// 間のパラメータの既定値。VOICEVOX プラグインと同一。
    public static let defaultPrePhonemeLength = VoicevoxPluginClient.defaultPrePhonemeLength
    public static let defaultPostPhonemeLength = VoicevoxPluginClient.defaultPostPhonemeLength
    public static let defaultPauseLengthScale = VoicevoxPluginClient.defaultPauseLengthScale

    /// POST /audio_query → accent_phrases を型にして返す(アクセント編集の初期値用。キャッシュには触れない)。
    public func accentPhrases(text: String, speaker: Int) async throws -> [VoicevoxAccentPhrase] {
        var qreq = URLRequest(url: try url("/audio_query?text=\(VoicevoxClient.encode(text))&speaker=\(speaker)"))
        qreq.httpMethod = "POST"
        let qdata = try await send(qreq, "audio_query")
        guard let query = try JSONSerialization.jsonObject(with: qdata) as? [String: Any],
              let phrases = VoicevoxAccent.phrases(fromQuery: query) else { throw VoiceError.badResponse("audio_query") }
        return phrases
    }

    /// POST /audio_query → パラメータ設定 → POST /synthesis → キャッシュへ書く。
    /// パラメータ変換(speedScale / pitchScale / intonationScale / volumeScale / pre / post / pause)は
    /// VOICEVOX プラグインと同一。キャッシュキーの先頭タグと接続先だけがエンジンごとに違う。
    public func synthesize(text: String, speaker: Int, speed: Double? = nil, pitch: Double? = nil, intonation: Double? = nil, volume: Double? = nil, prePhonemeLength: Double? = nil, postPhonemeLength: Double? = nil, pauseLengthScale: Double? = nil, accentPhrases: [VoicevoxAccentPhrase]? = nil) async throws -> URL {
        let pre = prePhonemeLength ?? Self.defaultPrePhonemeLength
        let post = postPhonemeLength ?? Self.defaultPostPhonemeLength
        let pause = pauseLengthScale ?? Self.defaultPauseLengthScale
        var keyParts: [JSONValue] = [.string(spec.cacheTag), .string(baseURL), .string(text), .number(Double(speaker)), .opt(speed), .opt(pitch), .opt(intonation), .opt(volume), .number(pre), .number(post), .number(pause)]
        // アクセント句を差し替えるときだけ、その内容(安定 JSON)をキーへ足す。nil ならキーに足さない(VOICEVOX プラグインと同じ)。
        if let accentPhrases { keyParts.append(.string(VoicevoxAccent.stableJSON(accentPhrases))) }
        let key = VoiceCache.key(keyParts)
        if let hit = cache.hit(forKey: key) { return hit }
        let out = try cache.url(forKey: key)

        var qreq = URLRequest(url: try url("/audio_query?text=\(VoicevoxClient.encode(text))&speaker=\(speaker)"))
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
        if let accentPhrases { query["accent_phrases"] = try VoicevoxAccent.jsonObject(from: accentPhrases) }

        var sreq = URLRequest(url: try url("/synthesis?speaker=\(speaker)"))
        sreq.httpMethod = "POST"
        sreq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        sreq.httpBody = try JSONSerialization.data(withJSONObject: query)
        let wav = try await send(sreq, "synthesis")
        let tmp = out.appendingPathExtension("part-\(UUID().uuidString)")
        try wav.write(to: tmp)
        try VoiceCache.replaceItem(at: out, with: tmp)
        return out
    }
}

/// VOICEVOX 系追加エンジンの `VoiceProvider`(COEIROINK / SHAREVOX 共通)。
/// 処理手順は `VoicevoxPluginProvider` と同一(接続確認 → 合成 → 長さ計測)。
/// 違いは「自動起動せず、生きているかだけを見る」点と、案内文のエンジン名だけ。
public final class VoicevoxFamilyPluginProvider: VoicevoxAccentProviding {
    public let spec: VoicevoxFamilyEngineSpec
    public let baseURL: String
    public let client: VoicevoxFamilyPluginClient
    /// 可用性チェックの差し替え点(テスト用)。nil なら `VoicevoxFamilyAvailability.isAlive` を使う。
    var engineAvailabilityOverride: (@Sendable (String) async -> Bool)?

    public init(spec: VoicevoxFamilyEngineSpec, baseURL: String? = nil, cache: VoiceCache = .standard, session: URLSession = .shared, policy: VoiceEndpointPolicy = .current) {
        self.spec = spec
        self.client = VoicevoxFamilyPluginClient(spec: spec, baseURL: baseURL, cache: cache, session: session, policy: policy)
        self.baseURL = client.baseURL
    }

    public func synthesize(character: Character, text: String, in directory: URL) async throws -> VoiceResult {
        try await synthesize(character: character, text: text, accentPhrases: nil, in: directory)
    }

    /// アクセント句つき合成。VOICEVOX 系エンジンは VOICEVOX と同じ audio_query 形式なので、
    /// VOICEVOX プラグインと同じく accent_phrases を差し替えて合成できる。
    public func synthesizeWithAccent(character: Character, text: String, accentPhrases: [VoicevoxAccentPhrase], in directory: URL) async throws -> VoiceResult {
        try await synthesize(character: character, text: text, accentPhrases: accentPhrases, in: directory)
    }

    private func synthesize(character: Character, text: String, accentPhrases: [VoicevoxAccentPhrase]?, in directory: URL) async throws -> VoiceResult {
        _ = try client.validatedBaseURL()   // 送ってよい先か(だめなら日本語の理由で止める)
        let available: Bool
        if let override = engineAvailabilityOverride {
            available = await override(baseURL)
        } else {
            available = await VoicevoxFamilyAvailability.isAlive(baseURL: baseURL, session: client.session, policy: client.policy)
        }
        guard available else {
            throw VoiceError.message("\(spec.displayName) に接続できません。\(spec.displayName) をインストールして起動するか、インスペクタでこのキャラの音声エンジンを切り替えてください(既定の接続先 \(spec.defaultBaseURL))。")
        }
        let url = try await client.synthesize(text: text, speaker: character.speaker ?? 3, speed: character.speed, pitch: character.pitch, intonation: character.intonation, prePhonemeLength: character.prePhonemeLength, postPhonemeLength: character.postPhonemeLength, pauseLengthScale: character.pauseLengthScale, accentPhrases: accentPhrases)
        RealVoiceProvider.scheduleEnvelopeSidecar(wavURL: url, text: text)
        return VoiceResult(url: url, duration: try WavFile.duration(of: url))
    }
}
