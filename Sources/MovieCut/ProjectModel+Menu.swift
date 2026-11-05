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
    func chooseAndExport(preset: ExportPreset? = nil, spec: ExportSpec? = nil) {
        guard canExport else { return }
        // 欠けている素材があれば、保存パネルを出す前に止める
        if reportMissingMediaForExport() { return }
        let initial: ExportChoice = spec.map { .custom($0) } ?? preset.map { .builtin($0) } ?? .current
        let customs = CustomExportPresetStore.load(from: CustomExportPresetStore.defaultURL()).map(\.spec)
        let options = ExportPanelOptions(documentName: documentName, initial: initial, custom: customs, projectCodec: project.codec)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [options.contentType(for: initial)]
        panel.nameFieldStringValue = exportSuggestedName(preset: preset, spec: spec)
        panel.canCreateDirectories = true
        panel.title = initial.spec.map { "書き出し — \($0.name)" } ?? (OutputPlan.isProRes(project.codec) ? "\(OutputPlan.codecLabel(project.codec)) 書き出し" : "MP4 書き出し")
        options.panel = panel
        // 範囲があるときは「範囲だけ書き出す」(最初からオン)。
        let range = project.exportRange
        var rangeBox: NSButton?
        if range != nil {
            let box = NSButton(checkboxWithTitle: String(format: "範囲だけ書き出す(%.2f〜%.2f 秒)", range!.start, range!.end), target: nil, action: nil)
            box.state = .on
            box.setAccessibilityIdentifier("export-range-only")
            rangeBox = box
        }
        panel.accessoryView = options.accessoryView(rangeBox: rangeBox)
        let run: (NSApplication.ModalResponse) -> Void = { [weak self] resp in
            guard resp == .OK, let url = panel.url, let self else { return }
            let useRange = rangeBox?.state == .on ? range : nil
            let choice = options.selectedChoice
            let bitrate = options.selectedBitrate
            Task { @MainActor in
                if case .success(let u) = await self.runExport(to: url, preset: choice.preset, spec: choice.spec, bitrateMbps: bitrate, range: useRange) {
                    NSWorkspace.shared.activateFileViewerSelecting([u])
                }
            }
        }
        if let w = window { panel.beginSheetModal(for: w, completionHandler: run) } else { panel.begin(completionHandler: run) }
    }

    /// 現在の設定(解像度・コーデック・fps)を名前を付けて保存したプリセットにする。同じ名前は置き換える。
    func saveCurrentAsCustomPreset() {
        guard !isLocked else { return }
        let alert = NSAlert()
        alert.messageText = "プリセットとして保存"
        alert.informativeText = "\(project.width)×\(project.height) · \(project.codec == "hevc" ? "HEVC" : "H.264") · \(FrameRate.label(project.fps)) fps を、名前を付けて保存します。"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "例: 縦動画 8 Mbps"
        alert.accessoryView = field
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "キャンセル")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard CustomExportPreset.isValidName(name) else {
            errorTitle = "プリセットを保存できません"; errorMessage = "名前は 1〜40 文字で、/ : \\ は使えません。組み込みと同じ名前も使えません。"
            return
        }
        guard CustomExportPreset.isValidSide(project.width), CustomExportPreset.isValidSide(project.height) else {
            errorTitle = "プリセットを保存できません"; errorMessage = "解像度が保存できる範囲(16〜7680 の偶数)ではありません。"
            return
        }
        let url = CustomExportPresetStore.defaultURL()
        let current = CustomExportPresetStore.load(from: url)
        let preset = CustomExportPreset(name: name, width: project.width, height: project.height, codec: project.codec == "hevc" ? "hevc" : "h264", fps: project.fps)
        guard let merged = CustomExportPresetStore.upserting(preset, into: current), let url else {
            errorTitle = "プリセットを保存できません"; errorMessage = "保存できるプリセットは \(CustomExportPreset.maxCount) 件までです。"
            return
        }
        do { try CustomExportPresetStore.save(merged, to: url) } catch {
            errorTitle = "プリセットを保存できません"; errorMessage = error.localizedDescription
        }
    }

    /// 保存パネルが最初に出す名前。
    func exportSuggestedName(preset: ExportPreset?, spec: ExportSpec? = nil) -> String {
        (spec ?? preset?.spec)?.suggestedFileName(documentName: documentName) ?? documentName + "." + OutputPlan.fileExtension(forCodec: project.codec)
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

    /// 書き出し形式(メニューの H.264 / HEVC / ProRes 422 / ProRes 4444)。Undo できる。
    func setCodec(_ codec: String) {
        guard ["h264", "hevc", OutputPlan.proRes422, OutputPlan.proRes4444].contains(codec), !isLocked else { return }
        edit("書き出し形式の変更") { $0.codec = codec }
    }

    /// 背景色(メニューの黒 / 白 / 緑 / 透明)。Undo できる。
    func setBackground(_ hex: String) {
        guard !isLocked else { return }
        edit("背景色の変更") { $0.bg = hex }
    }

    /// タイムラインの拡大・縮小(factor 倍。範囲内に収める)。
    func zoomTimeline(by factor: Double) {
        pps = TimelineLayout.clampPps(pps * factor)
    }

    /// 台本で使われている表情タグのうち、表情の画像が無いもの(「キャラ名: 表情名」)。台本欄の下に赤く出す。
    var scriptMissingExpressions: [String] {
        CharacterPartCheck.missingInScript(scriptText, characters: project.characters) { FileManager.default.fileExists(atPath: $0) }
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
