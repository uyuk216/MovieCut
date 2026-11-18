import Foundation

// MARK: - サンプル組み込み書き出しプラグイン 1: GIF(既存バックエンドの包み)

/// 既存の `GIFExporter` をそのまま書き出しプラグインとして扱うバックエンド(サンプル)。
///
/// 「任意の書き出しバックエンドをプラグインとして扱える」ことの実証を兼ねる:
/// 本体は新しい描画を持たず、内蔵 GIF 書き出しへ委譲するだけである。
public struct GIFExportBackend: ExportBackendProviding {
    public var options: GIFOptions

    public init(options: GIFOptions = .standard) { self.options = options }

    public var formatDescriptors: [ExportFormatDescriptor] { [GIFExportPlugin.format] }

    public func export(formatID: String, project: Project, assets: RenderAssets, range: ExportRange?, to url: URL, progress: ((Double) -> Void)?) async throws -> PluginExportResult {
        guard formatID.trimmingCharacters(in: .whitespaces).lowercased() == GIFExportPlugin.formatID else {
            throw PluginError.noExportPlugin(formatID: formatID)
        }
        let result = try await GIFExporter.export(project: project, assets: assets, range: range, options: options, to: url, progress: progress)
        return PluginExportResult(url: result.url, formatID: GIFExportPlugin.formatID, bytes: result.bytes)
    }
}

/// GIF 書き出しプラグインの名前空間(マニフェスト)。
public enum GIFExportPlugin {
    public static let pluginID = "jp.local.moviecut.plugin.export-gif"
    public static let formatID = "gif"

    public static var format: ExportFormatDescriptor {
        ExportFormatDescriptor(id: formatID, name: "アニメーションGIF(プラグイン)", fileExtension: "gif",
                               detail: "内蔵 GIFExporter をプラグイン経由で使うサンプル")
    }

    public static var manifest: PluginManifest {
        PluginManifest(id: pluginID,
                       name: "GIF書き出し",
                       version: "1.0.0",
                       hooks: [.exporter],
                       entryPoint: "GIFExportPlugin",
                       minimumAppVersion: nil,
                       exportFormatIDs: [formatID],
                       requiresLicense: false,
                       description: "アニメーション GIF で書き出すプラグイン(組み込みサンプル)")
    }

    /// `manifest.json` の中身(PluginDiscovery で読める形)。
    public static func manifestJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(manifest), as: UTF8.self)
    }
}

// MARK: - サンプル組み込み書き出しプラグイン 2: プロジェクト情報 JSON(描画しない軽量形式)

/// プロジェクトの要約を JSON で書き出すバックエンド(サンプル)。
///
/// 描画を一切しない軽量な形式で、「映像でない書き出し形式」も同じ境界に乗ることを示す。
/// 出力はキー順を固定した決定的な JSON(同じプロジェクトからは同じバイト列になる)。
public struct ProjectInfoExportBackend: ExportBackendProviding {
    public init() {}

    public var formatDescriptors: [ExportFormatDescriptor] { [ProjectInfoExportPlugin.format] }

    public func export(formatID: String, project: Project, assets: RenderAssets, range: ExportRange?, to url: URL, progress: ((Double) -> Void)?) async throws -> PluginExportResult {
        guard formatID.trimmingCharacters(in: .whitespaces).lowercased() == ProjectInfoExportPlugin.formatID else {
            throw PluginError.noExportPlugin(formatID: formatID)
        }
        let duration = range?.duration ?? project.endTime
        let clipCount = project.tracks.reduce(0) { $0 + $1.clips.count }
        let info: [String: Any] = [
            "format": "moviecut-project-info",
            "version": 1,
            "width": project.width,
            "height": project.height,
            "fps": project.fps,
            "duration": duration,
            "tracks": project.tracks.count,
            "clips": clipCount,
        ]
        let data = try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: [.atomic])
        progress?(1.0)
        return PluginExportResult(url: url, formatID: ProjectInfoExportPlugin.formatID, bytes: data.count)
    }
}

/// プロジェクト情報 JSON プラグインの名前空間(マニフェスト)。
public enum ProjectInfoExportPlugin {
    public static let pluginID = "jp.local.moviecut.plugin.export-project-json"
    public static let formatID = "project-json"

    public static var format: ExportFormatDescriptor {
        ExportFormatDescriptor(id: formatID, name: "プロジェクト情報JSON(プラグイン)", fileExtension: "json",
                               detail: "解像度・長さ・クリップ数などの要約を JSON で書き出す")
    }

    public static var manifest: PluginManifest {
        PluginManifest(id: pluginID,
                       name: "プロジェクト情報書き出し",
                       version: "1.0.0",
                       hooks: [.exporter],
                       entryPoint: "ProjectInfoExportPlugin",
                       minimumAppVersion: nil,
                       exportFormatIDs: [formatID],
                       requiresLicense: false,
                       description: "プロジェクトの要約を JSON で書き出すプラグイン(組み込みサンプル)")
    }

    /// `manifest.json` の中身(PluginDiscovery で読める形)。
    public static func manifestJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(manifest), as: UTF8.self)
    }
}
