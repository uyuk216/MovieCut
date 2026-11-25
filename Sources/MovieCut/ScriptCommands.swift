import AppKit
import Foundation
import MovieCutCore

// MARK: - AppleScript(フェーズ D-3 / X-4)
//
// 定義は Resources/MovieCut.sdef(make-app.sh が .app に同梱し、Info.plist で有効化)。
// 引数の変換と実行は Shortcuts と同じ Core の `AutomationExport` に委譲する。
// 例:
//   tell application "Movie Cut"
//     export project (POSIX file "/path/to/a.mcpjc") preset "youtube1080"
//     project info (POSIX file "/path/to/a.mcpjc")
//   end tell

/// AppleScript の引数(ファイル・文字列)を素の値に直す。
enum ScriptArgumentConversion {
    /// 直接パラメータや引数として届くファイル指定(NSURL / パス文字列)をパスにする。
    static func path(from value: Any?) -> String? {
        switch value {
        case let url as NSURL: return url.path
        case let url as URL: return url.path
        case let s as String: return s
        case let s as NSString: return s as String
        default: return nil
        }
    }

    static func text(from value: Any?) -> String? {
        switch value {
        case let s as String: return s
        case let s as NSString: return s as String
        default: return nil
        }
    }

    /// コマンドの引数一式から書き出しの頼み方を組み立てる(直接パラメータ = プロジェクト)。
    static func exportRequest(directParameter: Any?, arguments: [String: Any]?) -> AutomationExportRequest? {
        guard let projectPath = path(from: directParameter) else { return nil }
        return AutomationExportRequest(
            projectPath: projectPath,
            outputPath: arguments.flatMap { path(from: $0["output"]) },
            presetName: arguments.flatMap { text(from: $0["preset"]) }
        )
    }
}

/// 「export project」コマンド。書き出しは時間がかかるので、実行を止めて(suspend)完了後に結果を返す。
final class ExportProjectScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let request = ScriptArgumentConversion.exportRequest(directParameter: directParameter, arguments: evaluatedArguments) else {
            scriptErrorNumber = -50
            scriptErrorString = "プロジェクトのファイルを指定してください"
            return nil
        }
        suspendExecution()
        Task.detached { [self] in
            do {
                let output = try await AutomationExport.run(request)
                await MainActor.run { resumeExecution(withResult: NSURL(fileURLWithPath: output.path)) }
            } catch {
                let message = error.localizedDescription
                await MainActor.run {
                    scriptErrorNumber = -1
                    scriptErrorString = message
                    resumeExecution(withResult: nil)
                }
            }
        }
        return nil
    }
}

/// 「project info」コマンド(読み取りのみ・即時)。
final class ProjectInfoScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let projectPath = ScriptArgumentConversion.path(from: directParameter) else {
            scriptErrorNumber = -50
            scriptErrorString = "プロジェクトのファイルを指定してください"
            return nil
        }
        do {
            return try AutomationExport.projectInfoSummary(projectPath: projectPath) as NSString
        } catch {
            scriptErrorNumber = -1
            scriptErrorString = error.localizedDescription
            return nil
        }
    }
}
