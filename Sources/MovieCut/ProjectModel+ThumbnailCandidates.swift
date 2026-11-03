import Foundation
import AppKit
import MovieCutCore

/// 出力 ▸ サムネイル候補を書き出す…: 選んでいる動画クリップ(無ければ全体)から、鮮明さ・明るさ・顔で点数の高いコマを選んで、
/// 選んだフォルダに PNG で書く。プロジェクトは変えない(Undo の対象外)。
extension ProjectModel {
    static let thumbnailCandidateCount = ThumbnailScoring.defaultCount

    /// 調べる範囲: 動画クリップを選んでいればその範囲、そうでなければ全体。
    var thumbnailCandidateRange: (start: Double, duration: Double) {
        if let c = selectedClip, c.type == .video, c.duration > 0 { return (c.start, c.duration) }
        return (0, project.endTime)
    }

    func chooseAndExportThumbnailCandidates() {
        guard canExport else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "サムネイル候補の書き出し先"
        panel.message = "点数の高いコマを \(Self.thumbnailCandidateCount) 枚、1280×720 の PNG で書き出します"
        panel.prompt = "書き出す"
        let run: (NSApplication.ModalResponse) -> Void = { [weak self] resp in
            guard resp == .OK, let url = panel.url, let self else { return }
            Task { @MainActor in
                if self.exportThumbnailCandidates(to: url) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        }
        if let w = window { panel.beginSheetModal(for: w, completionHandler: run) } else { panel.begin(completionHandler: run) }
    }

    /// 候補を選んで `folder` に書く。1 枚も選べなければ何も書かず false。
    @discardableResult
    func exportThumbnailCandidates(to folder: URL, detector: FaceDetecting = VisionFaceDetector()) -> Bool {
        guard canExport else { return false }
        let range = thumbnailCandidateRange
        let found = ThumbnailCandidateFinder.find(project: project, start: range.start, duration: range.duration,
                                                  count: Self.thumbnailCandidateCount, detector: detector)
        guard !found.isEmpty else {
            statusText = "サムネイルの候補が見つかりませんでした"
            return false
        }
        do {
            let urls = try ThumbnailCandidateFinder.write(found, project: project, baseName: documentName, to: folder)
            statusText = "サムネイル候補 \(urls.count) 枚を \(folder.lastPathComponent) に書き出しました"
            return true
        } catch {
            statusText = "サムネイル候補の書き出しに失敗しました"
            errorTitle = "書き出せませんでした"
            errorMessage = error.localizedDescription
            return false
        }
    }
}
