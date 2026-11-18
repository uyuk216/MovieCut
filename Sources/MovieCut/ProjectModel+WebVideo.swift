import Foundation
import AppKit
import UniformTypeIdentifiers
import MovieCutCore

/// 出力 ▸ WebM / AV1 / WebP で書き出す…(ffmpeg が見つかるときだけ使える任意形式)。
/// AVFoundation / ImageIO では書けない形式のため、裏側は `FFmpegVideoExporter`(中間 MP4 + ffmpeg 変換)。
/// 書けない形式は、選んだ時点で理由をアラートで見せる(黙って失敗させない)。
extension ProjectModel {
    func chooseAndExportWebVideo() {
        guard canExport else { return }
        if reportMissingMediaForExport() { return }
        let formats = WebVideoFormat.allCases
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.title = "WebM / AV1 / WebP で書き出す"
        panel.message = "これらの形式は ffmpeg を使って変換します(無い形式は理由を表示します)。"

        let formatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        formatPopup.addItems(withTitles: formats.map(\.title))
        formatPopup.selectItem(at: 0)
        panel.nameFieldStringValue = documentName + "." + formats[0].fileExtension
        panel.allowedContentTypes = [UTType(filenameExtension: formats[0].fileExtension) ?? .movie]

        let row = NSStackView(views: [NSTextField(labelWithString: "形式"), formatPopup])
        row.orientation = .horizontal
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        panel.accessoryView = row

        // 形式を変えたら拡張子を合わせる
        let handler = WebVideoPanelHandler(panel: panel, formats: formats, documentName: documentName)
        formatPopup.target = handler
        formatPopup.action = #selector(WebVideoPanelHandler.formatChanged(_:))
        objc_setAssociatedObject(formatPopup, "handler", handler, .OBJC_ASSOCIATION_RETAIN)

        let run: (NSApplication.ModalResponse) -> Void = { [weak self] resp in
            guard resp == .OK, let picked = panel.url, let self else { return }
            let format = formats[max(0, min(formatPopup.indexOfSelectedItem, formats.count - 1))]
            let url = picked.pathExtension.lowercased() == format.fileExtension ? picked : picked.appendingPathExtension(format.fileExtension)
            // 書けない環境・形式なら、先に理由を見せて止める
            let ffmpeg = FFmpegLocator.find()
            let encoders = ffmpeg.map { FFmpegLocator.availableEncoders(at: $0) } ?? nil
            if let reason = format.unavailableReason(encoders: encoders, ffmpegFound: ffmpeg != nil) {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "\(format.title) は書けません"
                alert.informativeText = reason + "\n\nMP4 / MOV / GIF / APNG は通常どおり書き出せます。"
                alert.addButton(withTitle: "OK")
                if let w = self.window { alert.beginSheetModal(for: w) } else { alert.runModal() }
                return
            }
            Task { @MainActor in
                if case .success(let done) = await self.runWebVideoExport(to: url, format: format) {
                    NSWorkspace.shared.activateFileViewerSelecting([done])
                }
            }
        }
        if let w = window { panel.beginSheetModal(for: w, completionHandler: run) } else { panel.begin(completionHandler: run) }
    }

    /// 書き出しシートを出して追加形式を書く(MP4・GIF と同じ進み具合・キャンセル・失敗の扱い)。
    func runWebVideoExport(to url: URL, format: WebVideoFormat, range: ExportRange? = nil) async -> ExportOutcome {
        guard !directExportBlocked() else { return .failure(ExportError.writerFailed(nil)) }
        if reportMissingMediaForExport() { return .failure(ExportError.writerFailed(nil)) }
        let snapshot = project
        return await runJob(title: "\(format.title) を書き出しています", fileName: url.lastPathComponent, notices: [],
                            success: "\(url.lastPathComponent) に \(format.title) を書き出しました", result: url) { progress in
            try await FFmpegVideoExporter.export(project: snapshot, range: range, format: format, to: url, progress: progress)
        }
    }
}

/// 保存パネルの形式ポップアップの受け手(拡張子の追随)。
private final class WebVideoPanelHandler: NSObject {
    let panel: NSSavePanel
    let formats: [WebVideoFormat]
    let documentName: String
    init(panel: NSSavePanel, formats: [WebVideoFormat], documentName: String) {
        self.panel = panel; self.formats = formats; self.documentName = documentName
    }
    @objc func formatChanged(_ sender: NSPopUpButton) {
        let format = formats[max(0, min(sender.indexOfSelectedItem, formats.count - 1))]
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .movie]
        panel.nameFieldStringValue = documentName + "." + format.fileExtension
    }
}
