import Foundation
import AppKit
import UniformTypeIdentifiers
import MovieCutCore

/// 出力 ▸ 書き出しキューに追加…(今の設定の MP4 を積む)。
extension ProjectModel {
    /// 保存先を選び、いまのプロジェクトの写しを書き出しキューの末尾に積む。書き出しは待たずに、編集を続けられる。
    /// 書き出し範囲が決まっていれば、その範囲だけ書き出す。欠けている素材があれば積まずに止める。
    func chooseAndQueueExport(queue: ExportQueueController? = nil) {
        guard canExport else { return }
        let queue = queue ?? AppServices.exportQueue
        if reportMissingMediaForExport() { return }
        let panel = NSSavePanel()
        let isProRes = OutputPlan.isProRes(project.codec)
        panel.allowedContentTypes = [isProRes ? .quickTimeMovie : .mpeg4Movie]
        panel.nameFieldStringValue = documentName + "." + OutputPlan.fileExtension(forCodec: project.codec)
        panel.canCreateDirectories = true
        panel.title = "書き出しキューに追加"
        let range = project.exportRange
        panel.message = range.map { String(format: "今の設定のまま、範囲 %.2f〜%.2f 秒を \(isProRes ? "ProRes の .mov" : "MP4") にしてキューの最後に積みます。", $0.start, $0.end) }
            ?? "今の設定のまま \(isProRes ? "ProRes の .mov" : "MP4") にして、キューの最後に積みます。"
        // 写しは保存先を選んだ時点で取る(パネルを開いている間の編集は含めない)
        let snapshot = project
        let run: (NSApplication.ModalResponse) -> Void = { [weak self] resp in
            guard resp == .OK, let url = panel.url, let self else { return }
            queue.enqueue(project: snapshot, range: range, to: url)
            self.statusText = "\(url.lastPathComponent) を書き出しキューに追加しました"
        }
        if let w = window { panel.beginSheetModal(for: w, completionHandler: run) } else { panel.begin(completionHandler: run) }
    }
}
