import Foundation
import MovieCutCore

/// 形のマスク(インスペクタの「形のマスク」)。値は `Clip.mask`(省くと nil)。つまみのドラッグは 1 回の Undo。
extension ProjectModel {
    nonisolated static let maskUndoName = "マスクの変更"

    /// オン(既定のマスク)・オフ(nil に戻す)・形や反転などの離散的な変更。1 回の Undo。
    func setClipMask(_ mask: ClipMask?, clipId: String? = nil, name: String = ProjectModel.maskUndoName) {
        setClipProperty({ $0.mask = mask }, name: name, clipId: clipId)
    }

    /// 1 項目だけ変える(マスクが無ければ既定から作る)。
    func setMaskField(clipId: String, name: String = ProjectModel.maskUndoName, _ change: @escaping (inout ClipMask) -> Void) {
        setClipProperty({ c in
            var m = c.mask ?? ClipMask()
            change(&m)
            c.mask = m
        }, name: name, clipId: clipId)
    }

    /// スライダーのドラッグ中(`beginGesture` 〜 `commitGesture`)。ドラッグ開始時のプロジェクトから毎回計算するので、動かして戻すと元に戻る。
    func liveMaskField(clipId: String, _ change: @escaping (inout ClipMask) -> Void) {
        guard !isLocked, let c = clip(clipId) else { return }
        var p = gestureBase ?? project
        guard let loc = ClipEditing.locate(c.id, in: p) else { return }
        var m = p.tracks[loc.track].clips[loc.index].mask ?? ClipMask()
        change(&m)
        p.tracks[loc.track].clips[loc.index].mask = m
        if gestureBase != nil { updateGesture(p) } else if p != project { edit(Self.maskUndoName) { $0 = p } }
    }

    // MARK: ペンマスク(形 = pen のときの点の編集。どれも 1 回の Undo)

    /// 形の切り替え。ペンへ切り替えるときは、点が無ければ既定の菱形を用意する。
    func setMaskShape(_ shape: String, clipId: String) {
        setMaskField(clipId: clipId) { m in
            m.shape = shape
            if shape == "pen" { m.ensurePenPoints() }
        }
    }

    /// 点を追加する: 閉じる辺(最後の点 → 最初の点)の中点に新しい点を挟む。上限では何もしない。
    func addPenPoint(clipId: String) {
        setMaskField(clipId: clipId) { m in
            guard m.shape == "pen" else { return }
            m.ensurePenPoints()
            guard m.points.count < ClipMask.maxPoints, let a = m.points.last, let b = m.points.first else { return }
            m.points.append(MaskPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2))
        }
    }

    /// 辺の中点に点を挟む(プレビューの線の近くへの追加や、細かい形作り用)。
    func insertPenPoint(after index: Int, clipId: String) {
        setMaskField(clipId: clipId) { m in
            guard m.shape == "pen", m.points.indices.contains(index), m.points.count < ClipMask.maxPoints else { return }
            let a = m.points[index], b = m.points[(index + 1) % m.points.count]
            m.points.insert(MaskPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), at: index + 1)
        }
    }

    /// 点を削除する。3 点未満にはしない(面積が無くなるため)。
    func removePenPoint(index: Int, clipId: String) {
        setMaskField(clipId: clipId) { m in
            guard m.shape == "pen", m.points.count > 3, m.points.indices.contains(index) else { return }
            m.points.remove(at: index)
        }
    }

    /// 点のハンドルをアンカーへ戻す(まっすぐな角にする)。
    func resetPenHandles(index: Int, clipId: String) {
        setMaskField(clipId: clipId) { m in
            guard m.shape == "pen", m.points.indices.contains(index) else { return }
            let p = m.points[index]
            m.points[index] = MaskPoint(x: p.x, y: p.y)
        }
    }
}
