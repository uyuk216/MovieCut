import Foundation
import AppKit
import MovieCutCore

/// エフェクト(インスペクタ・メニューが呼ぶ)。計算は MovieCutCore の EffectEditing に任せ、ここは Undo・選択・状態表示だけ。
/// 引数の値は、キーフレームの仕組み("fx.<番号>.<引数>")と同じ `setKeyed` / `coalescedKeyed` / `liveKeyed` で編集する。
extension ProjectModel {
    private func targetClip(_ clipId: String?) -> Clip? {
        guard !isLocked, let id = clipId ?? selectedClipId, let c = clip(id) else { return nil }
        return c
    }

    // MARK: 追加・削除・並べ替え

    @discardableResult
    func addEffect(_ kind: EffectKind, clipId: String? = nil) -> Bool {
        guard let c = targetClip(clipId) else { return false }
        var probe = c
        guard EffectEditing.add(&probe, kind) else { return false }
        setClipProperty({ _ = EffectEditing.add(&$0, kind) }, name: "エフェクトの追加: \(kind.label)", clipId: c.id)
        return true
    }

    /// メニュー「クリップ ▸ エフェクト ▸ ○○」。
    @discardableResult
    func addEffectSelected(_ kind: EffectKind) -> Bool { addEffect(kind) }

    @discardableResult
    func removeEffect(at index: Int, clipId: String? = nil) -> Bool {
        guard let c = targetClip(clipId) else { return false }
        var probe = c
        guard EffectEditing.remove(&probe, at: index) else { return false }
        let label = c.effects[index].known?.label ?? "エフェクト"
        setClipProperty({ _ = EffectEditing.remove(&$0, at: index) }, name: "エフェクトの削除: \(label)", clipId: c.id)
        return true
    }

    @discardableResult
    func moveEffect(at index: Int, by delta: Int, clipId: String? = nil) -> Bool {
        guard let c = targetClip(clipId) else { return false }
        var probe = c
        guard EffectEditing.move(&probe, at: index, by: delta) else { return false }
        setClipProperty({ _ = EffectEditing.move(&$0, at: index, by: delta) }, name: "エフェクトの順番の変更", clipId: c.id)
        return true
    }

    @discardableResult
    func setEffectEnabled(_ on: Bool, at index: Int, clipId: String? = nil) -> Bool {
        guard let c = targetClip(clipId) else { return false }
        var probe = c
        guard EffectEditing.setEnabled(&probe, at: index, on) else { return false }
        setClipProperty({ _ = EffectEditing.setEnabled(&$0, at: index, on) }, name: on ? "エフェクトを有効にする" : "エフェクトを無効にする", clipId: c.id)
        return true
    }

    /// 影・縁取りの色(色ピッカーの連続編集なので、まとめて 1 回の Undo)。
    func coalescedEffectColor(_ hex: String, at index: Int, clipId: String? = nil) {
        guard !isLocked else { return }
        coalescedClipProperty({ _ = EffectEditing.setColor(&$0, at: index, hex) }, name: "エフェクトの色の変更", clipId: clipId)
    }

    @discardableResult
    func resetEffect(at index: Int, clipId: String? = nil) -> Bool {
        guard let c = targetClip(clipId) else { return false }
        var probe = c
        guard EffectEditing.reset(&probe, at: index) else { return false }
        setClipProperty({ _ = EffectEditing.reset(&$0, at: index) }, name: "エフェクトを初期値に戻す", clipId: c.id)
        return true
    }

    // MARK: メニュー

    @discardableResult
    func clearEffectsSelected() -> Bool {
        guard let c = targetClip(nil), !c.effects.isEmpty else { return false }
        setClipProperty({ _ = EffectEditing.clear(&$0) }, name: "エフェクトをすべて外す", clipId: c.id)
        return true
    }

    @discardableResult
    func copyEffectsSelected() -> Bool {
        guard let c = selectedClip, !c.effects.isEmpty else { return false }
        effectClipboard = c.effects
        statusText = "エフェクトをコピーしました（\(c.effects.count) 個）"
        return true
    }

    @discardableResult
    func pasteEffectsSelected() -> Bool {
        guard !effectClipboard.isEmpty, let c = targetClip(nil) else { return false }
        var probe = c
        guard EffectEditing.append(&probe, effectClipboard) else { return false }
        let list = effectClipboard
        setClipProperty({ _ = EffectEditing.append(&$0, list) }, name: "エフェクトの貼り付け", clipId: c.id)
        return true
    }

    @discardableResult
    func applyEffectPreset(_ preset: EffectPreset) -> Bool {
        guard let c = targetClip(nil) else { return false }
        var probe = c
        guard preset.apply(to: &probe) else { return false }
        setClipProperty({ _ = preset.apply(to: &$0) }, name: preset.undoName, clipId: c.id)
        return true
    }
}
