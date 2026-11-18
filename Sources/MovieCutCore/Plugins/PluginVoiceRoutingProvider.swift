import Foundation

/// キャラの engine に担当プラグインがあればそちらで、無ければ(または解決に失敗したら)内蔵プロバイダで合成する。
public final class PluginVoiceRoutingProvider: VoiceProvider {
    public let host: PluginHost
    public let fallbackProvider: any VoiceProvider

    public init(host: PluginHost, fallback: any VoiceProvider) {
        self.host = host
        self.fallbackProvider = fallback
    }

    public func synthesize(character: Character, text: String, in directory: URL) async throws -> VoiceResult {
        // 方針: 解決時(登録なし / 読み込み失敗 / ライセンス拒否など)のエラーはすべて握りつぶして内蔵経路に落とす。
        // 壊れたプラグインで制作が止まらないようにするため。
        // `try?` は throws な Optional 返しを平坦化する(Swift 5 以降)ので、nil は「未登録 or 失敗」を表す。
        let resolved: (any VoiceProvider)? = try? host.voiceProviderIfAvailable(forEngine: character.engine)
        if let provider = resolved {
            return try await provider.synthesize(character: character, text: text, in: directory)
        }
        return try await fallbackProvider.synthesize(character: character, text: text, in: directory)
    }
}
