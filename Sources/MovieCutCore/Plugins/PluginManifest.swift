import Foundation

/// プラグインが提供するフックの種別。プラグインはこのうち 1 つ以上を提供する。
public enum PluginHook: String, Codable, CaseIterable, Sendable {
    /// 音声合成(`VoiceProvider` の提供)。
    case voice
    /// 素材・プロジェクト形式の取り込み。
    case importer
    /// 映像・音声エフェクト。
    case effect
    /// 音声エフェクト(ブロック単位のオフライン処理。境界は `PluginAudioEffect.swift`)。
    case audioEffect
    /// 書き出し形式。
    case exporter
}

/// プラグインのマニフェスト(`manifest.json`)。
///
/// 起動時に読むのはこのマニフェストだけで、プラグイン本体(コード)は読み込まない。
/// 本体の実体化は `PluginHost` が初回使用時に遅延して行う(遅延読み込み)。
/// フォルダ構成の前提: `<プラグインフォルダ>/manifest.json` + 本体ファイル群。
public struct PluginManifest: Codable, Equatable, Sendable {
    /// プラグインの一意な識別子(例: "jp.local.moviecut.plugin.sample-tone")。
    public var id: String
    /// 表示名。
    public var name: String
    /// プラグイン自身のバージョン("1.2.0" 形式)。
    public var version: String
    /// 提供するフック種別。
    public var hooks: [PluginHook]
    /// エントリポイント名。ローダが本体を引くときのキー(将来の動的読み込みではシンボル名/バンドル名になる)。
    public var entryPoint: String
    /// このプラグインが動く最小のアプリバージョン("1.0.0" 形式)。未指定なら制限なし。
    public var minimumAppVersion: String?
    /// 音声フック(`hooks` に `.voice` を含むとき)が担当する、キャラの `engine` 識別子の一覧。
    /// 例: ["voicevox"] / ["aquestalk"] / ["sample-tone"]。`PluginHost.voiceProvider(forEngine:)` の解決キー。
    public var voiceEngineIDs: [String]
    /// エフェクトフック(`hooks` に `.effect` を含むとき)が担当する、エフェクト識別子の一覧。
    /// 識別子は `Effect.kind`(文字列)そのもので、内蔵の `EffectKind.rawValue` と衝突しないよう
    /// 接頭辞付きにする(例: "plugin.invert")。`PluginHost.effectProvider(forEffectID:)` の解決キー。
    public var effectIDs: [String]
    /// 音声エフェクトフック(`hooks` に `.audioEffect` を含むとき)が担当する、音声エフェクト識別子の一覧。
    /// VST3 は "vst3.<バンドルID>" の形(`VST3BundleInfo.audioEffectID`)。`PluginHost.audioEffectProvider(forAudioEffectID:)` の解決キー。
    public var audioEffectIDs: [String]
    /// 書き出しフック(`hooks` に `.exporter` を含むとき)が担当する、書き出し形式識別子の一覧。
    /// 例: ["gif"] / ["project-json"]。`PluginHost.exportBackend(forFormat:)` の解決キー。
    public var exportFormatIDs: [String]
    /// ライセンス検証が必要なプラグインかどうか。有料プラグインは true にする想定。
    public var requiresLicense: Bool
    /// 人間向けの短い説明(任意)。
    public var description: String?

    public init(id: String,
                name: String,
                version: String,
                hooks: [PluginHook],
                entryPoint: String,
                minimumAppVersion: String? = nil,
                voiceEngineIDs: [String] = [],
                effectIDs: [String] = [],
                exportFormatIDs: [String] = [],
                audioEffectIDs: [String] = [],
                requiresLicense: Bool = false,
                description: String? = nil) {
        self.id = id
        self.name = name
        self.version = version
        self.hooks = hooks
        self.entryPoint = entryPoint
        self.minimumAppVersion = minimumAppVersion
        self.voiceEngineIDs = voiceEngineIDs
        self.effectIDs = effectIDs
        self.exportFormatIDs = exportFormatIDs
        self.audioEffectIDs = audioEffectIDs
        self.requiresLicense = requiresLicense
        self.description = description
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, version, hooks, entryPoint, minimumAppVersion, voiceEngineIDs, effectIDs, exportFormatIDs, audioEffectIDs, requiresLicense, description
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        version = try c.decode(String.self, forKey: .version)
        hooks = try c.decode([PluginHook].self, forKey: .hooks)
        entryPoint = try c.decode(String.self, forKey: .entryPoint)
        minimumAppVersion = try c.decodeIfPresent(String.self, forKey: .minimumAppVersion)
        voiceEngineIDs = try c.decodeIfPresent([String].self, forKey: .voiceEngineIDs) ?? []
        effectIDs = try c.decodeIfPresent([String].self, forKey: .effectIDs) ?? []
        exportFormatIDs = try c.decodeIfPresent([String].self, forKey: .exportFormatIDs) ?? []
        audioEffectIDs = try c.decodeIfPresent([String].self, forKey: .audioEffectIDs) ?? []
        requiresLicense = try c.decodeIfPresent(Bool.self, forKey: .requiresLicense) ?? false
        description = try c.decodeIfPresent(String.self, forKey: .description)
    }

    /// 指定のフックを提供するか。
    public func provides(_ hook: PluginHook) -> Bool { hooks.contains(hook) }

    /// 指定の engine 識別子の音声合成を担当するか(大文字小文字は区別しない)。
    public func handlesVoiceEngine(_ engineID: String) -> Bool {
        guard provides(.voice) else { return false }
        let needle = engineID.trimmingCharacters(in: .whitespaces).lowercased()
        return voiceEngineIDs.contains { $0.trimmingCharacters(in: .whitespaces).lowercased() == needle }
    }

    /// 指定のエフェクト識別子(`Effect.kind`)を担当するか(大文字小文字は区別しない)。
    public func handlesEffect(_ effectID: String) -> Bool {
        guard provides(.effect) else { return false }
        let needle = effectID.trimmingCharacters(in: .whitespaces).lowercased()
        return effectIDs.contains { $0.trimmingCharacters(in: .whitespaces).lowercased() == needle }
    }

    /// 指定の音声エフェクト識別子を担当するか(大文字小文字は区別しない)。
    public func handlesAudioEffect(_ effectID: String) -> Bool {
        guard provides(.audioEffect) else { return false }
        let needle = effectID.trimmingCharacters(in: .whitespaces).lowercased()
        return audioEffectIDs.contains { $0.trimmingCharacters(in: .whitespaces).lowercased() == needle }
    }

    /// 指定の書き出し形式識別子を担当するか(大文字小文字は区別しない)。
    public func handlesExportFormat(_ formatID: String) -> Bool {
        guard provides(.exporter) else { return false }
        let needle = formatID.trimmingCharacters(in: .whitespaces).lowercased()
        return exportFormatIDs.contains { $0.trimmingCharacters(in: .whitespaces).lowercased() == needle }
    }

    /// アプリバージョンとの互換性。`minimumAppVersion` 未指定なら常に互換あり。
    /// バージョン比較は数値部品ごとの単純なセマンティックバージョン比較("1.10.0" > "1.9.0")。
    public func isCompatible(withAppVersion appVersion: String) -> Bool {
        guard let minimumAppVersion, !minimumAppVersion.isEmpty else { return true }
        return PluginManifest.compareVersion(appVersion, minimumAppVersion) != .orderedAscending
    }

    /// "1.2.3" 形式同士の比較。数値でない部品は 0 として扱い、足りない部品は 0 で埋める。
    public static func compareVersion(_ a: String, _ b: String) -> ComparisonResult {
        let pa = versionParts(a), pb = versionParts(b)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    private static func versionParts(_ s: String) -> [Int] {
        // "1.2.0-beta" のような接尾辞は数値比較の対象外として落とす。
        s.split(separator: "-").first.map { head in
            head.split(separator: ".").map { Int($0) ?? 0 }
        } ?? []
    }
}
