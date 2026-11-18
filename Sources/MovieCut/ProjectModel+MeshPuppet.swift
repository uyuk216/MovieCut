import Foundation
import MovieCutCore

/// メッシュ変形・パペット変形(インスペクタの「メッシュ変形」「パペット変形」)。
/// 値は `Clip.meshWarp` / `Clip.puppetWarp`(省くと nil)。つまみのドラッグは 1 回の Undo。
extension ProjectModel {
    nonisolated static let warpUndoName = "変形の変更"

    // MARK: 離散的な変更(1 回の Undo)

    func ensureMeshWarp(clipId: String? = nil) {
        setClipProperty({ c in _ = WarpEditing.ensureMesh(&c) }, name: Self.warpUndoName, clipId: clipId)
    }

    func clearMeshWarp(clipId: String? = nil) {
        setClipProperty({ c in _ = WarpEditing.clearMesh(&c) }, name: Self.warpUndoName, clipId: clipId)
    }

    func setMeshGrid(cols: Int, rows: Int, clipId: String? = nil) {
        setClipProperty({ c in _ = WarpEditing.setMeshGrid(&c, cols: cols, rows: rows) }, name: Self.warpUndoName, clipId: clipId)
    }

    func resetMeshPoint(index: Int, clipId: String? = nil) {
        setClipProperty({ c in _ = WarpEditing.resetMeshPoint(&c, index: index) }, name: Self.warpUndoName, clipId: clipId)
    }

    func ensurePuppetWarp(clipId: String? = nil) {
        setClipProperty({ c in _ = WarpEditing.ensurePuppet(&c) }, name: Self.warpUndoName, clipId: clipId)
    }

    func clearPuppetWarp(clipId: String? = nil) {
        setClipProperty({ c in _ = WarpEditing.clearPuppet(&c) }, name: Self.warpUndoName, clipId: clipId)
    }

    func addPuppetPin(fixed: Bool, clipId: String? = nil) {
        setClipProperty({ c in _ = WarpEditing.addPin(&c, hx: 0.5, hy: 0.5, fixed: fixed) }, name: Self.warpUndoName, clipId: clipId)
    }

    func removePuppetPin(index: Int, clipId: String? = nil) {
        setClipProperty({ c in _ = WarpEditing.removePin(&c, index: index) }, name: Self.warpUndoName, clipId: clipId)
    }

    func setPuppetPinFixed(index: Int, _ fixed: Bool, clipId: String? = nil) {
        setClipProperty({ c in _ = WarpEditing.setPinFixed(&c, index: index, fixed) }, name: Self.warpUndoName, clipId: clipId)
    }

    // MARK: スライダーのドラッグ中(beginGesture 〜 commitGesture)。開始時のプロジェクトから毎回計算する

    private func liveWarp(clipId: String, _ change: (inout Clip) -> Void) {
        guard !isLocked, let c = clip(clipId) else { return }
        var p = gestureBase ?? project
        guard let loc = ClipEditing.locate(c.id, in: p) else { return }
        change(&p.tracks[loc.track].clips[loc.index])
        if gestureBase != nil { updateGesture(p) } else if p != project { edit(Self.warpUndoName) { $0 = p } }
    }

    func liveMeshPoint(clipId: String, index: Int, x: Double, y: Double) {
        liveWarp(clipId: clipId) { c in _ = WarpEditing.setMeshPoint(&c, index: index, x: x, y: y) }
    }

    func livePuppetPin(clipId: String, index: Int, x: Double, y: Double) {
        liveWarp(clipId: clipId) { c in _ = WarpEditing.movePin(&c, index: index, x: x, y: y) }
    }

    func livePuppetRadius(clipId: String, _ radius: Double) {
        liveWarp(clipId: clipId) { c in _ = WarpEditing.setPuppetRadius(&c, radius) }
    }
}
