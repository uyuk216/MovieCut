import Foundation
@testable import MovieCutCore

/// テスト用サンプルプラグインの音声プロバイダ。
/// 実体はコアの検証用 `ToneVoiceProvider` をラップし、engine 識別子だけを変えた最小実装。
/// (実プラグインではここが VOICEVOX / AquesTalk 接続になる想定。境界メモ参照)
final class SampleToneVoiceProvider: VoiceProvider {
    /// ラップ先。短いトーンにしてテストを速くする。
    private let inner = ToneVoiceProvider(durations: [0.25], frequencies: [440])
    private(set) var synthesizedTexts: [String] = []

    func synthesize(character: Character, text: String, in directory: URL) async throws -> VoiceResult {
        synthesizedTexts.append(text)
        return try await inner.synthesize(character: character, text: text, in: directory)
    }
}

/// テスト用サンプルプラグイン(マニフェスト + ローダ)。
/// Discovery → ライセンス検証 → 遅延ロード → VoiceProvider 解決 → WAV 生成、を通すための最小構成。
enum SampleTonePlugin {
    static let pluginID = "jp.local.moviecut.plugin.sample-tone"
    static let engineID = "sample-tone"
    static let entryPoint = "SampleTonePluginEntry"
    /// テストで使う発行済みライセンスコードとデバイス。
    static let licenseCode = "SAMPLE-TONE-1234-5678"
    static let deviceID = "test-device-001"

    static var manifest: PluginManifest {
        PluginManifest(id: pluginID,
                       name: "サンプルトーン音声",
                       version: "1.0.0",
                       hooks: [.voice],
                       entryPoint: entryPoint,
                       minimumAppVersion: "1.0.0",
                       voiceEngineIDs: [engineID],
                       requiresLicense: true,
                       description: "テスト用の最小音声プラグイン")
    }

    /// プラグインフォルダに置く `manifest.json` の中身。
    static func manifestJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(manifest), as: UTF8.self)
    }

    /// 一時ディレクトリにプラグインフォルダ(manifest.json のみ)を作り、親ディレクトリを返す。
    /// 本体ファイルは置かない(Discovery がマニフェストしか読まないことの確認も兼ねる)。
    @discardableResult
    static func install(into root: URL, fileManager: FileManager = .default) throws -> URL {
        let folder = root.appendingPathComponent("SampleTonePlugin", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        try manifestJSON().write(to: folder.appendingPathComponent(PluginDiscovery.manifestFileName),
                                 atomically: true, encoding: .utf8)
        return folder
    }
}

/// サンプルプラグインのローダ。実体化回数を数えられるようにして、遅延読み込みの検証に使う。
final class SampleTonePluginLoader: PluginLoader {
    private(set) var loadCount = 0
    private(set) var loadedEntryPoints: [String] = []
    /// 直近に作ったプロバイダ(テストから合成履歴を見るため)。
    private(set) var lastProvider: SampleToneVoiceProvider?

    func loadPlugin(manifest: PluginManifest, directory: URL) throws -> LoadedPlugin {
        loadCount += 1
        loadedEntryPoints.append(manifest.entryPoint)
        guard manifest.id == SampleTonePlugin.pluginID else {
            throw PluginError.notRegistered(pluginID: manifest.id)
        }
        let provider = SampleToneVoiceProvider()
        lastProvider = provider
        return LoadedPlugin(manifest: manifest, directory: directory, voiceProvider: provider)
    }
}
