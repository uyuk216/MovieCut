import Foundation
import AppKit
import MovieCutCore

/// 出力 ▸ サムネイル画像を書き出す…: 今の再生位置のコマを 1280×720 の PNG / JPEG にする。
extension ProjectModel {
    func chooseAndExportThumbnail() {
        guard canExport else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.nameFieldStringValue = documentName + "_thumbnail.png"
        panel.canCreateDirectories = true
        panel.title = "サムネイル画像を書き出す(1280×720)"
        panel.message = "拡張子で形式が決まります(.png / .jpg)。縦横比が違うときは余白を背景色で埋めます"
        let run: (NSApplication.ModalResponse) -> Void = { [weak self] resp in
            guard resp == .OK, let url = panel.url, let self else { return }
            Task { @MainActor in
                if self.exportThumbnail(to: url) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        }
        if let w = window { panel.beginSheetModal(for: w, completionHandler: run) } else { panel.begin(completionHandler: run) }
    }

    /// 今の再生位置のコマを 1280×720 で `url` に書く(形式は拡張子。.jpg / .jpeg 以外は PNG)。
    @discardableResult
    func exportThumbnail(to url: URL) -> Bool {
        guard canExport else { return false }
        let format = StillFormat(pathExtension: url.pathExtension) ?? .png
        do {
            try ThumbnailExporter.write(project: project, at: stillTime, format: format, to: url)
            statusText = "サムネイル（1280×720）を \(url.lastPathComponent) に書き出しました"
            return true
        } catch {
            statusText = "サムネイルの書き出しに失敗しました"
            errorTitle = "書き出せませんでした"
            errorMessage = error.localizedDescription
            return false
        }
    }
}
