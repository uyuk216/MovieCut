import Foundation

/// 自動保存と異常終了からの復元(画面にも依存しない純粋な処理)。
///
/// 編集中の書類の写しを、利用者のファイルとは別の「復元フォルダ」に定期的に書く(利用者のファイルは書き換えない)。
/// 正常に保存・閉じたら写しを消す。異常終了で残った写しは、次の起動で「復元」できる。
public enum AutosaveRecovery {
    /// 写しの拡張子(中身は JSON。`Entry` を入れる)。
    public static let fileExtension = "mcrecover"
    /// 写しを置くフォルダ名(Application Support の下)。
    public static let folderName = "Recovery"
    /// 自動保存の間隔(秒)。
    public static let interval: TimeInterval = 30

    /// 写しの中身。`project` は `Project.encoded()` の結果(そのままの JSON)。
    public struct Entry: Codable, Equatable {
        public var name: String
        public var originalPath: String?
        public var savedAt: Date
        public var project: Data

        public init(name: String, originalPath: String?, savedAt: Date, project: Data) {
            self.name = name; self.originalPath = originalPath; self.savedAt = savedAt; self.project = project
        }
    }

    /// 書類 1 つ(1 回の起動の中)に決まる写しのファイル名。
    public static func fileName(sessionID: String) -> String {
        "\(sessionID).\(fileExtension)"
    }

    public static func isRecoveryFileName(_ name: String) -> Bool {
        name.hasSuffix("." + fileExtension) && name.count > fileExtension.count + 1
    }

    /// 写しとして読み書きしてよい名前: 英数とハイフンだけ(1〜64 文字)+ 拡張子。「/」「..」や隠しファイルは通さない。
    public static func isSafeFileName(_ name: String) -> Bool {
        guard name.hasSuffix("." + fileExtension) else { return false }
        let stem = name.dropLast(fileExtension.count + 1)
        guard (1...64).contains(stem.count) else { return false }
        return stem.unicodeScalars.allSatisfy { ($0.value >= 48 && $0.value <= 57) || ($0.value >= 65 && $0.value <= 90) || ($0.value >= 97 && $0.value <= 122) || $0 == "-" }
    }

    /// 復元フォルダの中の、このセッションの写しの場所。名前が安全でなければ nil。
    public static func safeURL(sessionID: String, in dir: URL) -> URL? {
        let name = fileName(sessionID: sessionID)
        guard isSafeFileName(name) else { return nil }
        return dir.appendingPathComponent(name)
    }

    /// 写しの上限(バイト)。
    public static let maxFileBytes = InputLimits.maxRecoveryBytes

    /// 写しを書く。復元フォルダの外・危険な名前・シンボリックリンクの上書き・大きすぎる中身は断る(書けたら true)。
    @discardableResult
    public static func write(_ entry: Entry, sessionID: String, in dir: URL) -> Bool {
        guard let url = safeURL(sessionID: sessionID, in: dir), let data = try? encode(entry), data.count <= maxFileBytes else { return false }
        var st = stat()
        if lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) != S_IFREG { return false }   // リンクなどには書かない
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    /// 写しを読む: 通常のファイルだけ(リンク・特殊ファイル・大きすぎるもの・名前が危険なもの・壊れたものは読まない)。
    public static func load(_ url: URL) -> Entry? {
        guard isSafeFileName(url.lastPathComponent),
              let data = try? InputLimits.readFile(url, limit: maxFileBytes, what: "復元ファイル", allowSymlink: false),
              InputLimits.jsonDepthWithinLimit(data),
              let e = try? decode(data), e.project.count <= InputLimits.maxProjectBytes,
              (try? Project.decode(from: e.project)) != nil else { return nil }
        return e
    }

    /// 復元フォルダの写しの一覧(古い順)。読めないもの(壊れ・巨大・リンクなど)は一覧に出さず、通常のファイルだけ消す。
    public static func list(in dir: URL) -> [(url: URL, entry: Entry)] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { isRecoveryFileName($0.lastPathComponent) }.compactMap { url in
            if let e = load(url) { return (url, e) }
            var st = stat()
            if lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG { try? fm.removeItem(at: url) }
            return nil
        }.sorted { $0.entry.savedAt < $1.entry.savedAt }
    }

    /// 写しを書くべきか: 編集済みで、前に書いた版から変わっているときだけ。
    public static func shouldWrite(edited: Bool, revision: Int, lastWritten: Int?) -> Bool {
        edited && revision != lastWritten
    }

    /// 写しを消すべきか: 保存済み(編集済みでない)のとき。
    public static func shouldRemove(edited: Bool) -> Bool { !edited }

    public static func encode(_ e: Entry) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        enc.dateEncodingStrategy = .secondsSince1970
        return try enc.encode(e)
    }

    public static func decode(_ data: Data) throws -> Entry {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        return try dec.decode(Entry.self, from: data)
    }

    /// 一覧に出す題: 「名前(元: ファイル名 / 無題)・保存時刻」。
    public static func title(_ e: Entry) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M月d日 H:mm"
        let origin = e.originalPath.map { String(($0 as NSString).lastPathComponent.prefix(120)) } ?? "無題"
        return "\(origin)(\(f.string(from: e.savedAt)) に自動保存)"
    }
}
