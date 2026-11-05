import Foundation

/// 最近使ったプロジェクト 1 件。パスは標準化した絶対パス。
public struct RecentProject: Codable, Equatable, Hashable, Identifiable {
    public var path: String
    public var name: String
    /// ファイルの最終更新日(分かるときだけ)
    public var modified: Date?
    /// 最後にこのアプリで開いた / 保存した日時
    public var lastOpened: Date?
    public var id: String { path }

    public init(path: String, name: String? = nil, modified: Date? = nil, lastOpened: Date? = nil) {
        let std = RecentProjects.standardize(path)
        self.path = std
        self.name = name ?? RecentProjects.displayName(forPath: std)
        self.modified = modified
        self.lastOpened = lastOpened
    }
}

/// 保存先(UserDefaults 互換の JSON)。テストでは差し替える。
public protocol RecentProjectsStore {
    func loadData() -> Data?
    func saveData(_ data: Data)
}

public final class MemoryRecentProjectsStore: RecentProjectsStore {
    public var data: Data?
    public init(data: Data? = nil) { self.data = data }
    public func loadData() -> Data? { data }
    public func saveData(_ data: Data) { self.data = data }
}

public struct UserDefaultsRecentProjectsStore: RecentProjectsStore {
    public static let key = "recentProjects.v1"
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = DataLocations.current.defaults) { self.defaults = defaults }
    public func loadData() -> Data? { defaults.data(forKey: Self.key) }
    public func saveData(_ data: Data) { defaults.set(data, forKey: Self.key) }
}

/// 最近使ったプロジェクトの一覧(新しい順・最大 20 件)。AppKit に依存しない。
public struct RecentProjects: Equatable {
    public static let limit = 20
    public private(set) var entries: [RecentProject]

    public init(entries: [RecentProject] = []) {
        self.entries = []
        for e in entries { appendIfNew(e) }
        trim()
    }

    // MARK: 変更

    /// 開いた / 保存した。同じパスは 1 件にまとめ、先頭へ。
    public mutating func touch(path: String, modified: Date? = nil, now: Date = Date()) {
        let e = RecentProject(path: path, modified: modified, lastOpened: now)
        entries.removeAll { $0.path == e.path }
        entries.insert(e, at: 0)
        trim()
    }

    public mutating func remove(path: String) {
        let std = Self.standardize(path)
        entries.removeAll { $0.path == std }
    }

    public mutating func removeAll() { entries = [] }

    /// 見つからないものを除く。
    public mutating func removeMissing(fileExists: (String) -> Bool) {
        entries.removeAll { !fileExists($0.path) }
    }

    // MARK: 問い合わせ

    public func isMissing(_ e: RecentProject, fileExists: (String) -> Bool) -> Bool { !fileExists(e.path) }

    public func missingPaths(fileExists: (String) -> Bool) -> Set<String> {
        Set(entries.filter { !fileExists($0.path) }.map(\.path))
    }

    // MARK: 保存

    public static func load(from store: RecentProjectsStore) -> RecentProjects {
        guard let d = store.loadData(), let list = try? JSONDecoder().decode([RecentProject].self, from: d) else { return RecentProjects() }
        return RecentProjects(entries: list)
    }

    public func save(to store: RecentProjectsStore) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        if let d = try? enc.encode(entries) { store.saveData(d) }
    }

    // MARK: 内部

    private mutating func appendIfNew(_ e: RecentProject) {
        let std = RecentProject(path: e.path, name: e.name, modified: e.modified, lastOpened: e.lastOpened)
        if !entries.contains(where: { $0.path == std.path }) { entries.append(std) }
    }

    private mutating func trim() {
        if entries.count > Self.limit { entries = Array(entries.prefix(Self.limit)) }
    }

    public static func standardize(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// 拡張子を除いたファイル名。
    public static func displayName(forPath path: String) -> String {
        URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }
}

/// 起動時の画面の表示設定(既定は表示する)。
public enum WelcomeSettings {
    public static let key = "welcome.showAtLaunch"
    public static func showAtLaunch(_ d: UserDefaults = DataLocations.current.defaults) -> Bool {
        d.object(forKey: key) == nil ? true : d.bool(forKey: key)
    }
    public static func setShowAtLaunch(_ v: Bool, _ d: UserDefaults = DataLocations.current.defaults) { d.set(v, forKey: key) }
}
