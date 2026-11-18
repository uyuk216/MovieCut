import Foundation
import AppKit
import UniformTypeIdentifiers
import MovieCutCore

/// 出力 ▸ 連番PNG+WAVで書き出す…(W3-25 / 監査 #70)/ exo形式(.exo)で書き出す…(W3-26 / 監査 #71)。
/// どちらも追加方式で、既存の書き出し形式の挙動は変えない。
extension ProjectModel {

    // MARK: 連番 PNG + WAV

    /// 保存先フォルダを選んで、連番 PNG(`<名前>_000001.png` …)+ WAV(`<名前>.wav`)を書き出す。
    func chooseAndExportPngWav() {
        guard canExport else { return }
        if reportMissingMediaForExport() { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.title = "連番PNG+WAVで書き出す"
        panel.message = "選んだフォルダの中に \(documentName)_000001.png … と \(documentName).wav が入ります(fps はプロジェクト設定どおり)。"
        panel.prompt = "ここに書き出す"
        let range = project.exportRange
        let rangeBox = NSButton(checkboxWithTitle: range.map { String(format: "範囲だけ書き出す(%.2f〜%.2f 秒)", $0.start, $0.end) } ?? "範囲だけ書き出す(範囲なし)",
                                target: nil, action: nil)
        rangeBox.state = range == nil ? .off : .on
        rangeBox.isEnabled = range != nil
        rangeBox.setAccessibilityIdentifier("pngwav-range-only")
        let column = NSStackView(views: [rangeBox])
        column.orientation = .vertical
        column.alignment = .leading
        column.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        panel.accessoryView = column

        let run: (NSApplication.ModalResponse) -> Void = { [weak self] resp in
            guard resp == .OK, let dir = panel.url, let self else { return }
            let useRange = rangeBox.state == .on ? range : nil
            Task { @MainActor in
                if case .success(let done) = await self.runPngWavExport(to: dir, base: self.documentName, range: useRange) {
                    NSWorkspace.shared.activateFileViewerSelecting([done])
                }
            }
        }
        if let w = window { panel.beginSheetModal(for: w, completionHandler: run) } else { panel.begin(completionHandler: run) }
    }

    /// 書き出しシートを出して連番 PNG + WAV を書く(MP4 と同じ進み具合・キャンセル・失敗の扱い)。
    func runPngWavExport(to directory: URL, base: String, range: ExportRange? = nil,
                         loudness: LoudnessNormalizationSettings = .disabled) async -> ExportOutcome {
        guard !directExportBlocked() else { return .failure(ExportError.writerFailed(nil)) }
        if reportMissingMediaForExport() { return .failure(ExportError.writerFailed(nil)) }
        let snapshot = project
        let options = PngWavOptions(base: base, loudness: loudness)
        let plan = PngWavExporter.plan(project: snapshot, range: range, options: options)
        return await runJob(title: "連番PNG+WAV を書き出しています", fileName: directory.lastPathComponent, notices: [],
                            success: "\(directory.lastPathComponent) に \(plan.frameCount) 枚の PNG と WAV を書き出しました", result: directory) { progress in
            try await PngWavExporter.export(project: snapshot, range: range, options: options, to: directory, progress: progress)
        }
    }

    // MARK: exo

    /// 保存パネルで保存先を選び、AviUtl 拡張編集用の .exo を書く。対応できない要素はレポートで必ず見せる(ymmp と同じ流儀)。
    func chooseAndExportExo() {
        guard canExport else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "exo") ?? .data]
        panel.nameFieldStringValue = documentName + ".exo"
        panel.canCreateDirectories = true
        panel.title = "exo 形式(.exo)で書き出す"
        panel.message = "AviUtl の拡張編集プラグインで開けるプロジェクトファイルとして書き出します。対応できない要素は、書き出し後に一覧でお知らせします(実 AviUtl での読み込みは未検証です)。"

        let run: (NSApplication.ModalResponse) -> Void = { [weak self] resp in
            guard resp == .OK, let picked = panel.url, let self else { return }
            let url = picked.pathExtension.lowercased() == "exo" ? picked : picked.appendingPathExtension("exo")
            do {
                let report = try ExoExporter.write(project: self.project, to: url)
                NSWorkspace.shared.activateFileViewerSelecting([url])
                let alert = NSAlert()
                alert.messageText = "exo 形式で書き出しました"
                if report.hasLoss {
                    alert.alertStyle = .warning
                    alert.informativeText = report.summaryLines.joined(separator: "\n")
                } else {
                    alert.informativeText = "書き出し: \(report.convertedCount) 件\n" + report.notes.map { "注記: \($0)" }.joined(separator: "\n")
                }
                alert.addButton(withTitle: "OK")
                if let w = self.window { alert.beginSheetModal(for: w) } else { alert.runModal() }
            } catch {
                let alert = NSAlert(error: error)
                if let w = self.window { alert.beginSheetModal(for: w) } else { alert.runModal() }
            }
        }
        if let w = window { panel.beginSheetModal(for: w, completionHandler: run) } else { panel.begin(completionHandler: run) }
    }
}
