import Foundation

/// SHAREVOX プラグインの名前空間(マニフェストと生成)。
///
/// SHAREVOX は VOICEVOX のフォークで、VOICEVOX 互換のローカル HTTP API を
/// 既定 `http://127.0.0.1:50025` で提供する(GET /speakers、POST /audio_query、
/// POST /synthesis、GET /version)。合成手順は共通実装 `VoicevoxFamilyPluginClient` を使い、
/// ここでは識別子・既定 URL・マニフェストだけを持つ。
/// エンジンの自動起動はしない(単体アプリをユーザーが起動する前提。理由は
/// `VoicevoxFamilyAvailability` の注記参照)。
public enum SharevoxPlugin {
    public static let pluginID = "jp.local.moviecut.plugin.sharevox"
    public static let engineID = "sharevox"
    public static let displayName = "SHAREVOX"
    public static let defaultBaseURL = "http://127.0.0.1:50025"

    public static var spec: VoicevoxFamilyEngineSpec {
        VoicevoxFamilyEngineSpec(engineID: engineID, displayName: displayName, defaultBaseURL: defaultBaseURL, cacheTag: "sharevox", pluginID: pluginID)
    }

    public static var manifest: PluginManifest {
        PluginManifest(id: pluginID,
                       name: displayName,
                       version: "1.0.0",
                       hooks: [.voice],
                       entryPoint: "SharevoxPlugin",
                       minimumAppVersion: nil,
                       voiceEngineIDs: [engineID],
                       requiresLicense: false,
                       description: "SHAREVOX エンジンで音声合成するプラグイン(組み込み)")
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
