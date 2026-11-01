import Foundation

/// プロジェクトのテンプレート(画面を持たない純粋なロジック)。
/// テンプレートは `.mcpjc` と同じ JSON で、クリップだけを外したもの。
/// キャラクター・レイヤー(トラック)・設定・マーカーを残す。文字スタイルはアプリ全体の設定(UserDefaults)なので中身には入らない。
public enum ProjectTemplate {
    /// 保存に使う拡張子(プロジェクトと同じ形式)。
    public static let fileExtension = "mcpjc"
    /// Application Support/MovieCut の下のフォルダ名。
    public static let folderName = "Templates"
    /// 名前の最大の長さ(文字数)。
    public static let maxNameLength = 60

    /// テンプレートの中身を作る: クリップは全部外し、それ以外はそのまま残す。
    public static func make(from project: Project) -> Project {
        var p = project
        p.tracks = p.tracks.map { track in
            var t = track
            t.clips = []
            return t
        }
        return p
    }

    /// 名前をファイル名に使える形に整える。区切り文字と制御文字は空白に、前後の空白と先頭のドットは取る。空なら nil。
    public static func sanitizedName(_ raw: String) -> String? {
        let bad = CharacterSet(charactersIn: "/:\\\0").union(.controlCharacters)
        var s = raw.components(separatedBy: bad).joined(separator: " ")
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix(".") { s.removeFirst() }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.count > maxNameLength { s = String(s.prefix(maxNameLength)) }
        return s
    }

    /// 既存の名前と重ならない名前を返す。空いていれば base のまま、ふさがっていれば「base 2」「base 3」…。
    public static func uniqueName(base: String, existing: [String]) -> String {
        let taken = Set(existing)
        guard taken.contains(base) else { return base }
        var n = 2
        while taken.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    /// フォルダのファイル名から、テンプレートの名前の一覧を作る(拡張子が mcpjc のものだけ・名前順)。
    public static func names(fromFileNames files: [String]) -> [String] {
        files.compactMap { file -> String? in
            guard (file as NSString).pathExtension == fileExtension else { return nil }
            let name = (file as NSString).deletingPathExtension
            return name.isEmpty || name.hasPrefix(".") ? nil : name
        }
        .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

/// テンプレートの保存先(フォルダ)を読み書きする。保存・読み込みのファイル操作だけを持つ。
public struct TemplateStore {
    public enum StoreError: Error, Equatable {
        case invalidName
        case notFound(String)
    }

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// 既定の保存先 `~/Library/Application Support/MovieCut/Templates`(無ければ作る)。
    public static func standard() -> TemplateStore? {
        guard let base = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else { return nil }
        let dir = base.appendingPathComponent("MovieCut", isDirectory: true)
            .appendingPathComponent(ProjectTemplate.folderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return TemplateStore(directory: dir)
    }

    /// 保存されているテンプレートの名前(名前順)。
    public func names() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return ProjectTemplate.names(fromFileNames: files)
    }

    public func url(for name: String) -> URL {
        directory.appendingPathComponent(name).appendingPathExtension(ProjectTemplate.fileExtension)
    }

    /// プロジェクトからテンプレートを作って保存する。同じ名前があれば「名前 2」のように避ける。保存した名前を返す。
    @discardableResult
    public func save(_ project: Project, as rawName: String) throws -> String {
        guard let base = ProjectTemplate.sanitizedName(rawName) else { throw StoreError.invalidName }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = ProjectTemplate.uniqueName(base: base, existing: names())
        try ProjectTemplate.make(from: project).save(to: url(for: name))
        return name
    }

    /// 名前のテンプレートを読む。
    public func load(name: String) throws -> Project {
        let u = url(for: name)
        guard FileManager.default.fileExists(atPath: u.path) else { throw StoreError.notFound(name) }
        return try Project.load(from: u)
    }
}
