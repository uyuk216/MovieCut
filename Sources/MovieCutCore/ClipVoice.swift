import Foundation

// MARK: - 録音した音声クリップを「声」として扱う指定
//
// BGM の自動ダッキング(`Ducking.voiceSpans`)の「声」は、ボイスクリップに加えて、この指定をした音声クリップも含む。
// 映像・波形・音量は変えない(ダッキングの引き金になるだけ)。
// - 音の経路: 声の区間は `CompoundEditing.audibleClips` 経由なので、消音・ソロ・レイヤー消音・複合クリップの中の子も一貫する。
// - 保存: `Clip.treatAsVoice` は true のときだけ書く(`Clip.muted` と同じ流儀)。
// - 編集: ロックされたレイヤー・クリップ(複合クリップの外側も含む)には触れない。複合クリップの中の子にも効く。

public extension ClipEditing {
    /// 声として扱う指定ができるクリップ: 音声クリップだけ(ボイスクリップは元々声。動画は対象外)。
    static func supportsVoiceDesignation(_ c: Clip) -> Bool { c.type == .audio }

    /// クリップ 1 つの「声として扱う」指定を切り替える(複合クリップの中の子も探す)。
    /// 見つからない・対象外の型・変わらない・ロックされたレイヤー/クリップ(外側の複合クリップを含む)のときは nil。
    static func setTreatedAsVoice(in project: Project, clipId: String, _ on: Bool) -> Project? {
        setClipsTreatedAsVoice(in: project, ids: [clipId], on)
    }

    /// 複数のクリップの指定を揃えて切り替える。ロックされたものは飛ばす。何も変わらなければ nil。
    static func setClipsTreatedAsVoice(in project: Project, ids: Set<String>, _ on: Bool) -> Project? {
        var p = project
        applyTreatedAsVoice(&p.tracks, ids: ids, on: on, blocked: false)
        return p == project ? nil : p
    }

    /// 選んだクリップ(複合クリップの中を含む)のうち、指定できるものが全部指定済みか。メニューの表示用。
    static func allTreatedAsVoice(_ ids: Set<String>, in project: Project) -> Bool {
        let found = collectVoiceDesignatable(project.tracks, ids: ids)
        return !found.isEmpty && found.allSatisfy(\.isTreatedAsVoice)
    }

    /// 選んだクリップのうち、指定できるものがあるか(メニューの有効判定)。
    static func hasVoiceDesignatable(_ ids: Set<String>, in project: Project) -> Bool {
        !collectVoiceDesignatable(project.tracks, ids: ids).isEmpty
    }

    private static func collectVoiceDesignatable(_ tracks: [Track], ids: Set<String>) -> [Clip] {
        var out: [Clip] = []
        for c in tracks.flatMap(\.clips) {
            if ids.contains(c.id), supportsVoiceDesignation(c) { out.append(c) }
            if c.type == .compound, let kids = c.tracks { out += collectVoiceDesignatable(kids, ids: ids) }
        }
        return out
    }

    private static func applyTreatedAsVoice(_ tracks: inout [Track], ids: Set<String>, on: Bool, blocked: Bool) {
        for ti in tracks.indices {
            let tb = blocked || tracks[ti].isLocked
            for ci in tracks[ti].clips.indices {
                if ids.contains(tracks[ti].clips[ci].id), !tb, !tracks[ti].clips[ci].isClipLocked, supportsVoiceDesignation(tracks[ti].clips[ci]) {
                    tracks[ti].clips[ci].treatAsVoice = on ? true : nil
                    tracks[ti].clips[ci].extra["treatAsVoice"] = nil
                }
                if tracks[ti].clips[ci].type == .compound, var kids = tracks[ti].clips[ci].tracks {
                    applyTreatedAsVoice(&kids, ids: ids, on: on, blocked: tb || tracks[ti].clips[ci].isClipLocked)
                    tracks[ti].clips[ci].tracks = kids
                }
            }
        }
    }
}
