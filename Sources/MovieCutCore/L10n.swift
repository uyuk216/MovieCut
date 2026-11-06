import Foundation

// MARK: - 多言語の土台(日本語が原文・英語は対訳表)
//
// 日本語の文字列をそのままキーにして、`L10n.t("ファイル")` と呼ぶ。日本語のときは入力をそのまま返す(挙動は今までと同じ)。
// 英語のときは `L10nTable.pairs` の対訳を返し、無いものは日本語のまま返す(訳が無くても壊れない)。
// 言語の決め方: 設定の上書き(システムに合わせる / 日本語 / English)→ なければシステムの言語(日本語以外は英語)。
// 試験(XCTest)の中や環境変数 MC_LANG=ja|en があるときは、それを優先する(画面の確認を言語に左右されないため)。

public enum AppLanguage: String, CaseIterable, Sendable {
    case system, ja, en

    /// 設定画面に出す名前(自分の言語で書く。切り替え後も読める)。
    public var label: String {
        switch self {
        case .system: return "システムの言語に合わせる / Follow system"
        case .ja: return "日本語"
        case .en: return "English"
        }
    }
}

public enum L10n {
    public static let defaultsKey = "appLanguage"

    /// 画面に出す言語(日本語 / 英語)。
    public enum Lang: String, Sendable { case ja, en }

    /// 優先する言語の並び(`Locale.preferredLanguages`)から、日本語か英語かを決める。先頭が日本語なら日本語、それ以外は英語。空なら日本語。
    public static func systemLanguage(preferred: [String]) -> Lang {
        guard let first = preferred.first else { return .ja }
        return first.lowercased().hasPrefix("ja") ? .ja : .en
    }

    /// 上書きの設定とシステムの言語から決める(純粋な関数)。
    public static func resolve(override: AppLanguage, preferred: [String]) -> Lang {
        switch override {
        case .ja: return .ja
        case .en: return .en
        case .system: return systemLanguage(preferred: preferred)
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: Lang?
    nonisolated(unsafe) private static var forced: Lang?

    /// 保存してある上書き(無ければ system)。
    public static func storedOverride(_ d: UserDefaults = DataLocations.current.defaults) -> AppLanguage {
        d.string(forKey: defaultsKey).flatMap(AppLanguage.init(rawValue:)) ?? .system
    }

    /// 上書きを保存して、すぐ反映する(メニューなど組み直しの要る所は、次に描き直されるときに変わる)。`system` は記録を消す。
    public static func setOverride(_ v: AppLanguage, defaults d: UserDefaults = DataLocations.current.defaults) {
        if v == .system { d.removeObject(forKey: defaultsKey) } else { d.set(v.rawValue, forKey: defaultsKey) }
        reload()
    }

    /// 試験や確認のために言語を固定する(nil で戻す)。
    public static func force(_ l: Lang?) {
        lock.lock(); forced = l; cached = nil; lock.unlock()
    }

    /// 言語を決め直す(設定が変わったとき)。
    public static func reload() {
        lock.lock(); cached = nil; lock.unlock()
    }

    /// いまの言語。
    public static var current: Lang {
        lock.lock(); defer { lock.unlock() }
        if let f = forced { return f }
        if let c = cached { return c }
        let env = ProcessInfo.processInfo.environment["MC_LANG"]
        let v: Lang
        if let env, let l = Lang(rawValue: env) {
            v = l
        } else if NSClassFromString("XCTestCase") != nil, storedOverride() == .system {
            v = .ja   // 試験では、上書きが無ければ日本語(システムの言語で結果が変わらないように)
        } else {
            v = resolve(override: storedOverride(), preferred: Locale.preferredLanguages)
        }
        cached = v
        return v
    }

    /// 翻訳済みの文字列。日本語・訳が無いとき・空のときは、そのまま返す。
    public static func t(_ ja: String) -> String { t(ja, in: current) }

    public static func t(_ ja: String, in lang: Lang) -> String {
        guard lang == .en, !ja.isEmpty else { return ja }
        return L10nTable.english[ja] ?? ja
    }

    /// 翻訳があるか(試験用)。
    public static func hasEnglish(_ ja: String) -> Bool { L10nTable.english[ja] != nil }
}
