import Foundation

// MARK: - 外部自動化からの書き出し(フェーズ D-3 / X-4)
//
// Shortcuts(App Intents)と AppleScript が使う共通の入口。書き出しそのものは既存の
// `ExportJob.run`(アプリの画面・コマンドラインと同じ経路)に任せ、二重実装にしない。
// ここは「パスの文字列・プリセット名・範囲の文字列」という自動化側の入力を検証して
// 計画(プロジェクト・出力先・プリセット・範囲)に直すところまでを担う。
// コマンドライン(`moviecut-cli export`)は従来どおり自前の引数解析のまま(挙動不変)で、
// 最終的に同じ `ExportJob.run` へ合流する。

/// 自動化から受け取る書き出しの頼み方(文字列ベース。Intents / AppleScript の引数変換の受け皿)。
public struct AutomationExportRequest: Equatable, Sendable {
    public var projectPath: String
    /// 省略時はプロジェクトと同じフォルダに `<名前>-書き出し.mp4`(プリセット時はプリセットの提案名)。
    public var outputPath: String?
    /// 組み込みプリセットの CLI 名(youtube1080 など)または保存したプリセットの名前。省略時はプロジェクトの設定のまま。
    public var presetName: String?
    /// "a:b"(秒)または "project"(プロジェクトに保存してある範囲)。省略時は全体。
    public var rangeText: String?

    public init(projectPath: String, outputPath: String? = nil, presetName: String? = nil, rangeText: String? = nil) {
        self.projectPath = projectPath
        self.outputPath = outputPath
        self.presetName = presetName
        self.rangeText = rangeText
    }
}

/// 自動化の書き出しで起きる入力側の失敗(日本語の理由つき)。
public enum AutomationError: Error, Equatable, Sendable {
    case emptyProjectPath
    case projectNotFound(String)
    case unknownPreset(String)
    case badRange(String)
    case sameAsProject

    public var message: String {
        switch self {
        case .emptyProjectPath: return "プロジェクトのファイルが指定されていません"
        case .projectNotFound(let p): return "プロジェクトが見つかりません: \(p)"
        case .unknownPreset(let n): return "プリセットが見つかりません: \(n)(組み込み: \(ExportPreset.allCases.map(\.rawValue).joined(separator: " / "))、または保存したプリセット名)"
        case .badRange(let m): return m
        case .sameAsProject: return "書き出し先がプロジェクトと同じファイルになっています"
        }
    }
}

extension AutomationError: LocalizedError {
    public var errorDescription: String? { message }
}

/// 検証済みの書き出し計画。
public struct AutomationExportPlan {
    public var project: Project
    public var projectURL: URL
    public var outputURL: URL
    public var preset: ExportPreset?
    public var spec: ExportSpec?
    public var range: ExportRange?
}

public enum AutomationExport {
    /// 既定の出力先: プロジェクトと同じフォルダ。プリセットがあれば提案名、無ければ「<名前>-書き出し.mp4」。
    public static func defaultOutputURL(projectURL: URL, preset: ExportPreset?, spec: ExportSpec?, codec: String? = nil) -> URL {
        let dir = projectURL.deletingLastPathComponent()
        let stem = projectURL.deletingPathExtension().lastPathComponent
        if let spec { return dir.appendingPathComponent(spec.suggestedFileName(documentName: stem)) }
        if let preset { return dir.appendingPathComponent(preset.suggestedFileName(documentName: stem)) }
        return dir.appendingPathComponent(stem + "-書き出し").appendingPathExtension(OutputPlan.fileExtension(forCodec: codec ?? ""))
    }

    /// 文字列の引数を検証して計画に直す。プロジェクトの読み込みを含む(ファイルが無ければ理由つきで失敗)。
    public static func plan(_ request: AutomationExportRequest, fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) throws -> AutomationExportPlan {
        let path = request.projectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { throw AutomationError.emptyProjectPath }
        let projectURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard fileExists(projectURL) else { throw AutomationError.projectNotFound(path) }
        let project = try Project.load(from: projectURL)

        var preset: ExportPreset?
        var spec: ExportSpec?
        if let name = request.presetName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            if let p = ExportPreset(cliName: name) {
                preset = p
            } else if let saved = CustomExportPresetStore.load(from: CustomExportPresetStore.defaultURL())
                .first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                spec = saved.spec
            } else {
                throw AutomationError.unknownPreset(name)
            }
        }

        var range: ExportRange?
        if let text = request.rangeText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            if text == "project" {
                guard let r = project.exportRange else {
                    throw AutomationError.badRange("プロジェクトに書き出し範囲が設定されていません")
                }
                range = r
            } else {
                switch ExportRange.parse(text, endTime: project.endTime) {
                case .success(let r): range = r
                case .failure(let e): throw AutomationError.badRange(e.message)
                }
            }
        }

        let outputURL: URL
        if let out = request.outputPath?.trimmingCharacters(in: .whitespacesAndNewlines), !out.isEmpty {
            outputURL = URL(fileURLWithPath: (out as NSString).expandingTildeInPath)
        } else {
            outputURL = defaultOutputURL(projectURL: projectURL, preset: preset, spec: spec, codec: project.codec)
        }
        guard outputURL.standardizedFileURL != projectURL.standardizedFileURL else { throw AutomationError.sameAsProject }
        return AutomationExportPlan(project: project, projectURL: projectURL, outputURL: outputURL, preset: preset, spec: spec, range: range)
    }

    /// 計画どおりに書き出す(既存の `ExportJob.run` に委譲)。出力先の URL を返す。
    @discardableResult
    public static func run(_ request: AutomationExportRequest, progress: ((Double) -> Void)? = nil) async throws -> URL {
        let plan = try plan(request)
        try await ExportJob.run(project: plan.project, preset: plan.preset, spec: plan.spec, range: plan.range, to: plan.outputURL, progress: progress)
        return plan.outputURL
    }

    /// プロジェクトの要約(Shortcuts / AppleScript の「情報を得る」用。読み取りのみ)。
    public static func projectInfoSummary(_ project: Project) -> String {
        let clips = project.allClips.count
        let lines = [
            "大きさ: \(project.width)×\(project.height)",
            "フレームレート: \(FrameRate.label(project.fps))",
            "長さ: \(String(format: "%.1f", project.endTime)) 秒",
            "トラック: \(project.tracks.count) / クリップ: \(clips)",
        ]
        return lines.joined(separator: "\n")
    }

    /// パスから読み込んだ要約(ファイルが無ければ理由つきで失敗)。
    public static func projectInfoSummary(projectPath: String) throws -> String {
        let path = projectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { throw AutomationError.emptyProjectPath }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else { throw AutomationError.projectNotFound(path) }
        return projectInfoSummary(try Project.load(from: url))
    }
}

/// 自動化からの新規プロジェクト作成(空のプロジェクトをファイルに書く)。
public enum AutomationProjectFile {
    /// フォルダと名前(拡張子なしでもよい)から出力先を決める。拡張子は現行の書き込み形式に合わせる。
    public static func outputURL(folder: URL, name: String) -> URL {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "名称未設定" : trimmed
        let ext = ProjectFileExtension.current
        if (base as NSString).pathExtension.lowercased() == ext { return folder.appendingPathComponent(base) }
        return folder.appendingPathComponent(base).appendingPathExtension(ext)
    }

    /// 空のプロジェクトを作って保存し、保存先を返す。同名がある場合は上書きしない(理由つきで失敗)。
    @discardableResult
    public static func createNew(folder: URL, name: String) throws -> URL {
        let url = outputURL(folder: folder, name: name)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw AutomationError.badRange("同じ名前のプロジェクトがすでにあります: \(url.lastPathComponent)")
        }
        try Project.new().save(to: url)
        return url
    }
}
