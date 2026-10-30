import Foundation
import MovieCutCore

/// 無音カットと BGM の自動ダッキング(メニュー・シート・インスペクタが呼ぶ)。計算は MovieCutCore に任せ、
/// ここは Undo(1 操作 = 1 回)・選択・状態表示だけ。何も変わらない操作は Undo に積まない。
extension ProjectModel {
    static let silenceUndoName = "無音をカット"
    static let duckUndoName = "自動ダッキングの変更"

    // MARK: 無音カット

    /// 「無音をカット…」のシートを開く(音のある素材のクリップを選んでいるときだけ)。
    func openSilenceSheet() {
        guard !isLocked, let c = selectedClip, SilenceDetector.supports(c) else { return }
        silenceClipId = c.id
        showSilenceSheet = true
    }

    /// シートの決定: 測った音の大きさと設定から無音を求めて切り取る。全体で 1 回の Undo。切る所が無い・全部が無音なら false(何も登録しない)。
    @discardableResult
    func cutSilence(clipId: String, profile: LevelProfile, params: SilenceParams, ripple: Bool) -> Bool {
        guard !isLocked else { return false }
        let cuts = profile.silentRanges(params)
        guard let r = ClipEditing.removeSilence(in: project, clipId: clipId, cuts: cuts, ripple: ripple) else { return false }
        guard edit(Self.silenceUndoName, { $0 = r.project }) else { return false }
        selectedClipId = r.clipIds.first
        statusText = "\(cuts.count) 箇所の無音をカットしました"
        return true
    }

    // MARK: 自動ダッキング

    private func duckTarget(_ clipId: String?) -> Clip? {
        guard !isLocked, let id = clipId ?? selectedClipId, let c = clip(id), DuckEditing.supports(c) else { return nil }
        return c
    }

    /// 1 回の編集(トグル・数値の確定)。
    func setDuck(_ change: @escaping (inout Clip) -> Void, name: String = "自動ダッキングの変更", clipId: String? = nil) {
        guard let c = duckTarget(clipId) else { return }
        setClipProperty(change, name: name, clipId: c.id)
    }

    /// スライダーのドラッグ中(`beginGesture` 〜 `commitGesture` の間)。
    func liveDuck(_ change: @escaping (inout Clip) -> Void, name: String = "自動ダッキングの変更", clipId: String? = nil) {
        guard let c = duckTarget(clipId) else { return }
        liveClipProperty(change, name: name, clipId: c.id)
    }

    /// メニュー「自動ダッキングを切り替え」。
    @discardableResult
    func toggleDuckSelected() -> Bool {
        guard let c = duckTarget(nil) else { return false }
        var probe = c
        guard DuckEditing.toggle(&probe) else { return false }
        setClipProperty({ _ = DuckEditing.toggle(&$0) }, name: c.hasDuck ? "自動ダッキングをオフ" : "自動ダッキングをオン", clipId: c.id)
        return true
    }
}
