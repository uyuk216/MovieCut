import Foundation

/// COEIROINK の話者(v2 の /v1/speakers 形式)。話者は UUID で識別され、スタイルは数値 ID を持つ。
public struct CoeiroinkSpeaker: Equatable, Sendable {
    public var name: String
    public var uuid: String
    public var styles: [VoicevoxStyle]
    public init(name: String, uuid: String, styles: [VoicevoxStyle]) {
        self.name = name; self.uuid = uuid; self.styles = styles
    }
}

/// COEIROINK v2 のエンジン情報(GET /v1/engine_info の応答)。
public struct CoeiroinkEngineInfo: Equatable, Sendable {
    public var version: String
    public var device: String?
    public init(version: String, device: String?) {
        self.version = version; self.device = device
    }
}

/// COEIROINK v2 のスタイル ID から解決した「話者 + スタイル」の組。
/// v2 の合成は話者 UUID とスタイル ID の両方が要るため、話者一覧からこの形に解決してから合成する。
public struct CoeiroinkV2Voice: Equatable, Sendable {
    public var speakerName: String
    public var speakerUuid: String
    public var style: VoicevoxStyle
    public init(speakerName: String, speakerUuid: String, style: VoicevoxStyle) {
        self.speakerName = speakerName; self.speakerUuid = speakerUuid; self.style = style
    }
}

/// COEIROINK プラグインの名前空間(マニフェストと生成)。
///
/// 対象範囲(実仕様の確認結果):
/// - **COEIROINK v1 系**: VOICEVOX 互換 API(既定 `http://127.0.0.1:50032`)。
///   GET /speakers・POST /audio_query・POST /synthesis・GET /version をそのまま使う。
///   合成・話者一覧・アクセント句の取得と差し替えはこの経路で対応する(共通実装 `VoicevoxFamilyPluginClient`)。
/// - **COEIROINK v2 系**: 独自 API(同じポート 50032)。話者一覧は GET /v1/speakers
///   (話者は UUID 識別、スタイルは数値 ID)、合成は POST /v1/synthesis への 1 リクエストで完結し、
///   WAV がそのまま返る(VOICEVOX 系の audio_query → synthesis の 2 段階ではない)。
///   合成リクエスト形式は COEIROINK 2.13.0 の /openapi.json と照合した公開実装
///   (coeiro-operator、CoeiroClip、astarot ほか複数)で確定した。詳細は
///   docs/追加TTS-COEIROINK-SHAREVOX.md の「COEIROINK v2 合成(R3-1)」。
///   v2 の合成は `CoeiroinkV2Client` / `CoeiroinkV2Provider` が担当する。
///   アプリの標準配線は R3-2 で v1 / v2 自動判定の `CoeiroinkAutoProvider` へ
///   切り替えた(AppServices が `makeAutoProvider()` を使う)。v2 が応答しない環境では
///   従来の v1 互換プロバイダへ委譲されるため、v1 の合成結果は変わらない。
public enum CoeiroinkPlugin {
    public static let pluginID = "jp.local.moviecut.plugin.coeiroink"
    public static let engineID = "coeiroink"
    public static let displayName = "COEIROINK"
    public static let defaultBaseURL = "http://127.0.0.1:50032"

    public static var spec: VoicevoxFamilyEngineSpec {
        VoicevoxFamilyEngineSpec(engineID: engineID, displayName: displayName, defaultBaseURL: defaultBaseURL, cacheTag: "coeiroink", pluginID: pluginID)
    }

    public static var manifest: PluginManifest {
        PluginManifest(id: pluginID,
                       name: displayName,
                       version: "1.0.0",
                       hooks: [.voice],
                       entryPoint: "CoeiroinkPlugin",
                       minimumAppVersion: nil,
                       voiceEngineIDs: [engineID],
                       requiresLicense: false,
                       description: "COEIROINK(v1 の VOICEVOX 互換 API / v2 の独自 API)で音声合成するプラグイン(組み込み)")
    }

    /// `manifest.json` の中身(PluginDiscovery で読める形)。
    public static func manifestJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(manifest), as: UTF8.self)
    }

    public static func makeClient(baseURL: String? = nil, cache: VoiceCache = .standard, session: URLSession = .shared, policy: VoiceEndpointPolicy = .current) -> VoicevoxFamilyPluginClient {
        VoicevoxFamilyPluginClient(spec: spec, baseURL: baseURL, cache: cache, session: session, policy: policy)
    }

    public static func makeProvider(baseURL: String? = nil, cache: VoiceCache = .standard, session: URLSession = .shared, policy: VoiceEndpointPolicy = .current) -> VoicevoxFamilyPluginProvider {
        VoicevoxFamilyPluginProvider(spec: spec, baseURL: baseURL, cache: cache, session: session, policy: policy)
    }

    /// COEIROINK v2 専用クライアント(話者一覧・エンジン情報・合成)。
    public static func makeV2Client(baseURL: String? = nil, cache: VoiceCache = .standard, session: URLSession = .shared, policy: VoiceEndpointPolicy = .current) -> CoeiroinkV2Client {
        CoeiroinkV2Client(baseURL: baseURL ?? defaultBaseURL, session: session, policy: policy, cache: cache)
    }

    /// COEIROINK v2 専用プロバイダ(キャラの話者はスタイル ID として解決する)。
    public static func makeV2Provider(baseURL: String? = nil, cache: VoiceCache = .standard, session: URLSession = .shared, policy: VoiceEndpointPolicy = .current) -> CoeiroinkV2Provider {
        CoeiroinkV2Provider(baseURL: baseURL, cache: cache, session: session, policy: policy)
    }

    /// v1 / v2 自動判定プロバイダ(GET /v1/engine_info が応答すれば v2、しなければ従来の v1 経路へ委譲)。
    public static func makeAutoProvider(baseURL: String? = nil, cache: VoiceCache = .standard, session: URLSession = .shared, policy: VoiceEndpointPolicy = .current) -> CoeiroinkAutoProvider {
        CoeiroinkAutoProvider(baseURL: baseURL, cache: cache, session: session, policy: policy)
    }
}

/// COEIROINK v2 のクライアント(独自 API)。
///
/// 確定した v2 の手順(出典は docs/追加TTS-COEIROINK-SHAREVOX.md):
/// - GET /v1/speakers: 話者一覧。キー名揺れ(camelCase / snake_case)の両方を受け付けて解釈する。
/// - GET /v1/engine_info: エンジン情報 {version, device}。生存確認にも使う(v2 には /version は無い)。
/// - POST /v1/synthesis: 合成。JSON で
///   speakerUuid / styleId / text / speedScale / volumeScale / pitchScale / intonationScale /
///   prePhonemeLength / postPhonemeLength / outputSamplingRate を送ると WAV が返る。
///   スケール類は全て必須で、既定値はエンジン UI の既定(speed 1 / volume 1 / pitch 0 /
///   intonation 1 / pre 0.1 / post 0.1 / 24000Hz)。prosodyDetail は省略でき、
///   省略時はエンジン側がプロソディを推定する(公開実装はいずれも省略している)。
/// - 間の倍率(pauseLengthScale)に相当する項目は /v1/synthesis には無いため扱わない
///   (休止は /v1/process 側の pauseLength の領分で、1 リクエスト合成の対象外)。
/// - アクセント句(VOICEVOX 形式)の取得・差し替えに相当する API は v2 には無いため扱わない。
public struct CoeiroinkV2Client {
    public var baseURL: String
    public var session: URLSession
    public var policy: VoiceEndpointPolicy
    public var cache: VoiceCache

    public init(baseURL: String = CoeiroinkPlugin.defaultBaseURL, session: URLSession = .shared, policy: VoiceEndpointPolicy = .current, cache: VoiceCache = .standard) {
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.session = session
        self.policy = policy
        self.cache = cache
    }

    /// 間のパラメータと出力サンプルレートの既定値(v2 エンジン UI の既定。v1 系の 0.03 とは異なる)。
    public static let defaultPrePhonemeLength = 0.1
    public static let defaultPostPhonemeLength = 0.1
    public static let defaultOutputSamplingRate = 24000

    /// 送信先の検査(ローカル以外は、設定で許可したホストだけ)。VOICEVOX と同じ方針をそのまま使う。
    public func validatedBaseURL() throws -> URL { try policy.validate(baseURL) }

    private func url(_ path: String) throws -> URL {
        _ = try policy.validate(baseURL)
        guard let u = URL(string: baseURL + path) else { throw VoiceError.message("COEIROINK の URL が正しくありません: \(baseURL)") }
        return u
    }

    private func send(_ req: URLRequest, _ what: String) async throws -> Data {
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw VoiceError.http(what, code) }
        return data
    }

    /// GET /v1/speakers
    public func speakers() async throws -> [CoeiroinkSpeaker] {
        _ = try policy.validate(baseURL)
        guard let u = URL(string: baseURL + "/v1/speakers") else { throw VoiceError.message("COEIROINK の URL が正しくありません: \(baseURL)") }
        let (data, resp) = try await session.data(for: URLRequest(url: u))
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw VoiceError.http("speakers", code) }
        guard let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw VoiceError.badResponse("speakers") }
        return arr.map { s in
            let styles = (s["styles"] as? [[String: Any]] ?? []).compactMap { st -> VoicevoxStyle? in
                guard let id = ((st["styleId"] ?? st["style_id"] ?? st["id"]) as? NSNumber)?.intValue else { return nil }
                return VoicevoxStyle(id: id, name: (st["styleName"] ?? st["style_name"] ?? st["name"]) as? String ?? "")
            }
            return CoeiroinkSpeaker(name: (s["speakerName"] ?? s["speaker_name"] ?? s["name"]) as? String ?? "",
                                    uuid: (s["speakerUuid"] ?? s["speaker_uuid"] ?? s["uuid"]) as? String ?? "",
                                    styles: styles)
        }
    }

    /// GET /v1/engine_info(v2 のエンジン情報と生存確認)。
    public func engineInfo() async throws -> CoeiroinkEngineInfo {
        let data = try await send(URLRequest(url: try url("/v1/engine_info")), "v1/engine_info")
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = obj["version"] as? String else { throw VoiceError.badResponse("v1/engine_info") }
        return CoeiroinkEngineInfo(version: version, device: obj["device"] as? String)
    }

    /// v2 エンジンが生きているか(GET /v1/engine_info が読めるか)。
    public func isAlive() async -> Bool {
        (try? await engineInfo()) != nil
    }

    /// スタイル ID から話者を解決する。v2 のスタイル ID は話者をまたいで一意である前提
    /// (VOICEVOX 系と同じ採番で、公開クライアントもスタイル ID 単独で話者を引いている)。
    /// 見つからない場合と、万一複数話者に一致する場合は、推測で選ばず日本語の理由で止める。
    public func resolveVoice(styleId: Int) async throws -> CoeiroinkV2Voice {
        let matches = try await speakers().flatMap { sp in
            sp.styles.filter { $0.id == styleId }.map { CoeiroinkV2Voice(speakerName: sp.name, speakerUuid: sp.uuid, style: $0) }
        }
        if matches.count == 1 { return matches[0] }
        if matches.isEmpty {
            throw VoiceError.message("COEIROINK v2: スタイル ID \(styleId) を持つ話者が見つかりません。COEIROINK v2 の話者一覧にあるスタイル ID を指定してください。")
        }
        let names = matches.map { "\($0.speakerName)(\($0.speakerUuid))" }.joined(separator: "、")
        throw VoiceError.message("COEIROINK v2: スタイル ID \(styleId) は複数の話者にあります(\(names))。話者 UUID を指定する合成を使ってください。")
    }

    /// POST /v1/synthesis のリクエスト JSON(確定形式そのもの。テストからも検証する)。
    static func synthesisRequestBody(text: String, speakerUuid: String, styleId: Int, speed: Double?, pitch: Double?, intonation: Double?, volume: Double?, prePhonemeLength: Double, postPhonemeLength: Double, outputSamplingRate: Int) -> [String: Any] {
        [
            "speakerUuid": speakerUuid,
            "styleId": styleId,
            "text": text,
            "speedScale": speed ?? 1,
            "volumeScale": volume ?? 1,
            "pitchScale": pitch ?? 0,
            "intonationScale": intonation ?? 1,
            "prePhonemeLength": prePhonemeLength,
            "postPhonemeLength": postPhonemeLength,
            "outputSamplingRate": outputSamplingRate,
        ]
    }

    /// POST /v1/synthesis → WAV をキャッシュへ書く(話者 UUID + スタイル ID 指定)。
    /// キャッシュキーの先頭タグは `coeiroink-v2` で、v1 経路(coeiroink)とは混ざらない。
    public func synthesize(text: String, speakerUuid: String, styleId: Int, speed: Double? = nil, pitch: Double? = nil, intonation: Double? = nil, volume: Double? = nil, prePhonemeLength: Double? = nil, postPhonemeLength: Double? = nil, outputSamplingRate: Int? = nil) async throws -> URL {
        let pre = prePhonemeLength ?? Self.defaultPrePhonemeLength
        let post = postPhonemeLength ?? Self.defaultPostPhonemeLength
        let rate = outputSamplingRate ?? Self.defaultOutputSamplingRate
        let key = VoiceCache.key([.string("coeiroink-v2"), .string(baseURL), .string(speakerUuid), .number(Double(styleId)), .string(text), .opt(speed), .opt(pitch), .opt(intonation), .opt(volume), .number(pre), .number(post), .number(Double(rate))])
        if let hit = cache.hit(forKey: key) { return hit }
        let out = try cache.url(forKey: key)

        var req = URLRequest(url: try url("/v1/synthesis"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: Self.synthesisRequestBody(text: text, speakerUuid: speakerUuid, styleId: styleId, speed: speed, pitch: pitch, intonation: intonation, volume: volume, prePhonemeLength: pre, postPhonemeLength: post, outputSamplingRate: rate))
        let wav = try await send(req, "v1/synthesis")
        guard !wav.isEmpty else { throw VoiceError.badResponse("v1/synthesis") }
        let tmp = out.appendingPathExtension("part-\(UUID().uuidString)")
        try wav.write(to: tmp)
        try VoiceCache.replaceItem(at: out, with: tmp)
        return out
    }

    /// POST /v1/synthesis(スタイル ID のみ指定。話者 UUID は話者一覧から解決する)。
    /// 解決は合成の前に行うので、キャッシュキーには解決後の UUID が入る。
    public func synthesize(text: String, styleId: Int, speed: Double? = nil, pitch: Double? = nil, intonation: Double? = nil, volume: Double? = nil, prePhonemeLength: Double? = nil, postPhonemeLength: Double? = nil, outputSamplingRate: Int? = nil) async throws -> URL {
        let voice = try await resolveVoice(styleId: styleId)
        return try await synthesize(text: text, speakerUuid: voice.speakerUuid, styleId: styleId, speed: speed, pitch: pitch, intonation: intonation, volume: volume, prePhonemeLength: prePhonemeLength, postPhonemeLength: postPhonemeLength, outputSamplingRate: outputSamplingRate)
    }
}

/// COEIROINK v2 の `VoiceProvider`。
/// キャラの話者(数値)は v2 のスタイル ID として扱い、話者 UUID は合成時に話者一覧から解決する。
/// 処理手順は VOICEVOX 系プラグインと同じ(接続確認 → 合成 → 長さ計測)で、自動起動はしない
/// (v1 系と同じ理由。docs 参照)。
public final class CoeiroinkV2Provider: VoiceProvider {
    public let baseURL: String
    public let client: CoeiroinkV2Client
    /// 可用性チェックの差し替え点(テスト用)。nil なら GET /v1/engine_info で確認する。
    var engineAvailabilityOverride: (@Sendable (String) async -> Bool)?

    /// 話者が未設定のキャラに使う既定のスタイル ID(つくよみちゃん「れいせい」= 0。公開実装の既定と同じ)。
    public static let defaultStyleId = 0

    public init(baseURL: String? = nil, cache: VoiceCache = .standard, session: URLSession = .shared, policy: VoiceEndpointPolicy = .current) {
        self.client = CoeiroinkV2Client(baseURL: baseURL ?? CoeiroinkPlugin.defaultBaseURL, session: session, policy: policy, cache: cache)
        self.baseURL = client.baseURL
    }

    public func synthesize(character: Character, text: String, in directory: URL) async throws -> VoiceResult {
        _ = try client.validatedBaseURL()   // 送ってよい先か(だめなら日本語の理由で止める)
        let available: Bool
        if let override = engineAvailabilityOverride {
            available = await override(baseURL)
        } else {
            available = await client.isAlive()
        }
        guard available else {
            throw VoiceError.message("COEIROINK v2 に接続できません。COEIROINK v2 をインストールして起動するか、インスペクタでこのキャラの音声エンジンを切り替えてください(既定の接続先 \(CoeiroinkPlugin.defaultBaseURL))。")
        }
        return try await synthesizeAvailable(character: character, text: text)
    }

    /// 可用性確認を済ませた前提の合成(自動判定プロバイダから使う)。
    /// パラメータ対応: 速さ・高さ・抑揚・間(pre/post)はキャラの値をそのまま v2 のスケールへ渡す。
    /// 音量はキャラに項目が無いため既定 1、間の倍率(pauseLengthScale)は v2 の 1 リクエスト合成に無いため渡さない。
    func synthesizeAvailable(character: Character, text: String) async throws -> VoiceResult {
        let url = try await client.synthesize(text: text, styleId: character.speaker ?? Self.defaultStyleId, speed: character.speed, pitch: character.pitch, intonation: character.intonation, prePhonemeLength: character.prePhonemeLength, postPhonemeLength: character.postPhonemeLength)
        return VoiceResult(url: url, duration: try WavFile.duration(of: url))
    }
}

/// COEIROINK の v1 / v2 自動判定プロバイダ(R3-2 でアプリの標準配線に採用)。
/// GET /v1/engine_info(v2 専用)が応答すれば v2 プロバイダへ、しなければ従来の
/// v1 互換プロバイダ(`VoicevoxFamilyPluginProvider`)へ委譲する。v1 経路の合成手順
/// 自体は一切変えず、委譲先が従来どおり処理する(判定のための参照が 1 回増えるだけ)。
/// エンジン未起動時は判定が失敗して v1 へ委譲され、v1 側が従来どおりの案内文
/// (「COEIROINK に接続できません…」)で止まるため、利用者向けの挙動は変わらない。
/// アクセント句つき合成も v1 経路では従来どおり v1 へ委譲する。v2 にはアクセント句に
/// 相当する API が無いため、v2 経路では通常合成に落とす。
public final class CoeiroinkAutoProvider: VoicevoxAccentProviding {
    public let baseURL: String
    public let v2Provider: CoeiroinkV2Provider
    public let v1Provider: VoicevoxFamilyPluginProvider
    /// v2 判定の差し替え点(テスト用)。nil なら GET /v1/engine_info で判定する。
    var v2ProbeOverride: (@Sendable (String) async -> Bool)?

    public init(baseURL: String? = nil, cache: VoiceCache = .standard, session: URLSession = .shared, policy: VoiceEndpointPolicy = .current) {
        let raw = baseURL ?? CoeiroinkPlugin.defaultBaseURL
        self.baseURL = raw.hasSuffix("/") ? String(raw.dropLast()) : raw
        self.v2Provider = CoeiroinkV2Provider(baseURL: raw, cache: cache, session: session, policy: policy)
        self.v1Provider = VoicevoxFamilyPluginProvider(spec: CoeiroinkPlugin.spec, baseURL: raw, cache: cache, session: session, policy: policy)
    }

    /// v2 判定(差し替え点があればそれを使い、無ければ GET /v1/engine_info で判定する)。
    private func probeIsV2() async -> Bool {
        if let override = v2ProbeOverride { return await override(baseURL) }
        return await v2Provider.client.isAlive()
    }

    public func synthesize(character: Character, text: String, in directory: URL) async throws -> VoiceResult {
        if await probeIsV2() {
            _ = try v2Provider.client.validatedBaseURL()
            return try await v2Provider.synthesizeAvailable(character: character, text: text)
        }
        return try await v1Provider.synthesize(character: character, text: text, in: directory)
    }

    /// アクセント句つき合成。v1 経路では従来どおり v1 プロバイダの差し替え合成へ委譲し、
    /// v2 経路では通常合成に落とす(クラス冒頭の注記参照)。
    public func synthesizeWithAccent(character: Character, text: String, accentPhrases: [VoicevoxAccentPhrase], in directory: URL) async throws -> VoiceResult {
        if await probeIsV2() {
            _ = try v2Provider.client.validatedBaseURL()
            return try await v2Provider.synthesizeAvailable(character: character, text: text)
        }
        return try await v1Provider.synthesizeWithAccent(character: character, text: text, accentPhrases: accentPhrases, in: directory)
    }
}
