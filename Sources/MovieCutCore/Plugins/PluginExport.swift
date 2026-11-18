import Foundation

/// プラグインが提供する書き出し形式 1 種の記述子。
public struct ExportFormatDescriptor: Equatable, Sendable {
    /// 形式識別子(解決キー。例: "gif" / "project-json")。
    public var id: String
    /// 表示名。
    public var name: String
    /// 出力ファイルの拡張子("." なし)。
    public var fileExtension: String
    /// 人間向けの短い説明(任意)。
    public var detail: String?

    public init(id: String, name: String, fileExtension: String, detail: String? = nil) {
        self.id = id
        self.name = name
        self.fileExtension = fileExtension
        self.detail = detail
    }
}

/// プラグイン書き出しの結果。
public struct PluginExportResult: Equatable, Sendable {
    /// 書き出されたファイル。
    public var url: URL
    /// 使った形式識別子。
    public var formatID: String
    /// 出力ファイルのバイト数。
    public var bytes: Int

    public init(url: URL, formatID: String, bytes: Int) {
        self.url = url
        self.formatID = formatID
        self.bytes = bytes
    }
}

/// 書き出しプラグインの接続点。任意の書き出しバックエンドをプラグインとして扱うための境界。
///
/// - 非同期(書き出しは時間がかかるため)。進み具合は `progress`(0〜1)で知らせる。
/// - 入力は内蔵書き出し(`ExportJob` / `Exporter`)と同じ部品(プロジェクト・素材・区間)なので、
///   既存の書き出し実装(例: `GIFExporter`)をそのまま包んでプラグイン化できる。
/// - 担当外の `formatID` ではエラーを投げる(解決は `PluginHost` がマニフェストで先に行う前提だが、
///   直接呼ばれた場合の安全弁)。
public protocol ExportBackendProviding {
    /// 提供する形式の記述子の一覧。
    var formatDescriptors: [ExportFormatDescriptor] { get }
    /// `url` へ書き出す。キャンセルの扱いはバックエンド実装に従う(内蔵と同様、失敗時は出力先を壊さないのが望ましい)。
    func export(formatID: String, project: Project, assets: RenderAssets, range: ExportRange?, to url: URL, progress: ((Double) -> Void)?) async throws -> PluginExportResult
}

/// プラグイン書き出しの入口(音声の `PluginVoiceRoutingProvider` と同じ考え方)。
///
/// 担当プラグインが登録されていればプラグイン経路で書き出し、結果を返す。
/// 未登録・解決失敗のときは nil を返し、呼び出し側が内蔵書き出し(`ExportJob`)へ落とす。
/// プラグイン経路で書き出し自体が失敗した場合は、そのエラーをそのまま投げる(黙って別形式に化けないため)。
public enum PluginExportJob {
    @discardableResult
    public static func runIfAvailable(host: PluginHost, formatID: String, project: Project, assets: RenderAssets = RenderAssets(), range: ExportRange? = nil, to url: URL, progress: ((Double) -> Void)? = nil) async throws -> PluginExportResult? {
        let backend: (any ExportBackendProviding)? = try? host.exportBackendIfAvailable(forFormat: formatID)
        guard let backend else { return nil }
        return try await backend.export(formatID: formatID, project: project, assets: assets, range: range, to: url, progress: progress)
    }
}
