import AppKit
import UniformTypeIdentifiers
import MovieCutCore

/// B3: 字幕ファイル(SRT / VTT)の書き出し・読み込みと、チャプターのコピー。ロジックは Core(SubtitleFile / Chapters)にある。
extension ProjectModel {
    var canExportSubtitles: Bool { !SubtitleFile.cues(from: project).isEmpty }

    /// 出力 ▸ 字幕を書き出す…(保存パネルで .srt / .vtt を選ぶ)。
    func chooseAndExportSubtitles() {
        guard canExportSubtitles else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "srt"), UTType(filenameExtension: "vtt")].compactMap { $0 }
        panel.nameFieldStringValue = documentName + ".srt"
        panel.canCreateDirectories = true
        panel.title = "字幕を書き出す(拡張子 .srt か .vtt)"
        let run: (NSApplication.ModalResponse) -> Void = { [weak self] resp in
            guard resp == .OK, let url = panel.url, let self else { return }
            self.writeSubtitles(to: url)
        }
        if let w = window { panel.beginSheetModal(for: w, completionHandler: run) } else { panel.begin(completionHandler: run) }
    }

    /// 拡張子で形式を決めて書く(.vtt 以外は SRT)。
    @discardableResult
    func writeSubtitles(to url: URL) -> Bool {
        let fmt = SubtitleFormat(pathExtension: url.pathExtension) ?? .srt
        let cues = SubtitleFile.cues(from: project)
        guard !cues.isEmpty else { return false }
        do {
            try SubtitleFile.format(cues, as: fmt).write(to: url, atomically: true, encoding: .utf8)
            statusText = "字幕 \(cues.count) 件を書き出しました: \(url.lastPathComponent)"
            return true
        } catch {
            statusText = "字幕を書き出せませんでした: \(error.localizedDescription)"
            return false
        }
    }

    /// ファイル ▸ 字幕を読み込む…(開くパネル → ずらす秒数の確認)。
    func chooseAndImportSubtitles() {
        guard !isLocked else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "srt"), UTType(filenameExtension: "vtt")].compactMap { $0 }
        panel.title = "字幕を読み込む"
        let run: (NSApplication.ModalResponse) -> Void = { [weak self] resp in
            guard resp == .OK, let url = panel.url, let self else { return }
            Task { @MainActor in
                guard let offset = self.askSubtitleOffset() else { return }
                self.importSubtitles(from: url, offset: offset)
            }
        }
        if let w = window { panel.beginSheetModal(for: w, completionHandler: run) } else { panel.begin(completionHandler: run) }
    }

    /// 「全体を何秒ずらすか」を聞く小さな確認(キャンセルは nil)。
    private func askSubtitleOffset() -> Double? {
        let alert = NSAlert()
        alert.messageText = "字幕を読み込む"
        alert.informativeText = "字幕の時刻を何秒ずらしますか(0 でそのまま。マイナスで早く)。"
        let field = NSTextField(string: "0")
        field.frame = NSRect(x: 0, y: 0, width: 120, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "読み込む")
        alert.addButton(withTitle: "キャンセル")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let s = field.stringValue.trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? 0 : (Double(s) ?? 0)
    }

    /// 字幕ファイルを読んで「字幕」レイヤーに文字クリップとして足す。Undo は 1 回。
    @discardableResult
    func importSubtitles(from url: URL, offset: Double) -> Bool {
        guard !isLocked else { return false }
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else {
            statusText = "字幕ファイルを読めませんでした: \(url.lastPathComponent)"
            return false
        }
        return importSubtitles(cues: SubtitleFile.parse(text), offset: offset)
    }

    @discardableResult
    func importSubtitles(cues: [SubtitleCue], offset: Double) -> Bool {
        guard !isLocked else { return false }
        guard let r = SubtitleImport.apply(cues, to: project, offset: offset) else {
            statusText = "読み込める字幕がありませんでした"
            return false
        }
        edit("字幕の読み込み") { $0 = r.project }
        statusText = "字幕 \(r.clipIds.count) 件を読み込みました"
        return true
    }

    /// 出力 ▸ チャプターをコピー: YouTube の説明欄に貼る行をクリップボードへ。注意があれば状態欄に出す。
    @discardableResult
    func copyChapters() -> Bool {
        let r = Chapters.make(from: project.markers)
        guard r.count > 0 else { statusText = r.warnings.first ?? "マーカーがありません"; return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(r.text, forType: .string)
        statusText = "チャプター \(r.count) 件をコピーしました" + (r.warnings.isEmpty ? "" : "。注意: " + r.warnings.joined(separator: " / "))
        return true
    }
}
