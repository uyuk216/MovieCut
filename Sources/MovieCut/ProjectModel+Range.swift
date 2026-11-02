import Foundation
import AppKit
import UniformTypeIdentifiers
import MovieCutCore

/// 書き出し範囲(イン/アウト)と、静止画・連番画像の書き出し(フェーズ C-1)。
extension ProjectModel {
    /// ルーラーの印がある(イン点かアウト点のどちらかが設定されている)。
    var hasRangeMarks: Bool { project.rangeIn != nil || project.rangeOut != nil }

    /// 範囲を指定できる状態(編集中でなく、中身がある)。
    var canMarkRange: Bool { !isLocked && project.endTime > 0 }

    /// 出力 ▸ 書き出し開始を現在位置に。変わらないとき・範囲が成り立たないときは何もしない(Undo に載せない)。
    @discardableResult
    func setRangeInAtCurrent() -> Bool { applyRange("書き出し開始の設定", ExportRangeEditing.settingIn(project, at: currentTime), refusal: "開始はアウト点より前にしてください") }

    /// 出力 ▸ 書き出し終了を現在位置に。
    @discardableResult
    func setRangeOutAtCurrent() -> Bool { applyRange("書き出し終了の設定", ExportRangeEditing.settingOut(project, at: currentTime), refusal: "終了はイン点より後にしてください") }

    /// 出力 ▸ 選んだクリップの頭から終わりまでを書き出し範囲にする(イン・アウトを一度に。1 回の Undo で戻る)。
    @discardableResult
    func setRangeFromSelection() -> Bool {
        guard let r = TimelineQuery.span(ofClipIds: selectedClipIDs, in: project) else { statusText = "クリップを選んでください"; return false }
        var p = project
        p.rangeIn = r.start
        p.rangeOut = r.end
        guard p != project else { return false }
        return applyRange("選択範囲を書き出し範囲に", p, refusal: "書き出し範囲を設定できません")
    }

    /// 出力 ▸ 範囲を解除。
    @discardableResult
    func clearExportRange() -> Bool {
        guard canMarkRange, hasRangeMarks else { return false }
        return edit("書き出し範囲の解除", enforcesLock: false) { $0 = ExportRangeEditing.clearing($0) }
    }

    /// ループ再生が効いている範囲(ループがオフ・範囲が無いときは nil)。
    var activeLoopRange: ExportRange? { trimLoop ?? (rangeLoop ? project.exportRange : nil) }

    // MARK: トリム点・選択クリップの反復再生(範囲ループの仕組みをそのまま使う)

    /// 再生ヘッドの前後 `TrimLoopSettings.halfWidth` 秒を反復再生する。反復中なら止める。
    func toggleTrimLoop() { toggleTransientLoop { TrimLoop.loopRange(playhead: self.currentTime, halfWidth: TrimLoopSettings.halfWidth, duration: self.project.endTime, clipRange: nil) } }

    /// 選択クリップの範囲を反復再生する。反復中なら止める。
    func toggleClipLoop() {
        toggleTransientLoop {
            guard let c = self.selectedClip else { return nil }
            return TrimLoop.loopRange(playhead: self.currentTime, halfWidth: TrimLoopSettings.halfWidth, duration: self.project.endTime,
                                      clipRange: ExportRange(start: c.start, end: c.start + c.duration))
        }
    }

    private func toggleTransientLoop(_ make: () -> ExportRange?) {
        if trimLoop != nil { playback.pause(); trimLoop = nil; return }   // 同じ項目でオフ
        guard !isLocked, let r = make() else { statusText = "反復再生できる範囲がありません"; return }
        if playback.isPlaying { playback.pause() }
        trimLoop = r
        currentTime = r.start
        playback.play()
    }

    private func applyRange(_ name: String, _ new: Project?, refusal: String) -> Bool {
        guard canMarkRange else { return false }
        guard let new else { statusText = refusal; return false }
        return edit(name, enforcesLock: false) { $0 = new }
    }

    // MARK: 静止画

    var stillSuggestedName: String { documentName }

    /// 出力 ▸ 現在のフレームを画像で書き出す…
    func chooseAndExportStill() {
        guard canExport else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.nameFieldStringValue = documentName + ".png"
        panel.canCreateDirectories = true
        panel.title = "現在のフレームを画像で書き出す(PNG / JPEG)"
        panel.message = "拡張子で形式が決まります(.png / .jpg)"
        let run: (NSApplication.ModalResponse) -> Void = { [weak self] resp in
            guard resp == .OK, let url = panel.url, let self else { return }
            Task { @MainActor in
                if self.exportStill(to: url) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        }
        if let w = window { panel.beginSheetModal(for: w, completionHandler: run) } else { panel.begin(completionHandler: run) }
    }

    /// 静止画・サムネイルに使う時刻(再生位置をコマに合わせ、終わりの外に出ないようにする)。
    var stillTime: Double {
        min(project.frameRate.snapped(currentTime), max(0, project.endTime - project.frameRate.frameDuration))
    }

    /// 今の再生位置のコマを `url` に書く(形式は拡張子。.jpg / .jpeg 以外は PNG)。
    @discardableResult
    func exportStill(to url: URL) -> Bool {
        guard canExport else { return false }
        let format = StillFormat(pathExtension: url.pathExtension) ?? .png
        do {
            try StillExporter.write(project: project, at: stillTime, format: format, to: url)
            statusText = "\(url.lastPathComponent) に書き出しました"
            return true
        } catch {
            statusText = "画像の書き出しに失敗しました"
            errorTitle = "書き出せませんでした"
            errorMessage = error.localizedDescription
            return false
        }
    }

    // MARK: 連番画像

    /// 出力 ▸ 連番画像を書き出す…(保存パネルで付けた名前のフォルダを作り、その中に `名前_00001.png` …)。
    func chooseAndExportSequence() {
        guard canExport else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = documentName
        panel.canCreateDirectories = true
        panel.title = "連番画像を書き出す"
        panel.message = "この名前のフォルダができて、中に 名前_00001.png … が入ります"
        let range = project.exportRange
        let format = NSPopUpButton(frame: .zero, pullsDown: false)
        format.addItems(withTitles: StillFormat.allCases.map(\.title))
        let rangeBox = NSButton(checkboxWithTitle: "範囲だけ書き出す", target: nil, action: nil)
        rangeBox.state = range == nil ? .off : .on
        rangeBox.isEnabled = range != nil
        let stack = NSStackView(views: [NSTextField(labelWithString: "形式"), format, rangeBox])
        stack.orientation = .horizontal; stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        panel.accessoryView = stack
        let run: (NSApplication.ModalResponse) -> Void = { [weak self] resp in
            guard resp == .OK, let url = panel.url, let self else { return }
            let fmt = StillFormat.allCases[max(0, format.indexOfSelectedItem)]
            let useRange = rangeBox.state == .on ? range : nil
            Task { @MainActor in
                let base = url.deletingPathExtension().lastPathComponent
                let dir = url.deletingPathExtension()
                if case .success(let d) = await self.runSequenceExport(to: dir, base: base, format: fmt, range: useRange) {
                    NSWorkspace.shared.activateFileViewerSelecting([d])
                }
            }
        }
        if let w = window { panel.beginSheetModal(for: w, completionHandler: run) } else { panel.begin(completionHandler: run) }
    }
}
