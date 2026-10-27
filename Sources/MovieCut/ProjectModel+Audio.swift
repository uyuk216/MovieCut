import Foundation
import AppKit
import MovieCutCore

/// 音声エフェクト・パン・音量の段階操作(インスペクタ・メニューが呼ぶ)。計算は MovieCutCore の AudioFxEditing に任せ、
/// ここは Undo(1 操作 = 1 回)・選択・状態表示だけ。何も変わらない操作は Undo に積まない。
extension ProjectModel {
    private func audioTarget(_ clipId: String?) -> Clip? {
        guard !isLocked, let id = clipId ?? selectedClipId, let c = clip(id), AudioFxEditing.supports(c) else { return nil }
        return c
    }

    /// 1 回の編集(トグル・ピッカー・リセット)。
    func setAudioFx(_ change: @escaping (inout Clip) -> Void, name: String, clipId: String? = nil) {
        guard let c = audioTarget(clipId) else { return }
        setClipProperty(change, name: name, clipId: c.id)
    }

    /// スライダーのドラッグ中(`beginGesture` 〜 `commitGesture` の間)。
    func liveAudioFx(_ change: @escaping (inout Clip) -> Void, name: String, clipId: String? = nil) {
        guard let c = audioTarget(clipId) else { return }
        liveClipProperty(change, name: name, clipId: c.id)
    }

    // MARK: 名前(編集履歴)

    static let eqUndoName = "イコライザーの変更"
    static let reverbUndoName = "リバーブの変更"
    static let normalizeUndoName = "ノーマライズの変更"
    static let panUndoName = "パンの変更"

    // MARK: メニュー「クリップ ▸ 音声」

    /// ノーマライズ(ピーク −1 dB)。
    @discardableResult
    func normalizePeakSelected() -> Bool {
        guard let c = audioTarget(nil) else { return false }
        var probe = c
        guard AudioFxEditing.normalizePeak(&probe) else { return false }
        setClipProperty({ _ = AudioFxEditing.normalizePeak(&$0) }, name: "ノーマライズ（ピーク −1 dB）", clipId: c.id)
        return true
    }

    /// 音量を ±3 dB。
    @discardableResult
    func stepVolumeSelected(db: Double) -> Bool {
        guard let c = audioTarget(nil) else { return false }
        var probe = c
        guard AudioFxEditing.stepVolume(&probe, db: db) else { return false }
        setClipProperty({ _ = AudioFxEditing.stepVolume(&$0, db: db) }, name: db > 0 ? "音量を上げる" : "音量を下げる", clipId: c.id)
        return true
    }

    @discardableResult
    func applyVoicePresetSelected() -> Bool {
        guard let c = audioTarget(nil) else { return false }
        var probe = c
        guard AudioFxEditing.applyVoicePreset(&probe) else { return false }
        setClipProperty({ _ = AudioFxEditing.applyVoicePreset(&$0) }, name: "ボイス向けプリセット", clipId: c.id)
        return true
    }

    @discardableResult
    func clearAudioFxSelected() -> Bool {
        guard let c = audioTarget(nil), AudioFxEditing.hasAnyFx(c) else { return false }
        setClipProperty({ _ = AudioFxEditing.clearAll(&$0) }, name: "音声エフェクトをすべて外す", clipId: c.id)
        return true
    }
}
