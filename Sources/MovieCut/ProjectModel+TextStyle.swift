import Foundation
import MovieCutCore

/// 文字の装飾・アニメーション・スタイル(インスペクタ・メニューが呼ぶ)。計算は MovieCutCore の TextStyleEditing / TextStyleLibrary に任せ、
/// ここは Undo・選択・状態表示だけ。何も変わらない編集は Undo に載せない。
extension ProjectModel {
    private func styleTarget(_ clipId: String?) -> Clip? {
        guard !isLocked, let id = clipId ?? selectedClipId, let c = clip(id) else { return nil }
        return c
    }

    /// 装飾の 1 回の編集(メニュー・トグル・選択など)。
    @discardableResult
    func setTextStyle(_ change: @escaping (inout TextStyle) -> Void, name: String, clipId: String? = nil) -> Bool {
        guard let c = styleTarget(clipId) else { return false }
        var probe = c
        guard TextStyleEditing.update(&probe, change) else { return false }
        setClipProperty({ _ = TextStyleEditing.update(&$0, change) }, name: name, clipId: c.id)
        return true
    }

    /// 色ピッカー・ステッパーなど連続する編集(まとめて 1 回の Undo)。
    func coalescedTextStyle(_ change: @escaping (inout TextStyle) -> Void, name: String, clipId: String? = nil) {
        guard styleTarget(clipId) != nil else { return }
        coalescedClipProperty({ _ = TextStyleEditing.update(&$0, change) }, name: name, clipId: clipId)
    }

    @discardableResult
    func setTextAnim(_ kind: TextAnimKind, duration: Double? = nil, clipId: String? = nil) -> Bool {
        guard let c = styleTarget(clipId) else { return false }
        var probe = c
        guard TextStyleEditing.setAnim(&probe, kind: kind, duration: duration) else { return false }
        setClipProperty({ _ = TextStyleEditing.setAnim(&$0, kind: kind, duration: duration) }, name: "文字アニメーション: " + kind.label, clipId: c.id)
        return true
    }

    func coalescedTextAnimDuration(_ d: Double, clipId: String? = nil) {
        guard let c = styleTarget(clipId), let k = c.textAnim?.known, k != .none else { return }
        coalescedClipProperty({ _ = TextStyleEditing.setAnim(&$0, kind: k, duration: d) }, name: "文字アニメーションの長さの変更", clipId: clipId)
    }

    // MARK: スタイル

    /// 保存したスタイル(組み込み + 保存)を当てる(1 回の Undo)。
    @discardableResult
    func applyTextStyle(id: String, clipId: String? = nil) -> Bool {
        guard let c = styleTarget(clipId), c.type == .text, let s = textStyles.find(id) else { return false }
        var probe = c
        guard s.look.apply(to: &probe) else { return false }
        let look = s.look
        setClipProperty({ _ = look.apply(to: &$0) }, name: "スタイルを適用: " + s.name, clipId: c.id)
        return true
    }

    /// メニュー「クリップ ▸ テキスト ▸ スタイルを適用 ▸ ○○」。
    @discardableResult
    func applyTextStyleSelected(_ id: String) -> Bool { applyTextStyle(id: id) }

    /// 「現在の見た目を保存…」。保存した id(名前が空・文字クリップでない場合は nil)。
    @discardableResult
    func saveCurrentTextStyle(named name: String, clipId: String? = nil) -> String? {
        guard let id = clipId ?? selectedClipId, let c = clip(id), c.type == .text else { return nil }
        let sid = textStyles.add(name: name, look: TextLook(of: c))
        if sid != nil { statusText = "スタイルを保存しました: " + (TextStyleLibrary.sanitizedName(name) ?? name) }
        return sid
    }

    @discardableResult
    func renameTextStyle(id: String, to name: String) -> Bool { textStyles.rename(id: id, to: name) }

    @discardableResult
    func deleteTextStyle(id: String) -> Bool { textStyles.delete(id: id) }
}
