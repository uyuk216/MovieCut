import Foundation
import MovieCutCore

/// ぼかし範囲(背景ぼかし)の絞りぼかしの形。ロジックは MovieCutCore の `ApertureShape` / `Bokeh`。
extension ProjectModel {
    /// 絞りの形を変える(ぼかし範囲のクリップだけ。円はファイルに書かない)。変わらなければ何もしない。1 回の Undo。
    @discardableResult
    func setBokehShape(_ shape: ApertureShape, clipId: String) -> Bool {
        guard !isLocked, let c = clip(clipId), c.type == .blur, c.bokehShapeOrDefault != shape else { return false }
        setClipProperty({ $0.bokehShape = shape == .circle ? nil : shape.name }, name: "絞りの形の変更", clipId: c.id)
        return true
    }
}
