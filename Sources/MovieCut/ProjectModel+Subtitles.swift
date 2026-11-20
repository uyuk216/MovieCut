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
        panel.allowedContentTypes = [UTType(filenameExtension: "srt"), UTType(filenameExtension: "vtt"), UTType(filenameExtension: "scc"), UTType(filenameExtension: "stl")].compactMap { $0 }
        panel.nameFieldStringValue = documentName + ".srt"
        panel.canCreateDirectories = true
        panel.title = L10n.t("字幕を書き出す(拡張子 .srt / .vtt / .scc / .stl)")
        let run: (NSApplication.ModalResponse) -> Void = { [weak self] resp in
            guard resp == .OK, let url = panel.url, let self else { return }
            self.writeSubtitles(to: url)
        }
        FilePanelPresenter.shared.present(panel, window: window, completion: run)
    }

    /// 拡張子で形式を決めて書く(.vtt 以外は SRT)。
    @discardableResult
    func writeSubtitles(to url: URL) -> Bool {
        let cues = SubtitleFile.cues(from: project)
        guard !cues.isEmpty else { return false }
        do {
            // 放送・配信用形式(.scc / .stl)は拡張子で分ける。それ以外は従来どおり SRT / VTT。
            let warnings: [String]
            switch url.pathExtension.lowercased() {
            case "scc":
                let r = SCCExporter.export(cues)
                try r.text.write(to: url, atomically: true, encoding: .utf8)
                warnings = r.warnings
            case "stl":
                let r = EBUSTLExporter.export(cues, options: EBUSTLOptions(frameRate: project.fps < 27.5 ? .fps25 : .fps30, programmeTitle: documentName))
                try r.data.write(to: url, options: .atomic)
                warnings = r.warnings
            default:
                let fmt = SubtitleFormat(pathExtension: url.pathExtension) ?? .srt
                try SubtitleFile.format(cues, as: fmt).write(to: url, atomically: true, encoding: .utf8)
                warnings = []
            }
            statusText = String(format: L10n.t("字幕 %d 件を書き出しました: %@"), cues.count, url.lastPathComponent) + (warnings.isEmpty ? "" : String(format: L10n.t("。注意: %@"), warnings.joined(separator: " / ")))
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
        panel.title = L10n.t("字幕を読み込む")
        let run: (NSApplication.ModalResponse) -> Void = { [weak self] resp in
            guard resp == .OK, let url = panel.url, let self else { return }
            Task { @MainActor in
                guard let offset = self.askSubtitleOffset() else { return }
                self.importSubtitles(from: url, offset: offset)
            }
        }
        FilePanelPresenter.shared.present(panel, window: window, completion: run)
    }

    /// 「全体を何秒ずらすか」を聞く小さな確認(キャンセルは nil)。
    private func askSubtitleOffset() -> Double? {
        let alert = NSAlert()
        alert.messageText = L10n.t("字幕を読み込む")
        alert.informativeText = L10n.t("字幕の時刻を何秒ずらしますか(0 でそのまま。マイナスで早く)。")
        let field = NSTextField(string: "0")
        field.frame = NSRect(x: 0, y: 0, width: 120, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: L10n.t("読み込む"))
        alert.addButton(withTitle: L10n.t("キャンセル"))
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let s = field.stringValue.trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? 0 : (Double(s) ?? 0)
    }

    /// 字幕ファイルを読んで「字幕」レイヤーに文字クリップとして足す。Undo は 1 回。
    @discardableResult
    func importSubtitles(from url: URL, offset: Double) -> Bool {
        guard !isLocked else { return false }
        let cues: [SubtitleCue]
        do {
            guard let c = try SubtitleFile.read(url) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
            cues = c
        } catch {
            statusText = "字幕ファイルを読めませんでした: \(url.lastPathComponent)(\(error.localizedDescription))"
            return false
        }
        return importSubtitles(cues: cues, offset: offset)
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

    /// 出力 ▸ 字幕を自動生成: 台本(ボイス)の文字から字幕の文字クリップを作る。見た目は組み込みの「ゆっくり風」。Undo は 1 回。
    @discardableResult
    func generateSubtitlesFromScript() -> Bool {
        guard !isLocked else { return false }
        let style = TextStyleLibrary.builtins.first { $0.id == "builtin.classic" }?.look
        guard let r = SubtitleGeneration.generate(project, style: style) else {
            statusText = "字幕にするセリフがありません(字幕オフのセリフや、ロック・非表示のレイヤーは対象外)"
            return false
        }
        edit("字幕の自動生成") { $0 = r.project }
        statusText = "字幕 \(r.count) 件を作りました。元のセリフの字幕表示は切りました"
        return true
    }

    /// 出力 ▸ チャプターをコピー: YouTube の説明欄に貼る行をクリップボードへ。注意があれば状態欄に出す。
    @discardableResult
    func copyChapters(color: MarkerColor? = nil) -> Bool {
        let r = Chapters.make(from: project.markers, color: color)
        guard r.count > 0 else { statusText = r.warnings.first ?? "マーカーがありません"; return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(r.text, forType: .string)
        statusText = (color.map { String(format: L10n.t("%@のマーカーから "), L10n.t($0.title)) } ?? "") + String(format: L10n.t("チャプター %d 件をコピーしました"), r.count) + (r.warnings.isEmpty ? "" : String(format: L10n.t("。注意: %@"), r.warnings.joined(separator: " / ")))
        return true
    }
}
