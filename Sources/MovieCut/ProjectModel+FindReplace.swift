import Foundation
import MovieCutCore

/// 編集 ▸ 検索と置換…(テロップとセリフの一括置換)。計算は MovieCutCore(TextSearch)に任せ、ここは
/// セリフの音声の作り直し・Undo(全体で 1 回)・状態表示だけ。一致が無い・何も変わらないときは Undo に積まない。
extension ProjectModel {
    static let findReplaceUndoName = "検索と置換"

    /// 検索の対象: 選んでいるクリップだけにするなら選択の集合、そうでなければ nil(全体)。
    func findScope(selectionOnly: Bool) -> Set<String>? { selectionOnly ? selectedClipIDs : nil }

    /// シートの一致数の表示用。何も変えない。
    func findTextMatchCount(_ query: String, selectionOnly: Bool, options: TextSearch.Options) -> Int {
        TextSearch.matches(query, in: project, scope: findScope(selectionOnly: selectionOnly), options: options).count
    }

    /// 編集 ▸ 検索と置換…(書き出し中・音声生成中は開かない)。
    func openFindReplace() {
        guard !isLocked else { return }
        showFindSheet = true
    }

    /// 全部置き換える。セリフの文字が変わったものは音声を作り直す(セリフの編集と同じ作り方)。全体で Undo は 1 回。
    /// 1 つでも音声を作れなければ何も変えない。置き換えた数を返す。
    @discardableResult
    func replaceAllText(_ query: String, with replacement: String, options: TextSearch.Options, selectionOnly: Bool) async -> Int {
        guard !isLocked, !query.isEmpty else { return 0 }
        let r = TextSearch.replaceAll(query, with: replacement, in: project, scope: findScope(selectionOnly: selectionOnly), options: options)
        guard !r.changes.isEmpty else {
            statusText = r.skippedEmptyVoices > 0 ? "空になるセリフがあるため、変えませんでした" : "一致する文字はありません"
            return 0
        }
        flushCoalesced()
        playback.pause()
        let voiceCount = r.changes.filter(\.isVoice).count
        busyMessage = voiceCount > 0 ? "音声を作っています 0/\(voiceCount)" : "置き換えています"
        defer { busyMessage = nil }
        var updated: [String: Clip] = [:]
        var provider: VoiceProvider?
        if voiceCount > 0 {
            provider = ProgressVoiceProvider(inner: voiceProviderFactory(r.project), total: voiceCount) { [weak self] msg in
                Task { @MainActor in self?.busyMessage = msg }
            }
        }
        for ch in r.changes {
            guard let loc = ClipEditing.locate(ch.clipId, in: r.project) else { continue }
            var c = r.project.tracks[loc.track].clips[loc.index]
            if ch.isVoice, let provider {
                do {
                    try await ScriptTimeline.regenerateVoice(clip: &c, project: r.project, provider: provider)
                } catch {
                    errorTitle = "音声を作れませんでした"
                    errorMessage = error.localizedDescription
                    return 0
                }
            }
            updated[ch.clipId] = c
        }
        edit(Self.findReplaceUndoName) { p in
            for (id, c) in updated {
                if let l = ClipEditing.locate(id, in: p) { p.tracks[l.track].clips[l.index] = c }
            }
        }
        var note = "\(r.count) 箇所を置き換えました"
        if voiceCount > 0 { note += "(セリフ \(voiceCount) 個は音声を作り直しました)" }
        if r.lockedMatches > 0 { note += "。ロックされたレイヤーの \(r.lockedMatches) 箇所は変えていません" }
        if r.skippedEmptyVoices > 0 { note += "。空になるセリフ \(r.skippedEmptyVoices) 個は変えていません" }
        statusText = note
        return r.count
    }
}
