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

    // MARK: 吹き出し(B-2)

    /// 吹き出しを付ける・外す(b が nil で外す)。変わらないときは何もしない。1 回の Undo。
    func setBubble(_ b: Bubble?, name: String, clipId: String? = nil) {
        guard let c = styleTarget(clipId), c.type == .text else { return }
        let new = b?.normalized
        guard new != c.bubble else { return }
        setClipProperty({ $0.bubble = new }, name: name, clipId: c.id)
    }

    /// 吹き出しの項目を 1 つ書き換える(ボタン・メニュー・トグル)。吹き出しが無いときは何もしない。
    func editBubble(_ change: (inout Bubble) -> Void, name: String, clipId: String? = nil) {
        guard let c = styleTarget(clipId), c.type == .text, let cur = c.bubble else { return }
        var nb = cur
        change(&nb)
        setBubble(nb, name: name, clipId: c.id)
    }

    /// 色ピッカー・スライダーなど連続する編集(まとめて 1 回の Undo)。
    func coalescedBubble(_ change: @escaping (inout Bubble) -> Void, name: String, clipId: String? = nil) {
        guard let c = styleTarget(clipId), c.bubble != nil else { return }
        coalescedClipProperty({ clip in
            if var b = clip.bubble { change(&b); clip.bubble = b.normalized }
        }, name: name, clipId: c.id)
    }
}

// MARK: スタイルの一括適用(item 7)
extension ProjectModel {
    /// 保存したスタイルを文字クリップに一括で当てる(全体で 1 回の Undo)。
    /// 対象は、文字クリップを 2 つ以上選んでいればその選択、そうでなければ全部の文字クリップ。ロックされたレイヤーは変えない。
    /// 変わるものが無ければ何もせず 0 を返す(Undo に載せない)。
    @discardableResult
    func applyTextStyleToAll(id: String) -> Int {
        guard !isLocked, let s = textStyles.find(id) else { return 0 }
        flushCoalesced()
        let scope: Set<String>? = selectedClipIDs.count > 1 ? selectedClipIDs : nil
        let r = TextStyleBulk.apply(s.look, to: project, scope: scope)
        guard !r.changedIds.isEmpty else {
            statusText = r.lockedSkipped > 0 ? "ロックされたレイヤーの文字は変えませんでした" : "変わる文字クリップがありません"
            return 0
        }
        edit("スタイルを一括適用: " + s.name) { $0 = r.project }
        var note = "\(r.changedIds.count) 個の文字クリップにスタイルを当てました"
        if r.lockedSkipped > 0 { note += "(ロックされた \(r.lockedSkipped) 個は変えていません)" }
        statusText = note
        return r.changedIds.count
    }
}

// MARK: カウントダウン(文字クリップ)
extension ProjectModel {
    /// カウントダウンを置く・外す(nil で外す)。変わらないときは何もしない(Undo に載せない)。1 回の Undo。
    func setCounter(_ counter: TextCounter?, name: String, clipId: String? = nil) {
        guard let c = styleTarget(clipId), c.type == .text else { return }
        var probe = c
        guard CounterEditing.set(&probe, to: counter) else { return }
        setClipProperty({ _ = CounterEditing.set(&$0, to: counter) }, name: name, clipId: c.id)
    }

    /// メニュー「テキスト ▸ カウントダウンにする」(付いていれば外す)。
    func toggleCounterSelected() {
        guard let c = styleTarget(nil), c.type == .text else { return }
        setCounter(c.counter == nil ? TextCounter() : nil, name: c.counter == nil ? "カウントダウンにする" : "カウントダウンを外す", clipId: c.id)
    }

    /// 付いているカウントダウンの項目を 1 つ書き換える(入力欄の確定)。付いていないときは何もしない。
    func editCounter(_ change: (inout TextCounter) -> Void, name: String, clipId: String? = nil) {
        guard let c = styleTarget(clipId), c.type == .text, c.counter != nil else { return }
        var probe = c
        guard CounterEditing.update(&probe, change) else { return }
        setClipProperty({ _ = CounterEditing.update(&$0, change) }, name: name, clipId: c.id)
    }

    /// ステッパーなど連続する編集(まとめて 1 回の Undo)。
    func coalescedCounter(_ change: @escaping (inout TextCounter) -> Void, name: String, clipId: String? = nil) {
        guard let c = styleTarget(clipId), c.counter != nil else { return }
        coalescedClipProperty({ _ = CounterEditing.update(&$0, change) }, name: name, clipId: c.id)
    }
}
