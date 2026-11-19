import Foundation
import AppKit
import UniformTypeIdentifiers
import MovieCutCore

/// ファイル ▸ FCP XMLを読み込む… / 出力 ▸ FCP XML形式(.xml)で書き出す… / EDL形式(.edl)で書き出す…。
/// 交換形式(FCP XML = XMEML、EDL = CMX 3600)による他ソフトとのプロジェクト受け渡し(移行支援)。
/// 対応できない要素は、書き出し・読み込みのどちらでもレポート(理由つき)をアラートで必ず見せる
/// (黙って落とさない。YmmpExporter と同じ作法)。対応範囲の詳細は docs/FCPXMLとEDL.md。
extension ProjectModel {

    // MARK: FCP XML 書き出し

    func chooseAndExportFcpXml() {
        guard canExport else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "xml") ?? .data]
        panel.nameFieldStringValue = documentName + ".xml"
        panel.canCreateDirectories = true
        panel.title = "FCP XML形式(.xml)で書き出す"
        panel.message = "Premiere Pro 等で開ける FCP XML(XMEML)として書き出します。対応できない要素は、書き出し後に一覧でお知らせします。"

        let run: (NSApplication.ModalResponse) -> Void = { [weak self] resp in
            guard resp == .OK, let picked = panel.url, let self else { return }
            let url = picked.pathExtension.lowercased() == "xml" ? picked : picked.appendingPathExtension("xml")
            do {
                let report = try FcpXmlExporter.write(project: self.project, to: url, sequenceName: self.documentName)
                NSWorkspace.shared.activateFileViewerSelecting([url])
                showInterchangeReport(title: "FCP XML形式で書き出しました", lines: report.summaryLines, hasLoss: report.hasLoss)
            } catch {
                let alert = NSAlert(error: error)
                if let w = self.window { alert.beginSheetModal(for: w) } else { alert.runModal() }
            }
        }
        if let w = window { panel.beginSheetModal(for: w, completionHandler: run) } else { panel.begin(completionHandler: run) }
    }

    // MARK: EDL 書き出し

    func chooseAndExportEdl() {
        guard canExport else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "edl") ?? .data]
        panel.nameFieldStringValue = documentName + ".edl"
        panel.canCreateDirectories = true
        panel.title = "EDL形式(.edl)で書き出す"
        panel.message = "CMX 3600 形式のカットリストとして書き出します(映像 1 トラック + 音声最大 4 トラック)。対応できない要素は、書き出し後に一覧でお知らせします。"

        let run: (NSApplication.ModalResponse) -> Void = { [weak self] resp in
            guard resp == .OK, let picked = panel.url, let self else { return }
            let url = picked.pathExtension.lowercased() == "edl" ? picked : picked.appendingPathExtension("edl")
            do {
                let report = try EdlExporter.write(project: self.project, to: url, title: self.documentName)
                NSWorkspace.shared.activateFileViewerSelecting([url])
                let lines = report.summaryLines
                showInterchangeReport(title: "EDL形式で書き出しました", lines: lines, hasLoss: report.hasLoss)
            } catch {
                let alert = NSAlert(error: error)
                if let w = self.window { alert.beginSheetModal(for: w) } else { alert.runModal() }
            }
        }
        if let w = window { panel.beginSheetModal(for: w, completionHandler: run) } else { panel.begin(completionHandler: run) }
    }

    // MARK: FCP XML 読み込み

    /// 開くパネルで .xml を選び、内容を確認してから今のプロジェクトを置き換える(1 回の Undo で戻せる)。
    func chooseAndImportFcpXml() {
        guard !isLocked else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "xml") ?? .data]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.title = "FCP XMLを読み込む"
        panel.message = "FCP XML(XMEML)を読み込み、今のプロジェクトをその内容に置き換えます(取り消しで戻せます)。対応できない要素は、読み込み後に一覧でお知らせします。"

        let run: (NSApplication.ModalResponse) -> Void = { [weak self] resp in
            guard resp == .OK, let url = panel.url, let self else { return }
            do {
                let out = try FcpXmlImporter.read(from: url)
                self.applyRoot(out.project, name: "FCP XMLを読み込む")
                self.showInterchangeReport(title: "FCP XMLを読み込みました", lines: out.report.summaryLines, hasLoss: out.report.hasLoss)
            } catch {
                let alert = NSAlert(error: error)
                if let w = self.window { alert.beginSheetModal(for: w) } else { alert.runModal() }
            }
        }
        if let w = window { panel.beginSheetModal(for: w, completionHandler: run) } else { panel.begin(completionHandler: run) }
    }

    // MARK: レポート表示(共通)

    private func showInterchangeReport(title: String, lines: [String], hasLoss: Bool) {
        let alert = NSAlert()
        alert.messageText = title
        if hasLoss { alert.alertStyle = .warning }
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: "OK")
        if let w = window { alert.beginSheetModal(for: w) } else { alert.runModal() }
    }
}
