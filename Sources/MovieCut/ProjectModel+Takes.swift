import Foundation
import MovieCutCore

/// 同じセリフの別テイクの比較(候補 35)。ロジックは MovieCutCore の `TakeCompare`。
/// 表示の状態(シートの開閉・数字・試聴)は保存せず Undo にも載せない。「このテイクだけ残す」だけが 1 回の Undo。
extension ProjectModel {
    var takeGroups: [TakeCompare.Group] { TakeCompare.groups(in: project) }

    /// クリップ ▸ 同じセリフのテイクを比較…
    func openTakeCompare() {
        guard !isLocked, !takeGroups.isEmpty else { return }
        showTakeSheet = true
    }

    /// テイクの音を頭から鳴らす(全体の再生は止める)。素材が無ければ状態欄に出す。
    @discardableResult
    func playTake(clipId: String) -> Bool {
        guard let c = clip(clipId), c.type == .voice, let src = c.src, FileManager.default.fileExists(atPath: src) else {
            statusText = "テイクの音声ファイルが見つかりません"
            return false
        }
        playback.pause()
        takePlayer.play(url: URL(fileURLWithPath: src))
        takePlayingId = clipId
        return true
    }

    func stopTakePlayback() {
        takePlayer.stop()
        takePlayingId = nil
    }

    /// 選んだテイクだけを残し、同じセリフの他のテイクを取り除く。全体で 1 回の Undo。取り除くものが無ければ何もしない。
    @discardableResult
    func keepOnlyTake(_ clipId: String) -> Bool {
        guard !isLocked else { return false }
        flushCoalesced()
        guard let r = TakeCompare.keepOnly(clipId, in: project) else {
            statusText = "取り除けるテイクがありません(ロックされているか、他のテイクがありません)"
            return false
        }
        stopTakePlayback()
        guard edit("テイクを選ぶ(他を取り除く)", { $0 = r.project }) else { return false }
        selectedClipId = clipId
        statusText = "\(r.removed.count) 個のテイクを取り除きました" + (r.skippedLocked > 0 ? "(ロックされた \(r.skippedLocked) 個は残しています)" : "")
        return true
    }

    /// テイクのクリップの頭へ移り、選ぶ(選択だけ。Undo に載せない)。
    func focusTake(_ t: TakeCompare.Take) { focusClip(id: t.clipId, at: t.start) }
}
