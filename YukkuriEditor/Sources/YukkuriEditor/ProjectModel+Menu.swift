import Foundation
import AppKit
import UniformTypeIdentifiers
import YukkuriCore

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

    /// 「MP4 を書き出す…」: 保存パネルで場所を選び、書き出し、終わったら Finder で見せる。
    func chooseAndExport() {
        guard canExport else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = documentName + ".mp4"
        panel.canCreateDirectories = true
        panel.title = "MP4 書き出し"
        let run: (NSApplication.ModalResponse) -> Void = { [weak self] resp in
            guard resp == .OK, let url = panel.url, let self else { return }
            Task { @MainActor in
                if case .success(let u) = await self.runExport(to: url) {
                    NSWorkspace.shared.activateFileViewerSelecting([u])
                }
            }
        }
        if let w = window { panel.beginSheetModal(for: w, completionHandler: run) } else { panel.begin(completionHandler: run) }
    }

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
