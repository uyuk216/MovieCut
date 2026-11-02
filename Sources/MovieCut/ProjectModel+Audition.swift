import Foundation
import MovieCutCore

/// 重なったクリップの音だけの試聴。ロジックは MovieCutCore の `AudioAudition`。ここは対象の記憶・短い音の作成(背景)・再生だけで、
/// プロジェクトは変えない(Undo に載らない)。
extension ProjectModel {
    /// 再生位置に鳴っているクリップの id(下のレイヤーから順)。
    var auditionCandidates: [String] { AudioAudition.audibleIds(at: currentTime, in: project) }

    /// クリップの短い名前(状態欄用)。
    private func auditionName(_ id: String) -> String {
        let c = AudioAudition.audibleClips(at: currentTime, in: project).first { $0.id == id } ?? clip(id)
        if let t = c?.text, !t.isEmpty { return String(t.prefix(12)) }
        if let s = c?.src, !s.isEmpty { return (s as NSString).lastPathComponent }
        return "クリップ"
    }

    /// 再生 ▸ 重なったクリップの音だけ試聴: オン / オフ。オンにすると、対象(選択中の鳴っているクリップ、無ければ先頭)だけを鳴らす。
    @discardableResult
    func toggleAudition() -> Bool {
        if auditionOn {
            stopAudition()
            statusText = "音だけの試聴をやめました"
            return true
        }
        guard !isLocked else { return false }
        guard let id = AudioAudition.target(current: auditionClipId, selected: selectedClipId, at: currentTime, in: project) else {
            statusText = "再生位置に音のあるクリップがありません"
            return false
        }
        if playback.isPlaying { playback.pause() }
        auditionOn = true
        auditionClipId = id
        statusText = "試聴: \(auditionName(id)) の音だけ(再生位置を動かすと鳴ります)"
        auditionAtPlayhead()
        return true
    }

    /// 再生 ▸ 次の重なったクリップを試聴: 再生位置で鳴っているクリップを順に巡回して、その音だけを鳴らす(試聴がオフならオンにする)。
    @discardableResult
    func cycleAuditionTarget() -> Bool {
        guard !isLocked else { return false }
        let ids = auditionCandidates
        guard let id = AudioAudition.next(after: auditionClipId ?? selectedClipId, in: ids) else {
            statusText = "再生位置に音のあるクリップがありません"
            return false
        }
        if playback.isPlaying { playback.pause() }
        auditionOn = true
        auditionClipId = id
        let n = (ids.firstIndex(of: id) ?? 0) + 1
        statusText = "試聴: \(auditionName(id)) の音だけ(\(n)/\(ids.count))"
        auditionAtPlayhead()
        return true
    }

    /// 試聴をやめる(音を止め、準備中の仕事も捨てる)。
    func stopAudition() {
        auditionSeq += 1
        auditionTask?.cancel(); auditionTask = nil
        auditionPlayer.stop()
        auditionOn = false
        auditionClipId = nil
        removeAuditionFile()
    }

    private func removeAuditionFile() {
        if let u = auditionFile { try? FileManager.default.removeItem(at: u); auditionFile = nil }
    }

    /// 止まっている再生位置が動いたとき(スクラブ・コマ送り・クリック)に呼ぶ: 試聴がオンなら、対象の音を再生位置から短く鳴らす。
    func auditionAtPlayhead() {
        guard auditionOn, !isLocked, !playback.isPlaying, let id = auditionClipId else { return }
        auditionSeq += 1
        let seq = auditionSeq
        auditionTask?.cancel()
        guard AudioAudition.audibleIds(at: currentTime, in: project).contains(id) else {
            auditionPlayer.stop()                         // 対象が鳴っていない場所: 何も鳴らさない(他のクリップへは移らない)
            return
        }
        let p = project, t = currentTime
        let url = PlaybackTempFiles.newFileURL()
        auditionTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 25_000_000)            // ドラッグ中の細かい動きをまとめる
            guard !Task.isCancelled else { return }
            let result: Result<Double?, Error> = await Task.detached(priority: .userInitiated) {
                do { return .success(try AudioAudition.renderSnippet(project: p, clipId: id, at: t, to: url)) } catch { return .failure(error) }
            }.value
            guard let self, seq == self.auditionSeq, self.auditionOn else { try? FileManager.default.removeItem(at: url); return }
            switch result {
            case .success(let d?) where d > 0:
                self.removeAuditionFile()
                self.auditionFile = url
                self.auditionPlayer.play(url: url)
            case .success:
                try? FileManager.default.removeItem(at: url)
                self.auditionPlayer.stop()
            case .failure(let e):
                try? FileManager.default.removeItem(at: url)
                self.auditionPlayer.stop()
                self.statusText = "試聴の音を作れませんでした: \(e.localizedDescription)"
            }
        }
    }
}
