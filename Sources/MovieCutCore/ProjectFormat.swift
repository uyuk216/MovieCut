import Foundation

/// プロジェクトファイルの形式の版(`formatVersion`)。
///
/// - 書くとき: 常に `current` 以上を書く(新しい版のファイルを読んだものは、その版を保つ)。
/// - 読むとき: 無ければ 0(従来のファイル)。今までと同じに読む。
/// - `current` より新しい版のファイルも開く。知らないキーは「保持して書き戻す」仕組み(`extra`)で、できる範囲だけ残す。
///   残らない部分があり得るので、利用者に 1 度知らせ、最初の保存の前に元の中身を世代バックアップへ残す。
public enum ProjectFormat {
    /// このアプリが知っている形式の版。
    public static let current = 1
    /// ファイルに書くキー。
    public static let key = "formatVersion"

    /// ファイルの先頭の階層から版だけを読む(全部は読まない)。無い・整数でない・負は 0。
    public static func version(in data: Data) -> Int {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let n = obj[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return 0 }
        let d = n.doubleValue
        guard d.isFinite, d >= 0, d < 1e9 else { return 0 }
        return Int(d)
    }

    public static func isNewer(_ version: Int) -> Bool { version > current }

    /// 新しい版のファイルを開いたときの案内(1 度だけ出す)。
    public static let newerWarning = "このファイルは新しいバージョンの Movie Cut で作られています。保存すると一部の情報が失われることがあります"
    public static let newerWarningDetail = "開く前の中身は、最初に保存するときに「過去の版」へ残します(ファイル ▸ 過去の版から復元…)。"

    /// 新しい版のファイルを上書きして最初に保存する前に、元の中身を世代バックアップへ残し、そのあと保存する中身も世代に残す。
    /// 間隔による置き換えはしない(元の中身を置き換えてしまわないため)。元の中身を残せなかったら throw(= 保存しない方がよい)。
    @discardableResult
    public static func backupOriginalBeforeFirstSave(original: Data, saving: Data, projectURL: URL, locations: DataLocations = .current, keep: Int = ProjectVersions.defaultKeep) throws -> ProjectVersions.Outcome {
        let o = try ProjectVersions.record(data: original, projectURL: projectURL, locations: locations, keep: max(keep, 2), minInterval: 0)
        _ = try? ProjectVersions.record(data: saving, projectURL: projectURL, locations: locations, keep: max(keep, 2), minInterval: 0)
        return o
    }
}

/// 読んだときの形式の版。`Project` の等しさには入れない(版だけが違うプロジェクトは同じ中身として扱う)。
public struct SourceFormatVersion: Equatable, Sendable {
    public var value: Int
    public init(_ v: Int = 0) { value = v }
    public static func == (a: SourceFormatVersion, b: SourceFormatVersion) -> Bool { true }
}
