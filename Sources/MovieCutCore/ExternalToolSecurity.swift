import Foundation

/// 外部の実行ファイル・音声サーバーに関する安全の方針(画面に依存しない純粋な処理)。
///
/// 原則: プロジェクトファイル・素材フォルダの中身は「データ」であって「命令」ではない。
/// そこに書かれたコマンドやパスを実行したり、書かれた URL へ本文を送ったりしない。
/// 実行してよい場所と送ってよい先は、アプリの設定(UserDefaults。プロジェクトには保存しない)と固定の場所だけ。
public enum SecuritySettings {
    static let allowRemoteVoiceKey = "security.allowRemoteVoice"
    static let remoteVoiceHostsKey = "security.remoteVoiceHosts"
    static let aquestalkPathKey = "security.aquestalkPath"

    /// リモートの音声サーバーを許可するか(既定は許可しない)。
    public static func allowRemoteVoice(_ d: UserDefaults = DataLocations.current.defaults) -> Bool {
        d.bool(forKey: allowRemoteVoiceKey)
    }
    public static func setAllowRemoteVoice(_ on: Bool, to d: UserDefaults = DataLocations.current.defaults) {
        if on { d.set(true, forKey: allowRemoteVoiceKey) } else { d.removeObject(forKey: allowRemoteVoiceKey) }
    }

    /// 許可するリモートのホスト名(小文字・重複なし)。
    public static func remoteVoiceHosts(_ d: UserDefaults = DataLocations.current.defaults) -> [String] {
        parseHosts(d.string(forKey: remoteVoiceHostsKey) ?? "")
    }
    public static func setRemoteVoiceHosts(_ text: String, to d: UserDefaults = DataLocations.current.defaults) {
        let hosts = parseHosts(text)
        if hosts.isEmpty { d.removeObject(forKey: remoteVoiceHostsKey) } else { d.set(hosts.joined(separator: ","), forKey: remoteVoiceHostsKey) }
    }
    static func parseHosts(_ text: String) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for part in text.split(whereSeparator: { ",、 \n\t".contains($0) }) {
            let h = part.trimmingCharacters(in: .whitespaces).lowercased()
            if !h.isEmpty, seen.insert(h).inserted { out.append(h) }
        }
        return out
    }

    /// 利用者がファイルパネルで選んだ AquesTalk 実行ファイルの場所(無ければ nil)。
    public static func aquestalkPath(_ d: UserDefaults = DataLocations.current.defaults) -> String? {
        let s = d.string(forKey: aquestalkPathKey) ?? ""
        return s.isEmpty ? nil : s
    }
    public static func setAquestalkPath(_ path: String?, to d: UserDefaults = DataLocations.current.defaults) {
        if let path, !path.isEmpty { d.set(path, forKey: aquestalkPathKey) } else { d.removeObject(forKey: aquestalkPathKey) }
    }
}

// MARK: - 音声サーバーの送信先

public struct VoiceEndpointPolicy: Equatable, Sendable {
    public var allowRemote: Bool
    public var allowedHosts: [String]
    public init(allowRemote: Bool = false, allowedHosts: [String] = []) {
        self.allowRemote = allowRemote
        self.allowedHosts = allowedHosts.map { $0.lowercased() }
    }
    /// アプリの設定から作る(プロジェクトには依存しない)。
    public static var current: VoiceEndpointPolicy {
        VoiceEndpointPolicy(allowRemote: SecuritySettings.allowRemoteVoice(), allowedHosts: SecuritySettings.remoteVoiceHosts())
    }

    public static let localHosts: Set<String> = ["127.0.0.1", "localhost", "::1"]

    public static func isLocalHost(_ host: String) -> Bool {
        var h = host.lowercased()
        if h.hasPrefix("[") && h.hasSuffix("]") { h = String(h.dropFirst().dropLast()) }
        return localHosts.contains(h)
    }

    /// 送ってよい先か確かめる。だめなら日本語の理由つきで投げる。
    @discardableResult
    public func validate(_ urlString: String) throws -> URL {
        let t = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let c = URLComponents(string: t), let scheme = c.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = c.host, !host.isEmpty, let url = c.url else {
            throw VoiceError.message("音声サーバーの URL が正しくありません(http://127.0.0.1:50021 の形で指定してください)。")
        }
        guard c.user == nil, c.password == nil else {
            throw VoiceError.message("音声サーバーの URL にユーザー名やパスワードは含められません。")
        }
        if Self.isLocalHost(host) { return url }
        let h = host.lowercased()
        guard allowRemote else {
            throw VoiceError.message("安全のため、この Mac の外(\(host))にはセリフを送りません。リモートの音声サーバーを使うには、プロジェクト設定の「リモートの音声サーバーを許可」をオンにして、ホスト名を許可してください。")
        }
        guard allowedHosts.contains(h) else {
            throw VoiceError.message("\(host) は許可されたホストではありません。プロジェクト設定の「許可するホスト」に追加してください(プロジェクトファイルに書かれた送信先には、そのままでは送りません)。")
        }
        return url
    }
}

// MARK: - 実行ファイルの検証

public enum ExecutableTrust {
    public enum Rejection: Error, Equatable, Sendable {
        case notAbsolute, traversal, notFound, symlink, notRegular, notExecutable, writableByOthers, wrongOwner, insideProject(String)

        public var message: String {
            switch self {
            case .notAbsolute: return "実行ファイルは絶対パスで指定してください。"
            case .traversal: return "パスに「..」は使えません。"
            case .notFound: return "実行ファイルが見つかりません。"
            case .symlink: return "シンボリックリンクは実行しません。実体のファイルを選んでください。"
            case .notRegular: return "通常のファイルではないので実行しません。"
            case .notExecutable: return "実行できるファイルではありません。"
            case .writableByOthers: return "他の人が書き換えられるファイル(またはフォルダ)なので実行しません。"
            case .wrongOwner: return "所有者があなた(または管理者)ではないので実行しません。"
            case .insideProject(let p): return "プロジェクト・素材のフォルダ内(\(p))にあるファイルは実行しません。"
            }
        }
    }

    /// 実行してよい実行ファイルか検証する。通れば実体のパスを返す。
    /// - `forbiddenRoots`: この下にあるファイルは実行しない(プロジェクトや素材のフォルダ)。
    public static func validate(path: String, forbiddenRoots: [URL] = []) -> Result<URL, Rejection> {
        guard path.hasPrefix("/") else { return .failure(.notAbsolute) }
        let comps = path.split(separator: "/", omittingEmptySubsequences: true)
        if comps.contains("..") { return .failure(.traversal) }
        var st = stat()
        guard lstat(path, &st) == 0 else { return .failure(.notFound) }
        if (st.st_mode & S_IFMT) == S_IFLNK { return .failure(.symlink) }
        guard (st.st_mode & S_IFMT) == S_IFREG else { return .failure(.notRegular) }
        guard access(path, X_OK) == 0 else { return .failure(.notExecutable) }
        guard st.st_mode & 0o022 == 0 else { return .failure(.writableByOthers) }
        guard st.st_uid == 0 || st.st_uid == geteuid() else { return .failure(.wrongOwner) }
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        var pst = stat()
        let parent = real.deletingLastPathComponent().path
        guard stat(parent, &pst) == 0 else { return .failure(.notFound) }
        guard pst.st_mode & 0o022 == 0 else { return .failure(.writableByOthers) }
        guard pst.st_uid == 0 || pst.st_uid == geteuid() else { return .failure(.wrongOwner) }
        for root in forbiddenRoots {
            let r = root.resolvingSymlinksInPath().standardizedFileURL.path
            let base = r.hasSuffix("/") ? r : r + "/"
            if r == "/" { continue }
            if real.path == r || (real.path + "/").hasPrefix(base) { return .failure(.insideProject(r)) }
        }
        return .success(real)
    }
}

/// AquesTalkPlayer の実行ファイルを、決まった場所だけから探す。
public enum AquesTalkLocator {
    public static let executableName = "AquesTalkPlayer"

    /// 候補(優先順): 利用者が設定で選んだもの → アプリ内 → 利用者の Application Support → /Applications → ~/Applications。
    public static func candidates(userSetting: String? = SecuritySettings.aquestalkPath(),
                                  bundleResources: URL? = Bundle.main.resourceURL,
                                  supportRoot: URL = DataLocations.current.root,
                                  home: String = NSHomeDirectory()) -> [String] {
        var list: [String] = []
        if let u = userSetting, !u.isEmpty { list.append(u) }
        if let b = bundleResources { list.append(b.appendingPathComponent("AquesTalk/\(executableName)").path) }
        list.append(supportRoot.appendingPathComponent("AquesTalk/\(executableName)").path)
        list.append("/Applications/AquesTalkPlayer.app/Contents/MacOS/\(executableName)")
        list.append(home + "/Applications/AquesTalkPlayer.app/Contents/MacOS/\(executableName)")
        return list
    }

    /// 検証を通った最初の実行ファイル。無ければ nil。
    public static func resolve(userSetting: String? = SecuritySettings.aquestalkPath(),
                               bundleResources: URL? = Bundle.main.resourceURL,
                               supportRoot: URL = DataLocations.current.root,
                               home: String = NSHomeDirectory(),
                               forbiddenRoots: [URL] = []) -> URL? {
        for p in candidates(userSetting: userSetting, bundleResources: bundleResources, supportRoot: supportRoot, home: home) {
            if case .success(let u) = ExecutableTrust.validate(path: p, forbiddenRoots: forbiddenRoots) { return u }
        }
        return nil
    }
}
