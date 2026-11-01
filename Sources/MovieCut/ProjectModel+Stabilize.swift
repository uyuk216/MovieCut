import Foundation
import MovieCutCore

/// 手ぶれ補正(メニュー ▸ クリップ ▸ 手ぶれ補正)。計算は MovieCutCore(`Stabilizer`)、ここは Undo(1 操作 = 1 回)と選択だけ。
extension ProjectModel {
    /// メニューの切り替え。選んでいる映像クリップの手ぶれ補正をオン/オフする(1 回の Undo)。値が変わらなければ何もしない。
    @discardableResult
    func toggleStabilizeSelected() -> Bool {
        guard !isLocked, let c = selectedClip, StabilizeEditing.supports(c) else { return false }
        var probe = c
        guard StabilizeEditing.toggle(&probe) else { return false }
        setClipProperty({ _ = StabilizeEditing.toggle(&$0) },
                        name: c.stabilizeStrength > 0 ? "手ぶれ補正をオフ" : "手ぶれ補正をオン", clipId: c.id)
        return true
    }
}
