import AppKit
import MovieCutCore

/// 候補クリップを比較して差し替える(候補 36 オーディション)。ロジックは MovieCutCore の `CandidateSwap`。
/// シートを開いている間、候補を選ぶたびにタイムラインへ仮に反映して(ドラッグ中の編集と同じ。Undo には載せない)プレビューで見比べる。
/// 「差し替える」で全体が 1 回の Undo、「キャンセル」(閉じる)で元に戻す。
struct CandidateSession: Equatable {
    var clipId: String
    /// 利用者がファイル選択で足した候補(取り込み済みの素材ではない)
    var extra: [String] = []
    /// いま仮に反映している候補(nil = 元の素材)
    var selectedPath: String?
}

extension ProjectModel {
    /// 比較の対象にできる選択か(動画・音声・画像で、ロックされていなくて、候補がある)。
    var canOpenCandidateSwap: Bool {
        guard let c = selectedClip, !isLocked else { return false }
        return !CandidateSwap.candidates(for: c, in: project).isEmpty
    }

    /// 候補一覧(元の素材の編集前の状態から数える)。
    func currentCandidates() -> [CandidateSwap.Candidate] {
        guard let s = candidateSession else { return [] }
        let base = gestureBase ?? project
        guard let loc = ClipEditing.locate(s.clipId, in: base) else { return [] }
        return CandidateSwap.candidates(for: base.tracks[loc.track].clips[loc.index], in: base, extra: s.extra)
    }

    /// クリップ ▸ 候補クリップを比較して差し替え…
    @discardableResult
    func openCandidateSwap() -> Bool {
        guard candidateSession == nil, let c = selectedClip, !isLocked, CandidateSwap.supports(c),
              !CandidateSwap.candidates(for: c, in: project).isEmpty else { return false }
        flushCoalesced()
        beginGesture()
        candidateSession = CandidateSession(clipId: c.id)
        playback.seek(to: c.start)
        return true
    }

    /// 候補を仮に反映する(nil で元の素材に戻す)。素材の長さを測ってから反映する。
    @discardableResult
    func previewCandidate(_ path: String?) async -> Bool {
        guard var s = candidateSession, let base = gestureBase else { return false }
        guard let path else {
            s.selectedPath = nil
            candidateSession = s
            project = base
            playback.projectDidChange()
            return true
        }
        guard let loc = ClipEditing.locate(s.clipId, in: base) else { return false }
        let kind = base.tracks[loc.track].clips[loc.index].type
        let cand = CandidateSwap.Candidate(path: path, kind: kind)
        let dur: Double? = kind == .image ? nil : await candidateProbe(URL(fileURLWithPath: path), kind)
        // 測っている間に閉じられた・別の候補が選ばれたときは捨てる
        guard candidateSession?.clipId == s.clipId, gestureBase != nil else { return false }
        guard var p = CandidateSwap.swap(in: base, clipId: s.clipId, to: cand, sourceDuration: dur) else { return false }
        UnusedMedia.register([path], in: &p)
        s.selectedPath = path
        candidateSession = s
        project = p
        playback.projectDidChange()
        return true
    }

    /// 利用者が選んだファイルを候補に足す(同じ種類のものだけ)。足した数を返す。
    @discardableResult
    func addCandidateFiles(_ urls: [URL]) -> Int {
        guard var s = candidateSession, let base = gestureBase, let loc = ClipEditing.locate(s.clipId, in: base) else { return 0 }
        let kind = base.tracks[loc.track].clips[loc.index].type
        let have = Set(currentCandidates().map(\.path) + [base.tracks[loc.track].clips[loc.index].src ?? ""])
        let add = urls.map(\.path).filter { ClipEditing.kindOf(path: $0) == kind && ClipEditing.isSupportedMedia(path: $0) && !have.contains($0) }
        guard !add.isEmpty else { return 0 }
        s.extra += add
        candidateSession = s
        return add.count
    }

    func chooseCandidateFiles() {
        guard candidateSession != nil else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.title = "候補にする素材を選ぶ"
        guard panel.runModal() == .OK else { return }
        let n = addCandidateFiles(panel.urls)
        if n == 0 { statusText = "同じ種類の新しい素材がありません" }
    }

    /// 反映中の候補で確定する。全体が 1 回の Undo。元の素材のままなら何も登録しない。
    @discardableResult
    func commitCandidateSwap() -> Bool {
        guard candidateSession != nil else { return false }
        candidateSession = nil
        guard let base = gestureBase else { return false }
        let changed = project != base
        commitGesture("候補クリップに差し替え")
        if changed { statusText = "素材を差し替えました" }
        return changed
    }

    /// 閉じる: 元の素材に戻して終わる。
    func cancelCandidateSwap() {
        guard candidateSession != nil else { return }
        candidateSession = nil
        if let base = gestureBase {
            gestureBase = nil
            if project != base { project = base; playback.projectDidChange() }
        }
    }
}
