import Foundation
import AppKit
import UniformTypeIdentifiers
import MovieCutCore

/// 出力 ▸ 台本を書き出す… / 絵コンテを書き出す…(どちらも保存パネルを開く。ショートカットなし)。
extension ProjectModel {
    /// 声のセリフを「キャラ名: セリフ」の行にして、テキストで保存する。読み直すと同じキャラの声に戻る。
    func chooseAndExportScript() {
        let result = VoiceScriptExport.make(project)
        guard result.lineCount > 0 else { statusText = "書き出せる声のセリフがありません"; return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = documentName + "_台本.txt"
        panel.canCreateDirectories = true
        panel.title = "台本を書き出す(テキスト)"
        panel.message = "「キャラ名: セリフ」の行で書きます。台本欄に貼ると、同じキャラで読み上げられます"
        let run: (NSApplication.ModalResponse) -> Void = { [weak self] resp in
            guard resp == .OK, let url = panel.url, let self else { return }
            do {
                try (result.text + "\n").write(to: url, atomically: true, encoding: .utf8)
                self.statusText = "台本 \(result.lineCount) 行を \(url.lastPathComponent) に書き出しました"
                    + (result.skipped > 0 ? "(\(result.skipped) 件は書けませんでした)" : "")
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                self.errorTitle = "書き出せませんでした"
                self.errorMessage = error.localizedDescription
            }
        }
        if let w = window { panel.beginSheetModal(for: w, completionHandler: run) } else { panel.begin(completionHandler: run) }
    }

    /// 全体を 12 等分した各区間の中央のコマを、格子の PNG 1 枚にする(プレビューと同じ描画経路)。
    func chooseAndExportStoryboard() {
        guard canExport else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = documentName + "_絵コンテ.png"
        panel.canCreateDirectories = true
        panel.title = "絵コンテを書き出す(PNG)"
        panel.message = "全体を \(Storyboard.defaultCount) 枚に区切った代表フレームを、\(Storyboard.defaultColumns) 列で並べます"
        let run: (NSApplication.ModalResponse) -> Void = { [weak self] resp in
            guard resp == .OK, let url = panel.url, let self else { return }
            do {
                try Storyboard.write(project: self.project, to: url)
                self.statusText = "絵コンテを \(url.lastPathComponent) に書き出しました"
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                self.statusText = "絵コンテの書き出しに失敗しました"
                self.errorTitle = "書き出せませんでした"
                self.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
        if let w = window { panel.beginSheetModal(for: w, completionHandler: run) } else { panel.begin(completionHandler: run) }
    }
}
