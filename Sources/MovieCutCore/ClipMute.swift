import Foundation

// MARK: - クリップ単位の消音
//
// レイヤーの消音(`Track.muted`)とは別に、クリップ 1 つだけを鳴らさない。映像・波形は変えない(音の経路だけ)。
// - 音の経路: `CompoundEditing.audibleClips` が消音クリップを除く(書き出し・プレビュー再生・ラウドネス・ダッキングの声がこれを通る)。
// - 保存: `Clip.muted` は true のときだけ書く(`Clip.locked` と同じ流儀)。
// - 編集: ロックされたレイヤー・クリップ(複合クリップの外側も含む)には触れない。複合クリップの中の子にも効く。

public extension ClipEditing {
    /// 消音できるクリップ: 音の出る型(音声・ボイス・動画)と、中に音を持つ複合クリップ。
    static func supportsMute(_ c: Clip) -> Bool { TransitionEditing.supportsAudio(c.type) || c.type == .compound }

    /// クリップ 1 つの消音を切り替える(複合クリップの中の子も探す)。
    /// 見つからない・消音できない型・変わらない・ロックされたレイヤー/クリップ(外側の複合クリップを含む)のときは nil。
    static func setMuted(in project: Project, clipId: String, _ on: Bool) -> Project? {
        setClipsMuted(in: project, ids: [clipId], on)
    }

    /// 複数のクリップの消音を揃えて切り替える。ロックされたものは飛ばす。何も変わらなければ nil。
    static func setClipsMuted(in project: Project, ids: Set<String>, _ on: Bool) -> Project? {
        var p = project
        applyMuted(&p.tracks, ids: ids, on: on, blocked: false)
        return p == project ? nil : p
    }

    /// 選んだクリップ(複合クリップの中を含む)のうち、消音できるものが全部消音済みか。メニューの表示用。
    static func allMuted(_ ids: Set<String>, in project: Project) -> Bool {
        let found = collectMutable(project.tracks, ids: ids)
        return !found.isEmpty && found.allSatisfy(\.isMuted)
    }

    /// 選んだクリップのうち、消音できるものがあるか(メニューの有効判定)。
    static func hasMutable(_ ids: Set<String>, in project: Project) -> Bool {
        !collectMutable(project.tracks, ids: ids).isEmpty
    }

    private static func collectMutable(_ tracks: [Track], ids: Set<String>) -> [Clip] {
        var out: [Clip] = []
        for c in tracks.flatMap(\.clips) {
            if ids.contains(c.id), supportsMute(c) { out.append(c) }
            if c.type == .compound, let kids = c.tracks { out += collectMutable(kids, ids: ids) }
        }
        return out
    }

    private static func applyMuted(_ tracks: inout [Track], ids: Set<String>, on: Bool, blocked: Bool) {
        for ti in tracks.indices {
            let tb = blocked || tracks[ti].isLocked
            for ci in tracks[ti].clips.indices {
                if ids.contains(tracks[ti].clips[ci].id), !tb, !tracks[ti].clips[ci].isClipLocked, supportsMute(tracks[ti].clips[ci]) {
                    tracks[ti].clips[ci].muted = on ? true : nil
                    tracks[ti].clips[ci].extra["muted"] = nil
                }
                if tracks[ti].clips[ci].type == .compound, var kids = tracks[ti].clips[ci].tracks {
                    applyMuted(&kids, ids: ids, on: on, blocked: tb || tracks[ti].clips[ci].isClipLocked)
                    tracks[ti].clips[ci].tracks = kids
                }
            }
        }
    }
}
