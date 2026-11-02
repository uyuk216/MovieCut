import Foundation
import CoreGraphics
import MovieCutCore

/// プレビュー上で重なったクリップを選ぶ(⌥ クリックで手前から奥へ巡回)。ロジックは MovieCutCore の `PreviewPicking`。選択だけで、Undo には載らない。
extension ProjectModel {
    /// ⌥ クリック: キャンバスの画素 `point` に重なるクリップを巡回して 1 つ選ぶ(選んでいるクリップが重なりの中にあれば、その次)。
    /// 何も重なっていなければ選択は変えず false。
    @discardableResult
    func pickPreviewClip(atCanvasPoint point: CGPoint) -> Bool {
        guard !isLocked else { return false }
        let ids = PreviewPicking.hits(in: project, at: point, time: currentTime, assets: assets)
        guard let id = PreviewPicking.next(after: selectedClipId, in: ids) else { return false }
        selectOnly(id)
        statusText = ids.count > 1 ? "重なったクリップを選択(\((ids.firstIndex(of: id) ?? 0) + 1)/\(ids.count)。⌥ クリックで次へ)" : "クリップを選択"
        return true
    }

    /// クリップ ▸ 再生位置の重なったクリップを巡回選択(座標なし。画面に見えているクリップを、手前から奥へ)。
    @discardableResult
    func cycleOverlappingAtPlayhead() -> Bool {
        guard !isLocked else { return false }
        let ids = Array(PreviewPicking.stack(in: project, at: currentTime).reversed())
        guard ids.count >= 2, let id = PreviewPicking.next(after: selectedClipId, in: ids) else { return false }
        selectOnly(id)
        statusText = "重なったクリップを選択(\((ids.firstIndex(of: id) ?? 0) + 1)/\(ids.count))"
        return true
    }
}
