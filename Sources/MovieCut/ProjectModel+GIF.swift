import Foundation
import AppKit
import UniformTypeIdentifiers
import MovieCutCore

/// 出力 ▸ GIFとして書き出す…(アニメーション GIF。音は入らない)。
/// 描画は書き出し・プレビューと同じ `Renderer`。進み具合・キャンセル・完了の表示は MP4 と同じ書き出しシート。
extension ProjectModel {
    /// 保存パネル(fps・幅・範囲を決める)→ 書き出し。
    func chooseAndExportGIF() {
        guard canExport else { return }
        if reportMissingMediaForExport() { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.gif]
        panel.nameFieldStringValue = documentName + ".gif"
        panel.canCreateDirectories = true
        panel.title = "GIF として書き出す"
        panel.message = "fps と大きさは下で選べます。音は入りません。"

        let fpsValues = GIFOptions.presetFPS
        let fpsPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        fpsPopup.addItems(withTitles: fpsValues.map { "\(Int($0)) fps" })
        fpsPopup.selectItem(at: fpsValues.firstIndex(of: GIFOptions.standard.fps) ?? 1)

        // 最後の項目は「原寸」(幅を縮めない = nil)
        let widthValues: [Int?] = GIFOptions.presetWidths.map { $0 } + [nil]
        let widthPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        widthPopup.addItems(withTitles: GIFOptions.presetWidths.map { "幅 \($0) px" } + ["原寸(\(project.width) px)"])
        widthPopup.selectItem(at: GIFOptions.presetWidths.firstIndex(of: GIFOptions.standard.maxWidth ?? -1) ?? 1)

        let range = project.exportRange
        let rangeBox = NSButton(checkboxWithTitle: range.map { String(format: "範囲だけ書き出す(%.2f〜%.2f 秒)", $0.start, $0.end) } ?? "範囲だけ書き出す(範囲なし)",
                                target: nil, action: nil)
        rangeBox.state = range == nil ? .off : .on
        rangeBox.isEnabled = range != nil
        rangeBox.setAccessibilityIdentifier("gif-range-only")

        let row = NSStackView(views: [NSTextField(labelWithString: "速さ"), fpsPopup, NSTextField(labelWithString: "大きさ"), widthPopup])
        row.orientation = .horizontal
        row.spacing = 8
        let column = NSStackView(views: [row, rangeBox])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        panel.accessoryView = column

        let run: (NSApplication.ModalResponse) -> Void = { [weak self] resp in
            guard resp == .OK, let picked = panel.url, let self else { return }
            let url = picked.pathExtension.lowercased() == "gif" ? picked : picked.appendingPathExtension("gif")
            let options = GIFOptions(fps: fpsValues[max(0, fpsPopup.indexOfSelectedItem)],
                                     maxWidth: widthValues[max(0, widthPopup.indexOfSelectedItem)])
            let useRange = rangeBox.state == .on ? range : nil
            Task { @MainActor in
                if case .success(let done) = await self.runGIFExport(to: url, options: options, range: useRange) {
                    NSWorkspace.shared.activateFileViewerSelecting([done])
                }
            }
        }
        if let w = window { panel.beginSheetModal(for: w, completionHandler: run) } else { panel.begin(completionHandler: run) }
    }

    /// 書き出しシートを出して GIF を書く(MP4 と同じ進み具合・キャンセル・失敗の扱い)。
    func runGIFExport(to url: URL, options: GIFOptions = .standard, range: ExportRange? = nil) async -> ExportOutcome {
        guard !isExporting else { return .failure(ExportError.writerFailed(nil)) }
        if reportMissingMediaForExport() { return .failure(ExportError.writerFailed(nil)) }
        let snapshot = project
        let frames = GIFExporter.plan(project: snapshot, range: range, options: options).frames
        return await runJob(title: "GIF を書き出しています", fileName: url.lastPathComponent, notices: [],
                            success: "\(url.lastPathComponent) に \(frames) コマの GIF を書き出しました", result: url) { progress in
            try await GIFExporter.export(project: snapshot, range: range, options: options, to: url, progress: progress)
        }
    }
}
