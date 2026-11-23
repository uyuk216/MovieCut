import Foundation
import AppKit
import UniformTypeIdentifiers
import MovieCutCore

/// 出力 ▸ WebM / AV1 / WebP / DNxHR で書き出す…(ffmpeg が見つかるときだけ使える任意形式)。
/// AVFoundation / ImageIO では書けない形式のため、裏側は `FFmpegVideoExporter`(中間 MP4 + ffmpeg 変換)。
/// 書けない形式は、選んだ時点で理由をアラートで見せる(黙って失敗させない)。
extension ProjectModel {
    func chooseAndExportWebVideo() {
        guard canExport else { return }
        if reportMissingMediaForExport() { return }
        let formats = WebVideoFormat.allCases
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.title = L10n.t("WebM / AV1 / WebP / DNxHR で書き出す")
        panel.message = L10n.t("これらの形式は ffmpeg(アニメーション WebP は img2webp も)を使って変換します(無い形式は理由を表示します)。DNxHR は MOV(音声は無圧縮 PCM)で書き出します。")

        let formatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        formatPopup.addItems(withTitles: formats.map(\.title))
        formatPopup.selectItem(at: 0)
        panel.nameFieldStringValue = documentName + "." + formats[0].fileExtension
        panel.allowedContentTypes = [UTType(filenameExtension: formats[0].fileExtension) ?? .movie]

        let row = NSStackView(views: [NSTextField(labelWithString: L10n.t("形式")), formatPopup])
        row.orientation = .horizontal
        row.spacing = 8

        // DNxHR のときだけ、プロファイルの説明(用途・ビット深度・色差)を出す
        let detailLabel = NSTextField(wrappingLabelWithString: "")
        detailLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.setAccessibilityIdentifier("webvideo-format-detail")

        // ラウドネス正規化(通常書き出しと同じ設定。F-3: WebVideo 経路にも引き継ぐ)
        let loudnessBox = NSButton(checkboxWithTitle: L10n.t("ラウドネス正規化"), target: nil, action: nil)
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
        let column = NSStackView(views: [row, detailLabel, loudnessRow])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        panel.accessoryView = column

        // 形式を変えたら拡張子を合わせる
        let handler = WebVideoPanelHandler(panel: panel, formats: formats, documentName: documentName)
        handler.detailLabel = detailLabel
        handler.updateDetail(index: 0)
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
                alert.messageText = String(format: L10n.t("%@ は書けません"), L10n.t(format.title))
                alert.informativeText = reason + "\n\nMP4 / MOV / GIF / APNG は通常どおり書き出せます。"
                alert.addButton(withTitle: "OK")
                if let w = self.window { alert.beginSheetModal(for: w) } else { alert.runModal() }
                return
            }
            // DNxHR はサイズの対応範囲があるため、書き出し前に理由を見せて止める(ffmpeg の英語ログで失敗させない)
            if let profile = format.dnxProfile,
               let message = DNxHRProfile.validationError(width: self.project.width, height: self.project.height, fps: self.project.fps) {
                _ = profile
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = String(format: L10n.t("%@ は書けません"), L10n.t(format.title))
                alert.informativeText = message
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
        FilePanelPresenter.shared.present(panel, window: window, completion: run)
    }

    /// 書き出しシートを出して追加形式を書く(MP4・GIF と同じ進み具合・キャンセル・失敗の扱い)。
    func runWebVideoExport(to url: URL, format: WebVideoFormat, range: ExportRange? = nil,
                           loudness: LoudnessNormalizationSettings = .disabled) async -> ExportOutcome {
        guard !directExportBlocked() else { return .failure(ExportError.writerFailed(nil)) }
        if reportMissingMediaForExport() { return .failure(ExportError.writerFailed(nil)) }
        let snapshot = project
        // 範囲は、編集スコープを抜けた後(書類全体に戻った状態)で解決する(GIF と同じ)
        let effectiveRange = range ?? project.exportRange
        return await runJob(title: String(format: L10n.t("%@ を書き出しています"), L10n.t(format.title)), fileName: url.lastPathComponent, notices: [],
                            success: String(format: L10n.t("%@ に %@ を書き出しました"), url.lastPathComponent, L10n.t(format.title)), result: url) { progress in
            try await FFmpegVideoExporter.export(project: snapshot, range: effectiveRange, format: format, to: url, loudness: loudness, pluginEffectProviders: AppServices.pluginEffectProviders, vst3Provider: AppServices.vst3EffectProvider, progress: progress)
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
    var detailLabel: NSTextField?
    /// 形式に合わせた説明文(DNxHR プロファイルの用途・ビット深度・色差。それ以外は空)。
    func updateDetail(index: Int) {
        let format = formats[max(0, min(index, formats.count - 1))]
        guard let profile = format.dnxProfile else { detailLabel?.stringValue = ""; return }
        detailLabel?.stringValue = "\(L10n.t(profile.summary)) · \(profile.bitDepth)bit \(profile.chromaSubsampling) · MOV"
    }
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
        updateDetail(index: sender.indexOfSelectedItem)
        let format = formats[max(0, min(sender.indexOfSelectedItem, formats.count - 1))]
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .movie]
        panel.nameFieldStringValue = documentName + "." + format.fileExtension
    }
}
