import Foundation
import AppKit
import UniformTypeIdentifiers
import MovieCutCore

/// 出力 ▸ YMM4形式(.ymmp)で書き出す…(MovieCut プロジェクトを YMM4 のプロジェクトファイルへ書き戻す)。
/// 対応できない要素は、書き出し後にレポート(理由つき)をアラートで必ず見せる(黙って落とさない)。
extension ProjectModel {
    func chooseAndExportYmmp() {
        guard canExport else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "ymmp") ?? .data]
        panel.nameFieldStringValue = documentName + ".ymmp"
        panel.canCreateDirectories = true
        panel.title = L10n.t("YMM4 形式(.ymmp)で書き出す")
        panel.message = L10n.t("YMM4(ゆっくりMovieMaker4)で開けるプロジェクトファイルとして書き出します。対応できない要素は、書き出し後に一覧でお知らせします。")

        let run: (NSApplication.ModalResponse) -> Void = { [weak self] resp in
            guard resp == .OK, let picked = panel.url, let self else { return }
            let url = picked.pathExtension.lowercased() == "ymmp" ? picked : picked.appendingPathExtension("ymmp")
            do {
                let report = try YmmpExporter.write(project: self.project, to: url)
                NSWorkspace.shared.activateFileViewerSelecting([url])
                let alert = NSAlert()
                alert.messageText = L10n.t("YMM4 形式で書き出しました")
                if report.hasLoss {
                    alert.alertStyle = .warning
                    alert.informativeText = report.summaryLines.joined(separator: "\n")
                } else {
                    alert.informativeText = String(format: L10n.t("書き出し: %d 件\n"), report.convertedCount) + report.notes.map { L10n.t("注記: ") + $0 }.joined(separator: "\n")
                }
                alert.addButton(withTitle: "OK")
                if let w = self.window { alert.beginSheetModal(for: w) } else { alert.runModal() }
            } catch {
                let alert = NSAlert(error: error)
                if let w = self.window { alert.beginSheetModal(for: w) } else { alert.runModal() }
            }
        }
        FilePanelPresenter.shared.present(panel, window: window, completion: run)
    }
}
