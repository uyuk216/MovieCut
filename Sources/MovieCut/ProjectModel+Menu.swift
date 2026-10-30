import Foundation
import AppKit
import UniformTypeIdentifiers
import MovieCutCore

/// 一度だけ出すお知らせの入れ物(キーごとに最初の 1 回だけ true を返す)。
final class OneTimeNotices {
    private var shown = Set<String>()
    func claim(_ key: String) -> Bool { shown.insert(key).inserted }
}

/// 声を作ったときに、AquesTalkPlayer の代わりに say(Kyoko)を使ったかを知らせる。
protocol VoiceFallbackReporting: AnyObject {
    var didUseFallback: Bool { get }
}

extension RealVoiceProvider: VoiceFallbackReporting {
    var didUseFallback: Bool { enginesUsed.contains("say") }
}

/// メニュー(M5)とツールバーが共有する操作。ロジックはここに 1 つだけ置く。
extension ProjectModel {
    static let kyokoWarning = "AquesTalkPlayer が見つからないので、macOS の Kyoko で代わりに読み上げます。"

    /// 書き出せる状態か(編集中でなく、中身がある)。
    var canExport: Bool { !isLocked && project.endTime > 0 }

    /// 設定シート(動画設定)を開く。
    func openSettings() { if !isLocked { showSettings = true } }

    /// 「現在の設定で書き出す…」/ 書き出しプリセット: 保存パネルで場所を選び、書き出し、終わったら Finder で見せる。
    /// プリセットはプロジェクトの写しに当てるので、ドキュメントは変わらない。保存パネルの提案名は `<書類名>-<プリセット>.mp4|.m4a`。
    func chooseAndExport(preset: ExportPreset? = nil) {
        guard canExport else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [preset?.isAudioOnly == true ? .mpeg4Audio : .mpeg4Movie]
        panel.nameFieldStringValue = exportSuggestedName(preset: preset)
        panel.canCreateDirectories = true
        panel.title = preset.map { "書き出し — \($0.title)" } ?? "MP4 書き出し"
        // 範囲があるときは「範囲だけ書き出す」(最初からオン)。
        let range = project.exportRange
        var rangeBox: NSButton?
        if range != nil {
            let box = NSButton(checkboxWithTitle: String(format: "範囲だけ書き出す(%.2f〜%.2f 秒)", range!.start, range!.end), target: nil, action: nil)
            box.state = .on
            box.setAccessibilityIdentifier("export-range-only")
            let wrap = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 32))
            box.frame = NSRect(x: 12, y: 6, width: 300, height: 20)
            wrap.addSubview(box)
            panel.accessoryView = wrap
            rangeBox = box
        }
        let run: (NSApplication.ModalResponse) -> Void = { [weak self] resp in
            guard resp == .OK, let url = panel.url, let self else { return }
            let useRange = rangeBox?.state == .on ? range : nil
            Task { @MainActor in
                if case .success(let u) = await self.runExport(to: url, preset: preset, range: useRange) {
                    NSWorkspace.shared.activateFileViewerSelecting([u])
                }
            }
        }
        if let w = window { panel.beginSheetModal(for: w, completionHandler: run) } else { panel.begin(completionHandler: run) }
    }

    /// 保存パネルが最初に出す名前。
    func exportSuggestedName(preset: ExportPreset?) -> String {
        preset?.suggestedFileName(documentName: documentName) ?? documentName + ".mp4"
    }

    /// フレームレート(メニューの定番・最近使ったカスタム・シート)。1〜240 の範囲外は断る。Undo は 1 回。
    func setFps(_ fps: Double) {
        guard !isLocked else { return }
        switch FrameRateInput.validated(fps) {
        case .failure(let e):
            errorTitle = "フレームレートを変えられません"; errorMessage = e.message
        case .success(let v):
            guard !FrameRate.same(v, project.fps) else { return }
            edit("FPS の変更") { $0.fps = v }
        }
    }

    /// 「フレームレートを入力」シートの適用。定番でないレートは「最近使ったカスタム」に残す。
    func applyCustomFps(_ fps: Double) {
        guard !isLocked else { return }
        setFps(fps)
        rememberCustomFps(fps)
    }

    func rememberCustomFps(_ fps: Double) {
        if !FrameRate.presets.contains(where: { FrameRate.same($0, fps) }) { RecentCustoms.frameRates().addRate(fps) }
        ActiveDocument.shared.refresh()
    }

    func openFpsSheet() { if !isLocked { showFpsSheet = true } }

    /// 書き出し形式(メニューの H.264 / HEVC)。Undo できる。
    func setCodec(_ codec: String) {
        guard ["h264", "hevc"].contains(codec), !isLocked else { return }
        edit("書き出し形式の変更") { $0.codec = codec }
    }

    /// 背景色(メニューの黒 / 白 / 緑)。Undo できる。
    func setBackground(_ hex: String) {
        guard !isLocked else { return }
        edit("背景色の変更") { $0.bg = hex }
    }

    /// タイムラインの拡大・縮小(factor 倍。範囲内に収める)。
    func zoomTimeline(by factor: Double) {
        pps = TimelineLayout.clampPps(pps * factor)
    }

    /// 「台本から音声を作る」: 左の台本欄の文字から作る。空なら案内だけ出す。
    func generateVoicesFromScript() async {
        guard !isLocked else { return }
        if scriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            statusText = "左の台本欄にセリフを書いてください"
            return
        }
        await generateVoices(from: scriptText)
    }

    /// AquesTalkPlayer の代わりに Kyoko を使ったら、この起動中に 1 回だけ知らせる。
    func noteFallbackIfUsed(_ provider: VoiceProvider) {
        guard let r = provider as? VoiceFallbackReporting, r.didUseFallback,
              (notices ?? AppServices.notices).claim("kyoko-fallback") else { return }
        errorTitle = "ゆっくり音声について"
        errorMessage = Self.kyokoWarning
    }
}
