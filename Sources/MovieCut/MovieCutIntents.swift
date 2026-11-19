import AppIntents
import Foundation
import MovieCutCore

// MARK: - Shortcuts(App Intents)(フェーズ D-3 / X-4)
//
// 外部自動化(ショートカットアプリ)から Movie Cut の主要操作を呼ぶための公開面。
// 書き出しの実体は Core の `AutomationExport`(= 既存の `ExportJob`)に委譲し、
// アプリ画面・コマンドラインと経路を共有する(二重実装にしない)。
// 引数の変換(ファイル→パス、プリセット名)はここで薄く行い、検証は Core が担う。

/// 書き出しプリセットの選択肢(ショートカットの引数用)。値は Core の CLI 名と一致させる。
enum ExportPresetIntentValue: String, AppEnum {
    case current
    case youtube1080, youtube1080p60, youtube4k, short, shorts, tiktok, reels, x720, x1080, light, audio

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "書き出しプリセット"

    static var caseDisplayRepresentations: [Self: DisplayRepresentation] {
        [
            .current: "プロジェクトの設定のまま",
            .youtube1080: "YouTube 1080p",
            .youtube1080p60: "YouTube 1080p60",
            .youtube4k: "YouTube 4K",
            .short: "ショート縦",
            .shorts: "YouTube Shorts",
            .tiktok: "TikTok",
            .reels: "Instagram リール",
            .x720: "X 720p",
            .x1080: "X 1080p",
            .light: "軽量 720p",
            .audio: "音声のみ",
        ]
    }

    /// Core のプリセット名(「設定のまま」は nil)。
    var corePresetName: String? { self == .current ? nil : rawValue }
}

/// IntentFile を実ファイルの URL に直す。URL で渡されればそのまま、データで渡されれば一時ファイルに書く。
enum IntentFileConversion {
    static func fileURL(from file: IntentFile) throws -> URL {
        if let url = file.fileURL { return url }
        let ext = (file.filename as NSString).pathExtension
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("moviecut-intent-\(UUID().uuidString)")
            .appendingPathExtension(ext.isEmpty ? ProjectFileExtension.current : ext)
        try file.data.write(to: tmp)
        return tmp
    }
}

/// プロジェクトを書き出す(ショートカット)。
struct ExportProjectIntent: AppIntent {
    static var title: LocalizedStringResource = "プロジェクトを書き出す"
    static var description = IntentDescription("Movie Cut のプロジェクトを動画ファイルに書き出します。書き出し先はプロジェクトと同じフォルダです。")
    static var openAppWhenRun = false

    @Parameter(title: "プロジェクト")
    var projectFile: IntentFile

    @Parameter(title: "プリセット", default: .current)
    var preset: ExportPresetIntentValue

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let projectURL = try IntentFileConversion.fileURL(from: projectFile)
        let request = AutomationExportRequest(projectPath: projectURL.path, presetName: preset.corePresetName)
        let output = try await AutomationExport.run(request)
        return .result(value: output.path,
                       dialog: "書き出しました: \(output.lastPathComponent)")
    }
}

/// プロジェクトの情報を見る(ショートカット。読み取りのみ)。
struct ProjectInfoIntent: AppIntent {
    static var title: LocalizedStringResource = "プロジェクトの情報を見る"
    static var description = IntentDescription("Movie Cut のプロジェクトの大きさ・長さ・クリップ数を返します。")
    static var openAppWhenRun = false

    @Parameter(title: "プロジェクト")
    var projectFile: IntentFile

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let projectURL = try IntentFileConversion.fileURL(from: projectFile)
        let summary = try AutomationExport.projectInfoSummary(projectPath: projectURL.path)
        return .result(value: summary, dialog: "\(summary)")
    }
}

/// 新しいプロジェクトを作る(ショートカット)。
struct CreateProjectIntent: AppIntent {
    static var title: LocalizedStringResource = "プロジェクトを作る"
    static var description = IntentDescription("指定のフォルダに、新しい空の Movie Cut プロジェクトを作ります。")
    static var openAppWhenRun = false

    @Parameter(title: "保存先フォルダ")
    var folder: IntentFile

    @Parameter(title: "名前")
    var name: String

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard let folderURL = folder.fileURL else {
            throw AutomationError.badRange("保存先フォルダを指定してください")
        }
        let created = try AutomationProjectFile.createNew(folder: folderURL, name: name)
        return .result(value: created.path,
                       dialog: "プロジェクトを作りました: \(created.lastPathComponent)")
    }
}

/// ショートカットアプリの候補に出す組み合わせ。
struct MovieCutShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ExportProjectIntent(),
                    phrases: ["\(.applicationName)でプロジェクトを書き出す"],
                    shortTitle: "プロジェクトを書き出す",
                    systemImageName: "square.and.arrow.up")
        AppShortcut(intent: ProjectInfoIntent(),
                    phrases: ["\(.applicationName)でプロジェクトの情報を見る"],
                    shortTitle: "プロジェクトの情報を見る",
                    systemImageName: "info.circle")
        AppShortcut(intent: CreateProjectIntent(),
                    phrases: ["\(.applicationName)でプロジェクトを作る"],
                    shortTitle: "プロジェクトを作る",
                    systemImageName: "doc.badge.plus")
    }
}
