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
        panel.message = "これらの形式は ffmpeg(アニメーション WebP は img2webp も)を使って変換します(無い形式は理由を表示します)。"

        let formatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        formatPopup.addItems(withTitles: formats.map(\.title))
        formatPopup.selectItem(at: 0)
        panel.nameFieldStringValue = documentName + "." + formats[0].fileExtension
        panel.allowedContentTypes = [UTType(filenameExtension: formats[0].fileExtension) ?? .movie]

        let row = NSStackView(views: [NSTextField(labelWithString: "形式"), formatPopup])
        row.orientation = .horizontal
        row.spacing = 8

        // ラウドネス正規化(通常書き出しと同じ設定。F-3: WebVideo 経路にも引き継ぐ)
        let loudnessBox = NSButton(checkboxWithTitle: "ラウドネス正規化", target: nil, action: nil)
        loudnessBox.state = .off
        loudnessBox.setAccessibilityIdentifier("webvideo-loudness")
        let loudnessPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        for t in ExportPanelOptions.loudnessTargetChoices {
            loudnessPopup.addItem(withTitle: String(format: "%g LUFS", t) + (t == LoudnessNormalizationSettings.defaultTargetLUFS ? "(YouTube)" : ""))
        }
        loudnessPopup.selectItem(at: ExportPanelOptions.loudnessTargetChoices.firstIndex(of: LoudnessNormalizationSettings.defaultTargetLUFS) ?? 0)
        loudnessPopup.isEnabled = false
        loudnessPopup.setAccessibilityIdentifier("webvideo-loudness-target")
        let loudnessRow = NSStackView(views: [loudnessBox, loudnessPopup])
        loudnessRow.orientation = .horizontal
        loudnessRow.spacing = 8
        let column = NSStackView(views: [row, loudnessRow])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        panel.accessoryView = column

        // 形式を変えたら拡張子を合わせる
        let handler = WebVideoPanelHandler(panel: panel, formats: formats, documentName: documentName)
        handler.loudnessBox = loudnessBox
        handler.loudnessPopup = loudnessPopup
        formatPopup.target = handler
        formatPopup.action = #selector(WebVideoPanelHandler.formatChanged(_:))
        loudnessBox.target = handler
        loudnessBox.action = #selector(WebVideoPanelHandler.loudnessToggled(_:))
        objc_setAssociatedObject(formatPopup, "handler", handler, .OBJC_ASSOCIATION_RETAIN)

        let run: (NSApplication.ModalResponse) -> Void = { [weak self] resp in
            guard resp == .OK, let picked = panel.url, let self else { return }
            let format = formats[max(0, min(formatPopup.indexOfSelectedItem, formats.count - 1))]
            let url = picked.pathExtension.lowercased() == format.fileExtension ? picked : picked.appendingPathExtension(format.fileExtension)
            // 書けない環境・形式なら、先に理由を見せて止める
            let ffmpeg = FFmpegLocator.find()
            let encoders = ffmpeg.map { FFmpegLocator.availableEncoders(at: $0) } ?? nil
            if let reason = format.unavailableReason(encoders: encoders, ffmpegFound: ffmpeg != nil, img2webpFound: Img2WebPLocator.find() != nil) {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "\(format.title) は書けません"
                alert.informativeText = reason + "\n\nMP4 / MOV / GIF / APNG は通常どおり書き出せます。"
                alert.addButton(withTitle: "OK")
                if let w = self.window { alert.beginSheetModal(for: w) } else { alert.runModal() }
                return
            }
            let loudness = handler.selectedLoudness
            Task { @MainActor in
                if case .success(let done) = await self.runWebVideoExport(to: url, format: format, loudness: loudness) {
                    NSWorkspace.shared.activateFileViewerSelecting([done])
                }
            }
        }
        if let w = window { panel.beginSheetModal(for: w, completionHandler: run) } else { panel.begin(completionHandler: run) }
    }

    /// 書き出しシートを出して追加形式を書く(MP4・GIF と同じ進み具合・キャンセル・失敗の扱い)。
    func runWebVideoExport(to url: URL, format: WebVideoFormat, range: ExportRange? = nil,
                           loudness: LoudnessNormalizationSettings = .disabled) async -> ExportOutcome {
        guard !directExportBlocked() else { return .failure(ExportError.writerFailed(nil)) }
        if reportMissingMediaForExport() { return .failure(ExportError.writerFailed(nil)) }
        let snapshot = project
        return await runJob(title: "\(format.title) を書き出しています", fileName: url.lastPathComponent, notices: [],
                            success: "\(url.lastPathComponent) に \(format.title) を書き出しました", result: url) { progress in
            try await FFmpegVideoExporter.export(project: snapshot, range: range, format: format, to: url, loudness: loudness, pluginEffectProviders: AppServices.pluginEffectProviders, progress: progress)
        }
    }
}

/// 保存パネルの形式ポップアップの受け手(拡張子の追随)。
private final class WebVideoPanelHandler: NSObject {
    let panel: NSSavePanel
    let formats: [WebVideoFormat]
    let documentName: String
    var loudnessBox: NSButton?
    var loudnessPopup: NSPopUpButton?
    init(panel: NSSavePanel, formats: [WebVideoFormat], documentName: String) {
        self.panel = panel; self.formats = formats; self.documentName = documentName
    }
    @objc func loudnessToggled(_ sender: Any?) { loudnessPopup?.isEnabled = loudnessBox?.state == .on }
    /// 選んだラウドネス正規化の設定(チェックがオフなら .disabled。通常書き出しと同じ決まり)。
    var selectedLoudness: LoudnessNormalizationSettings {
        guard loudnessBox?.state == .on, let popup = loudnessPopup else { return .disabled }
        let i = popup.indexOfSelectedItem
        let t = i >= 0 && i < ExportPanelOptions.loudnessTargetChoices.count ? ExportPanelOptions.loudnessTargetChoices[i] : LoudnessNormalizationSettings.defaultTargetLUFS
        return .enabled(targetLUFS: t)
    }
    @objc func formatChanged(_ sender: NSPopUpButton) {
        let format = formats[max(0, min(sender.indexOfSelectedItem, formats.count - 1))]
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .movie]
        panel.nameFieldStringValue = documentName + "." + format.fileExtension
    }
}
