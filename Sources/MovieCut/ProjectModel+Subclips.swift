import Foundation
import MovieCutCore

/// 複数の素材から範囲を指定してサブクリップを一括作成(候補 38)。ロジックは MovieCutCore の `SubclipBatch`。
/// 再生位置から順に隙間なく、空いたレイヤーへ並べる。全体が 1 回の Undo。
extension ProjectModel {
    /// 素材の指定に使える(動画・音声の)取り込み済みの素材。
    var subclipPoolItems: [String] {
        project.mediaPool.filter { let k = ClipEditing.kindOf(path: $0); return k == .video || k == .audio }
    }

    func openSubclipSheet() {
        guard !isLocked else { return }
        showSubclipSheet = true
    }

    /// 書いた指定を解析する(シートの確認表示用)。
    func parseSubclipText(_ text: String) -> SubclipBatch.Parsed {
        SubclipBatch.parse(text, pool: project.mediaPool)
    }

    /// 指定どおりにサブクリップを作って並べる。作った数を返す(0 = 何もしなかった。理由は状態欄)。
    @discardableResult
    func createSubclips(from text: String) async -> Int {
        guard !isLocked else { return 0 }
        let parsed = parseSubclipText(text)
        guard !parsed.specs.isEmpty else {
            statusText = parsed.errors.first.map { "\($0.line) 行目: \($0.message)" } ?? "範囲の指定がありません"
            return 0
        }
        // 素材ごとに長さを測る(1 回ずつ)
        var durations: [String: Double] = [:]
        for src in Set(parsed.specs.map(\.src)) {
            if let d = await candidateProbe(URL(fileURLWithPath: src), ClipEditing.kindOf(path: src)), d > 0 { durations[src] = d }
        }
        // 測っている間に編集された・ロックされたときは、いまの状態でやり直せるよう何もしない
        guard !isLocked else { return 0 }
        let built = SubclipBatch.build(parsed.specs, durations: durations, start: currentTime)
        guard let r = SubclipBatch.place(built.clips, in: project) else {
            statusText = built.errors.first ?? "作れる範囲がありません"
            return 0
        }
        flushCoalesced()
        guard edit("サブクリップを一括作成", enforcesLock: false, { $0 = r.project }) else { return 0 }
        setSelection(ClipSelection(ids: Set(r.newIds), primary: r.newIds.first))
        var note = "\(r.newIds.count) 個のサブクリップを作りました"
        let skipped = parsed.errors.count + built.errors.count
        if skipped > 0 { note += "(読めなかった・作れなかった指定 \(skipped) 件)" }
        statusText = note
        return r.newIds.count
    }
}
