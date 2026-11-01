import Foundation
import MovieCutCore

/// クリップ ▸ 配置 ▸ 右上に小さく など(ピクチャー・イン・ピクチャー)。既存の位置・拡大を書く。1 回の Undo。
extension ProjectModel {
    /// 選んだクリップ(無ければ `clipId`)を角に小さく置く。変わらないときは何もせず false。
    @discardableResult
    func setPipCorner(_ corner: PipCorner, clipId: String? = nil) -> Bool {
        guard !isLocked, let id = clipId ?? selectedClipId, let c = clip(id), PictureInPicture.supports(c.type) else { return false }
        let aspect = Double(project.width) / Double(max(project.height, 1))
        var probe = c
        guard PictureInPicture.apply(&probe, corner: corner, canvasAspect: aspect) else { return false }
        setClipProperty({ _ = PictureInPicture.apply(&$0, corner: corner, canvasAspect: aspect) }, name: corner.label, clipId: c.id)
        if Animation.isAnimated("x", in: c) || Animation.isAnimated("y", in: c) || Animation.isAnimated("scale", in: c) {
            statusText = "位置・拡大にキーフレームがあるため、そのキーの値が優先されます"
        }
        return true
    }
}
