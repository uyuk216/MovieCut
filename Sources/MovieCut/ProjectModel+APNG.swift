import Foundation
import AppKit
import UniformTypeIdentifiers
import MovieCutCore

/// 出力 ▸ APNGとして書き出す…(アニメーション PNG。音は入らない。背景を「透明」にすると透明のまま残る)。
/// 描画は書き出し・プレビューと同じ `Renderer`。進み具合・キャンセル・完了の表示は MP4・GIF と同じ書き出しシート。
extension ProjectModel {
    /// 保存パネル(fps・幅・ループ回数・範囲を決める)→ 書き出し。
    func chooseAndExportAPNG() {
        guard canExport else { return }
        if reportMissingMediaForExport() { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = documentName + ".png"
        panel.canCreateDirectories = true
        panel.title = "APNG として書き出す"
        panel.message = project.hasTransparentBackground
            ? "背景が透明なので、透明のまま書き出します。音は入りません。"
            : "透明を残すには、出力 ▸ 背景色 ▸ 透明 にします。音は入りません。"

        let fpsValues = APNGOptions.presetFPS
        let fpsPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        fpsPopup.addItems(withTitles: fpsValues.map { "\(Int($0)) fps" })
        fpsPopup.selectItem(at: fpsValues.firstIndex(of: APNGOptions.standard.fps) ?? 1)

        // 最後の項目は「原寸」(幅を縮めない = nil)
        let widthValues: [Int?] = APNGOptions.presetWidths.map { $0 } + [nil]
        let widthPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        widthPopup.addItems(withTitles: APNGOptions.presetWidths.map { "幅 \($0) px" } + ["原寸(\(project.width) px)"])
        widthPopup.selectItem(at: APNGOptions.presetWidths.firstIndex(of: APNGOptions.standard.maxWidth ?? -1) ?? 1)

        let loopValues = APNGOptions.presetLoops
        let loopPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        loopPopup.addItems(withTitles: loopValues.map { $0 == 0 ? "くり返す: 無限" : "くり返す: \($0) 回" })
        loopPopup.selectItem(at: 0)

        let range = project.exportRange
        let rangeBox = NSButton(checkboxWithTitle: range.map { String(format: "範囲だけ書き出す(%.2f〜%.2f 秒)", $0.start, $0.end) } ?? "範囲だけ書き出す(範囲なし)",
                                target: nil, action: nil)
        rangeBox.state = range == nil ? .off : .on
        rangeBox.isEnabled = range != nil
        rangeBox.setAccessibilityIdentifier("apng-range-only")

        let row = NSStackView(views: [NSTextField(labelWithString: "速さ"), fpsPopup, NSTextField(labelWithString: "大きさ"), widthPopup, loopPopup])
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
            let url = picked.pathExtension.lowercased() == "png" ? picked : picked.appendingPathExtension("png")
            let options = APNGOptions(fps: fpsValues[max(0, fpsPopup.indexOfSelectedItem)],
                                      maxWidth: widthValues[max(0, widthPopup.indexOfSelectedItem)],
                                      loopCount: loopValues[max(0, loopPopup.indexOfSelectedItem)])
            let useRange = rangeBox.state == .on ? range : nil
            Task { @MainActor in
                if case .success(let done) = await self.runAPNGExport(to: url, options: options, range: useRange) {
                    NSWorkspace.shared.activateFileViewerSelecting([done])
                }
            }
        }
        if let w = window { panel.beginSheetModal(for: w, completionHandler: run) } else { panel.begin(completionHandler: run) }
    }

    /// 書き出しシートを出して APNG を書く(MP4・GIF と同じ進み具合・キャンセル・失敗の扱い)。
    func runAPNGExport(to url: URL, options: APNGOptions = .standard, range: ExportRange? = nil) async -> ExportOutcome {
        guard !directExportBlocked() else { return .failure(ExportError.writerFailed(nil)) }
        if reportMissingMediaForExport() { return .failure(ExportError.writerFailed(nil)) }
        let snapshot = project
        let frames = APNGExporter.plan(project: snapshot, range: range, options: options).frames
        return await runJob(title: "APNG を書き出しています", fileName: url.lastPathComponent, notices: [],
                            success: "\(url.lastPathComponent) に \(frames) コマの APNG を書き出しました", result: url) { progress in
            try await APNGExporter.export(project: snapshot, range: range, options: options, to: url, progress: progress)
        }
    }
}
