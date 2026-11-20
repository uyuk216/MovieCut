import Foundation
import AppKit
import UniformTypeIdentifiers
import MovieCutCore

/// 台本編集ウィンドウ(#41)と台本 CSV の読み書き(#42)の画面まわり。
/// 一覧編集の計算は Core の `ScriptTable`、CSV の変換は `ScriptCSV`。ここは選択・Undo・パネル・状態欄だけ。
extension ProjectModel {
    /// クリップ ▸ 台本を編集…: シートを出す。
    func openScriptTable() { showScriptTableSheet = true }

    /// 台本一覧の行(シートが開くときに読み、保存で書き戻す)。
    func scriptTableLines() -> [VoiceLine] { ScriptTable.lines(in: project) }

    /// 台本一覧の保存: 全部まとめて 1 回の Undo で当てる。当てた行数を返す。
    @discardableResult
    func commitScriptTable(_ lines: [VoiceLine]) -> Int {
        guard !isLocked else { return 0 }
        var applied = 0
        let ok = edit("台本の編集") { p in applied = ScriptTable.apply(lines, to: &p) }
        if ok {
            statusText = "台本 \(applied) 行を変更しました(音声は「音声の作り直し」で反映されます)"
        }
        return ok ? applied : 0
    }

    // MARK: 台本 CSV の書き出し

    /// 出力 ▸ 台本をCSVで書き出す…: ボイスクリップを 5 列の CSV で保存する。
    func chooseAndExportScriptCSV() {
        let result = ScriptCSV.csv(from: project)
        guard result.lineCount > 0 else { statusText = "書き出せる声のセリフがありません"; return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = documentName + "_台本.csv"
        panel.canCreateDirectories = true
        panel.title = L10n.t("台本をCSVで書き出す")
        panel.message = L10n.t("列は「キャラ,セリフ,読み,字幕,表情」です。そのまま読み込んで同じ台本に戻せます")
        let run: (NSApplication.ModalResponse) -> Void = { [weak self] resp in
            guard resp == .OK, let url = panel.url, let self else { return }
            do {
                try result.text.write(to: url, atomically: true, encoding: .utf8)
                self.statusText = "台本 \(result.lineCount) 行を \(url.lastPathComponent) に書き出しました"
                    + (result.skipped > 0 ? "(\(result.skipped) 件は書けませんでした)" : "")
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                self.errorTitle = "書き出せませんでした"
                self.errorMessage = error.localizedDescription
            }
        }
        FilePanelPresenter.shared.present(panel, window: window, completion: run)
    }

    // MARK: 台本 CSV の読み込み

    /// ファイル ▸ 台本CSVを読み込む…: CSV の行を台本テキストに直して、左の台本欄へ足す。
    /// 声の生成は従来どおり「台本から音声を作る」。読み込んだ行は台本欄で確認・修正できる。
    func chooseAndImportScriptCSV() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = L10n.t("台本CSVを読み込む")
        panel.message = L10n.t("CSV の行を台本に直して、台本欄の末尾へ足します")
        let run: (NSApplication.ModalResponse) -> Void = { [weak self] resp in
            guard resp == .OK, let url = panel.url, let self else { return }
            do {
                let text = try Self.readCSVText(from: url)
                let n = self.importScriptCSV(text: text)
                if n == 0 { self.statusText = "読み込める台本の行がありませんでした" }
            } catch {
                self.errorTitle = "読み込めませんでした"
                self.errorMessage = error.localizedDescription
            }
        }
        FilePanelPresenter.shared.present(panel, window: window, completion: run)
    }

    /// CSV ファイルの文字コードを推定して読む。UTF-16 は BOM があるときだけ先に試す
    /// (BOM の無い Shift_JIS のバイト列が UTF-16 として化けて読めてしまうため)。
    /// それ以外は UTF-8 → Shift_JIS → UTF-16 の順。
    static func readCSVText(from url: URL) throws -> String {
        let data = try InputLimits.readFile(url, limit: InputLimits.maxScriptCSVBytes, what: "台本の CSV")
        let hasUTF16BOM = data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF])
        let order: [String.Encoding] = hasUTF16BOM ? [.utf16, .utf8, .shiftJIS] : [.utf8, .shiftJIS, .utf16]
        for enc in order {
            if let s = String(data: data, encoding: enc) { return s }
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// CSV のテキストを台本欄へ足す。足した行数を返す(台本欄の変更は従来どおり Undo の対象外で、編集済みの印が付く)。
    @discardableResult
    func importScriptCSV(text: String) -> Int {
        let lines = ScriptCSV.lines(fromRows: ScriptCSV.scriptRows(fromCSV: text))
        guard !lines.isEmpty else { return 0 }
        let add = lines.joined(separator: "\n")
        scriptText = scriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? add
            : scriptText.trimmingCharacters(in: .newlines) + "\n" + add
        statusText = "台本CSVから \(lines.count) 行を台本欄へ足しました"
        return lines.count
    }
}
