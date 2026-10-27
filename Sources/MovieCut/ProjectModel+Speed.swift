import Foundation
import AppKit
import MovieCutCore

/// 速度・逆再生・フリーズフレーム(インスペクタ・メニューが呼ぶ)。計算は MovieCutCore の SpeedEditing / ClipTiming に任せ、
/// ここは Undo(1 操作 = 1 回)・選択・状態表示だけ。何も変わらない操作は Undo に積まない。
extension ProjectModel {
    static let speedUndoName = "速度の変更"

    private func speedTarget(_ clipId: String?) -> Clip? {
        guard !isLocked, let id = clipId ?? selectedClipId, let c = clip(id), SpeedEditing.supports(c) else { return nil }
        return c
    }

    /// 速度を決める(メニュー・数値欄の確定・プリセットの Picker)。
    @discardableResult
    func setSpeed(_ v: Double, clipId: String? = nil) -> Bool {
        guard let c = speedTarget(clipId), let p = SpeedEditing.settingSpeed(in: project, clipId: c.id, v) else { return false }
        flushCoalesced()
        edit(Self.speedUndoName) { $0 = p }
        return true
    }

    /// メニュー「クリップ ▸ 速度 ▸ ○倍」。
    @discardableResult
    func setSpeedSelected(_ v: Double) -> Bool { setSpeed(v) }

    /// スライダーのドラッグ中(`beginGesture` 〜 `commitGesture` の間)。ドラッグ開始時のプロジェクトから毎回計算するので、動かして戻すとぴったり元に戻る。
    func liveSpeed(_ v: Double, clipId: String) {
        guard let c = speedTarget(clipId) else { return }
        let base = gestureBase ?? project
        guard let p = SpeedEditing.settingSpeed(in: base, clipId: c.id, v) else {
            // 元の速度に戻した(変化なし)ときは、ドラッグ前の状態に戻す
            if gestureBase != nil, let b = gestureBase { updateGesture(b) }
            return
        }
        if gestureBase != nil { updateGesture(p) } else { edit(Self.speedUndoName) { $0 = p } }
    }

    /// ステッパーなどの連続編集(まとめて 1 回の Undo)。
    func coalescedSpeed(_ v: Double, clipId: String? = nil) {
        guard let c = speedTarget(clipId) else { return }
        coalescedEdit(Self.speedUndoName) { p in
            if let np = SpeedEditing.settingSpeed(in: p, clipId: c.id, v) { p = np }
        }
    }

    @discardableResult
    func setReverse(_ on: Bool, clipId: String? = nil) -> Bool {
        guard let c = speedTarget(clipId) else { return false }
        var probe = c
        guard SpeedEditing.setReverse(&probe, on) else { return false }
        setClipProperty({ _ = SpeedEditing.setReverse(&$0, on) }, name: on ? "逆再生にする" : "逆再生をやめる", clipId: c.id)
        return true
    }

    /// メニュー「逆再生にする」(切り替え)。
    @discardableResult
    func toggleReverseSelected() -> Bool {
        guard let c = speedTarget(nil) else { return false }
        return setReverse(!c.reverseOrDefault, clipId: c.id)
    }

    @discardableResult
    func setKeepPitch(_ on: Bool, clipId: String? = nil) -> Bool {
        guard let c = speedTarget(clipId) else { return false }
        var probe = c
        guard SpeedEditing.setKeepPitch(&probe, on) else { return false }
        setClipProperty({ _ = SpeedEditing.setKeepPitch(&$0, on) }, name: "音程を保つの切り替え", clipId: c.id)
        return true
    }

    /// メニュー「フリーズフレーム」: 選択クリップを再生位置で割り、間に 2 秒の静止画を入れる(1 回の Undo)。入れた静止画を選択する。
    @discardableResult
    func freezeFrameSelected() -> Bool {
        guard !isLocked, let id = selectedClipId, let r = SpeedEditing.freezeFrame(in: project, clipId: id, at: currentTime) else { return false }
        flushCoalesced()
        edit("フリーズフレーム") { $0 = r.project }
        selectedClipId = r.freezeId
        statusText = "フリーズフレームを入れました（\(Int(ClipTiming.freezeLength)) 秒）"
        return true
    }

    /// 選択クリップをフリーズフレームにできる位置か(メニューの有効・無効用)。
    var canFreezeFrame: Bool {
        guard let c = selectedClip else { return false }
        return SpeedEditing.canFreeze(c, at: currentTime)
    }
}
