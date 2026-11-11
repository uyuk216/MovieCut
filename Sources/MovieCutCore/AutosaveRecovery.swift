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
              let e = try? decode(data), e.project.count <= InputLimits.maxProjectBytes,
              InputLimits.jsonDepthWithinLimit(e.project),
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

    /// 自動保存の失敗の数え方(画面に依存しない)。続けて `threshold` 回失敗したら 1 度だけ知らせ、成功したら知らせを消す。
    public struct FailureTracker: Equatable, Sendable {
        public static let threshold = 2
        public static let message = "自動保存の写しを書けません(ディスクの空きなどを確認してください)。編集は続けられますが、いまの内容は復元用に残っていません"
        public private(set) var consecutiveFailures = 0
        public private(set) var warningShown = false
        public init() {}

        public enum Event: Equatable, Sendable { case none, showWarning, clearWarning }

        /// 1 回の書き込みの結果を記録し、画面に出すべきことを返す(知らせは続けて失敗しても 1 度だけ)。
        public mutating func record(success: Bool) -> Event {
            if success {
                consecutiveFailures = 0
                if warningShown { warningShown = false; return .clearWarning }
                return .none
            }
            consecutiveFailures += 1
            if consecutiveFailures >= Self.threshold, !warningShown { warningShown = true; return .showWarning }
            return .none
        }
    }

    /// 写しを消すべきか: 保存済み(編集済みでない)のとき。
    public static func shouldRemove(edited: Bool) -> Bool { !edited }

    /// 写しの形式。
    /// - 新(v2): 1 行目に小さな JSON の見出し(`{"format":"mcrecover2","name":…,"originalPath":…,"savedAt":…}`)、改行、そのあとにプロジェクトの JSON をそのまま。
    ///   プロジェクトを base64 にして JSON に包み直さない(書く量が約 3 割減り、二重の符号化もない)。
    /// - 旧(v1): 全体が 1 つの JSON(`Entry` そのもの。`project` は base64)。読むことだけ続ける(前の版が書いた写しを復元できる)。
    /// 旧い版のアプリは v2 を読めない(= 一覧に出ない)。同じ PC で版を戻す場合だけの影響で、元のファイルは書き換えない。
    public static let formatTag = "mcrecover2"

    struct Header: Codable { var format: String; var name: String; var originalPath: String?; var savedAt: Date }

    private static func jsonEncoder() -> JSONEncoder {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        enc.dateEncodingStrategy = .secondsSince1970
        return enc
    }

    /// 書く形式(v2)。
    public static func encode(_ e: Entry) throws -> Data {
        var out = try jsonEncoder().encode(Header(format: formatTag, name: e.name, originalPath: e.originalPath, savedAt: e.savedAt))
        out.append(0x0A)
        out.append(e.project)
        return out
    }

    /// 旧形式(v1)で書く(互換の確認用。アプリは使わない)。
    public static func encodeLegacy(_ e: Entry) throws -> Data { try jsonEncoder().encode(e) }

    /// v2 と v1 のどちらも読む。
    public static func decode(_ data: Data) throws -> Entry {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        if let nl = data.firstIndex(of: 0x0A), nl < 64 * 1024,
           let h = try? dec.decode(Header.self, from: data[data.startIndex..<nl]), h.format == formatTag {
            return Entry(name: h.name, originalPath: h.originalPath, savedAt: h.savedAt, project: Data(data[data.index(after: nl)...]))
        }
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
