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

/// COEIROINK プラグインの名前空間(マニフェストと生成)。
///
/// 対象範囲(実仕様の確認結果):
/// - **COEIROINK v1 系**: VOICEVOX 互換 API(既定 `http://127.0.0.1:50032`)。
///   GET /speakers・POST /audio_query・POST /synthesis・GET /version をそのまま使う。
///   合成・話者一覧・アクセント句の取得と差し替えはこの経路で対応する(共通実装 `VoicevoxFamilyPluginClient`)。
/// - **COEIROINK v2 系**: 独自 API に変わっており VOICEVOX 互換ではない(同じポート 50032 で
///   GET /v1/speakers が話者一覧)。本プラグインでは v2 の話者一覧の読み取りだけを
///   `CoeiroinkV2Client` で対応し、**v2 の合成は未対応**(理由と確認手順は
///   docs/追加TTS-COEIROINK-SHAREVOX.md)。推測で合成リクエストを組み立てることはしない。
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
                       description: "COEIROINK(v1 の VOICEVOX 互換 API)で音声合成するプラグイン(組み込み)")
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
}

/// COEIROINK v2 の読み取り専用クライアント(GET /v1/speakers のみ)。
///
/// v2 の /v1/speakers は、キー名揺れ(camelCase / snake_case)の両方を受け付けて解釈する。
/// 合成(v2 は推論手順が v1 と異なり、公開資料だけではリクエスト形式を確定できない)は扱わない。
public struct CoeiroinkV2Client {
    public var baseURL: String
    public var session: URLSession
    public var policy: VoiceEndpointPolicy

    public init(baseURL: String = CoeiroinkPlugin.defaultBaseURL, session: URLSession = .shared, policy: VoiceEndpointPolicy = .current) {
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.session = session
        self.policy = policy
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
}
