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
        addPuppetPin(fixed: fixed, atX: 0.5, atY: 0.5, clipId: clipId)
    }

    /// ピンを任意の位置(割合・左上原点)に打つ。パペット変形が無ければ用意するところから 1 回の Undo。
    func addPuppetPin(fixed: Bool, atX hx: Double, atY hy: Double, clipId: String? = nil) {
        setClipProperty({ c in
            _ = WarpEditing.ensurePuppet(&c)
            _ = WarpEditing.addPin(&c, hx: hx, hy: hy, fixed: fixed)
        }, name: Self.warpUndoName, clipId: clipId)
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

    /// スライダー・プレビューのドラッグ用: その座標にキーがあれば再生ヘッドのキーを書き、無ければ静的な値を書く。
    func liveMeshPoint(clipId: String, index: Int, x: Double, y: Double) {
        let tol = keyTolerance
        liveWarp(clipId: clipId) { c in _ = WarpEditing.setMeshPointKeyed(&c, index: index, x: x, y: y, at: min(max(currentTime - c.start, 0), c.duration), tolerance: tol) }
    }

    /// 1 座標だけの版(横/縦スライダー用。もう一方の座標にキーがあっても触らない)。
    func liveMeshAxis(clipId: String, index: Int, axis: WarpKey.Axis, _ v: Double) {
        let tol = keyTolerance
        liveWarp(clipId: clipId) { c in _ = WarpEditing.setMeshAxisKeyed(&c, index: index, axis: axis, v, at: min(max(currentTime - c.start, 0), c.duration), tolerance: tol) }
    }

    func livePuppetPin(clipId: String, index: Int, x: Double, y: Double) {
        let tol = keyTolerance
        liveWarp(clipId: clipId) { c in _ = WarpEditing.movePinKeyed(&c, index: index, x: x, y: y, at: min(max(currentTime - c.start, 0), c.duration), tolerance: tol) }
    }

    func livePuppetAxis(clipId: String, index: Int, axis: WarpKey.Axis, _ v: Double) {
        let tol = keyTolerance
        liveWarp(clipId: clipId) { c in _ = WarpEditing.movePinAxisKeyed(&c, index: index, axis: axis, v, at: min(max(currentTime - c.start, 0), c.duration), tolerance: tol) }
    }

    func livePuppetRadius(clipId: String, _ radius: Double) {
        liveWarp(clipId: clipId) { c in _ = WarpEditing.setPuppetRadius(&c, radius) }
    }
}
