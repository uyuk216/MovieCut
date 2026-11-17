import Foundation

/// プロジェクトファイルの拡張子を管理する場所。
///
/// 拡張子の変更が決まったら、ここの `current` だけを差し替える(ファイルの中身の形式は変えない)。
/// 読み込み側は移行互換のため、旧形式の `ymproj` も当面受け付ける。
public enum ProjectFileExtension {
    /// 保存(書き出し)に使う現在の拡張子(ドットなし)。
    public static let current = "mcpjc"

    /// 読み込みで受け付ける拡張子(ドットなし・小文字)。移行互換の旧 `ymproj` を含む。
    public static let readable: [String] = [current, "ymproj"]

    /// その URL が読み込み可能なプロジェクトファイルか(拡張子で判定)。
    public static func isReadableFile(_ url: URL) -> Bool {
        readable.contains(url.pathExtension.lowercased())
    }

    /// ファイル名の拡張子を現在のものに付け替えたファイル名を作る。
    public static func fileName(replacingExtensionOf name: String) -> String {
        let base = (name as NSString).deletingPathExtension
        return (base as NSString).appendingPathExtension(current) ?? name
    }
}
