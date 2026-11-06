import Foundation

/// アプリの「版」。作者本人の環境(personal)と、配布用(public)でデータの置き場を完全に分ける。
/// Info.plist の `MovieCutEdition` で決まる。キーが無い・読めない値のときは personal(今のビルドと既存データはそのまま)。
public enum AppEdition: String, CaseIterable, Sendable {
    case personal
    case `public`

    public static let infoPlistKey = "MovieCutEdition"

    /// Info.plist の辞書から版を決める。無い・不明なら personal。
    public static func resolve(infoDictionary: [String: Any]?) -> AppEdition {
        guard let raw = infoDictionary?[infoPlistKey] as? String,
              let e = AppEdition(rawValue: raw.trimmingCharacters(in: .whitespaces).lowercased()) else { return .personal }
        return e
    }

    /// 今動いているアプリの版(起動中に変わらない)。
    public static let current: AppEdition = resolve(infoDictionary: Bundle.main.infoDictionary)

    /// 版ごとのバンドル ID。personal は今までと同じ。
    public var bundleIdentifier: String {
        switch self {
        case .personal: return "jp.local.moviecut"
        case .public: return "jp.local.moviecut.public"
        }
    }
}

/// 版ごとの保存場所と設定の置き場。個人の環境(PSD・立ち絵・キャラクター・フォント・最近使ったプロジェクト・
/// 各種キャッシュ・自動保存の復元)が配布版に混ざらないよう、保存先は必ずここを通す。
/// personal は従来どおりの場所(`Application Support/MovieCut/...`、`UserDefaults.standard`)。
public struct DataLocations: Sendable {
    public let edition: AppEdition
    /// Application Support の場所(試験では差し替える)。
    public let applicationSupport: URL

    public init(edition: AppEdition, applicationSupport: URL? = nil) {
        self.edition = edition
        self.applicationSupport = applicationSupport ?? Self.systemApplicationSupport
    }

    /// 今動いているアプリの版の保存場所。
    public static var current: DataLocations { DataLocations(edition: AppEdition.current) }

    static var systemApplicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support", isDirectory: true)
    }

    /// Application Support の下のフォルダ名。personal は今までの "MovieCut"、public は別名。
    public var supportFolderName: String {
        switch edition {
        case .personal: return "MovieCut"
        case .public: return "Movie Cut (Public)"
        }
    }

    public var root: URL { applicationSupport.appendingPathComponent(supportFolderName, isDirectory: true) }
    public var fonts: URL { root.appendingPathComponent("Fonts", isDirectory: true) }
    public var proxies: URL { root.appendingPathComponent("Proxies", isDirectory: true) }
    public var voices: URL { root.appendingPathComponent("voices", isDirectory: true) }
    public var templates: URL { root.appendingPathComponent("Templates", isDirectory: true) }
    public var exportPresets: URL { root.appendingPathComponent("export-presets.json") }
    public var recovery: URL { root.appendingPathComponent("Recovery", isDirectory: true) }
    public var qrCodes: URL { root.appendingPathComponent("QRCodes", isDirectory: true) }
    public var aiImages: URL { root.appendingPathComponent("AIImages", isDirectory: true) }
    public var psdCache: URL { root.appendingPathComponent("PSDCache", isDirectory: true) }
    public var cutouts: URL { root.appendingPathComponent("Cutouts", isDirectory: true) }
    /// 世代バックアップ(保存のたびの写し)。プロジェクトごとのフォルダがこの下に作られる。
    public var versions: URL { root.appendingPathComponent("Versions", isDirectory: true) }
    /// 同梱素材ライブラリ(アプリが合成・描画した効果音・背景・図形のキャッシュ)。
    public var builtinMedia: URL { root.appendingPathComponent("Bundled", isDirectory: true) }

    /// 版が持つフォルダ・ファイルの全部(重なり検査・説明用)。
    public var allPaths: [URL] {
        [fonts, proxies, voices, templates, exportPresets, recovery, qrCodes, aiImages, psdCache, cutouts, versions, builtinMedia]
    }

    /// 設定(UserDefaults)の置き場。personal は従来の `.standard`。
    /// public は別のバンドル ID(= 別の設定ドメイン)で動くので `.standard` がそのまま別物。
    /// 版のバンドル ID と違うプロセス(CLI・試験)から見るときだけ、専用のスイートを使う。
    public var defaults: UserDefaults {
        switch edition {
        case .personal: return .standard
        case .public:
            if Bundle.main.bundleIdentifier == edition.bundleIdentifier { return .standard }
            return UserDefaults(suiteName: edition.bundleIdentifier) ?? .standard
        }
    }

    /// 設定ドメインの名前(personal は従来のバンドル ID のドメイン)。
    public var defaultsDomain: String { edition.bundleIdentifier }
}
