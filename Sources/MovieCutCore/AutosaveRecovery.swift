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
        let origin = e.originalPath.map { ($0 as NSString).lastPathComponent } ?? "無題"
        return "\(origin)(\(f.string(from: e.savedAt)) に自動保存)"
    }
}
