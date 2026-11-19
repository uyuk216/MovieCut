import Foundation
import MovieCutCore

/// Paper Edit: 文字起こしで選んだ文(並び順つき)からクリップ列を組み立てて配置する。
/// 組み立ての計算は Core(`PaperEdit`)。ここは Undo(1 回)・選択・状態欄だけ。元クリップは変えない。
extension ProjectModel {
    static let paperEditUndoName = "ペーパーエディット"

    /// 選んだ文を組み立てて配置する(全体で 1 回の Undo)。選択が空・組み立てられないときは何もしない(false)。
    /// 配置先は呼び出し側が決める(タイムラインの末尾 / 新しいシーン)。
    @discardableResult
    func assemblePaperEdit(clipId: String, sentences: [TranscriptSentence], order: [Int],
                           destination: PaperEdit.Destination) -> Bool {
        guard !isLocked, !order.isEmpty else { return false }
        guard let r = PaperEdit.assemble(in: project, sourceClipId: clipId, sentences: sentences,
                                         order: order, destination: destination) else {
            statusText = "Paper Editで組み立てられませんでした(配置先が埋まっている・ロックされている等)"
            return false
        }
        guard edit(Self.paperEditUndoName, { $0 = r.project }) else { return false }
        selectedClipId = r.clipIds.first
        if let sceneId = r.sceneId, let name = r.project.scene(withId: sceneId)?.name {
            statusText = "Paper Edit: \(order.count) 文を新しいシーン「\(name)」に組み立てました(1 回で元に戻せます)"
        } else {
            statusText = "Paper Edit: \(order.count) 文を組み立てました(1 回で元に戻せます)"
        }
        return true
    }
}
