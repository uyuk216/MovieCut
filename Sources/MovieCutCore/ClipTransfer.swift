import Foundation

/// 選んだクリップを、元の配置(レイヤー番号と時刻)を残したまま別のプロジェクトへ複製する(候補 37)。
/// 通常のコピー&貼り付けは再生位置へ貼るが、こちらは時刻もレイヤーもそのまま。画面を持たない純粋な計算。
/// - `extract`: 選んだクリップだけの新しいプロジェクト(設定・使うキャラクター・使う素材つき)を作る。
/// - `insert`: 別のプロジェクトへ入れる。キャラクターは id → 名前の順に対応づけ、無ければ足す。クリップは新しい id。
public enum ClipTransfer {
    public struct Package: Equatable {
        /// 選んだクリップだけを元のレイヤー・時刻のまま置いた新しいプロジェクト。
        public var project: Project
        public var copied: Int
    }

    /// 選んだクリップ(レイヤーの外側のもの。複合クリップは中身ごと)から新しいプロジェクトを作る。選択が空・見つからなければ nil。
    /// - レイヤー: 選んだクリップがある一番下のレイヤーまで、元の番号のまま(名前・非表示・消音・ソロ・高さは写し、ロックは写さない)。
    /// - 設定(解像度・fps・背景・コーデック・音声エンジンの設定)は元と同じ。キャラクターはボイスクリップが使うものだけ(無ければ既定)。
    /// - 取り込んだ素材は、選んだクリップが使うものだけ。マーカー・書き出し範囲は写さない。
    public static func extract(from project: Project, clipIds: Set<String>) -> Package? {
        var picked: [(track: Int, clip: Clip)] = []
        for (ti, tr) in project.tracks.enumerated() {
            for c in tr.clips where clipIds.contains(c.id) { picked.append((ti, c)) }
        }
        guard !picked.isEmpty, let last = picked.map(\.track).max() else { return nil }
        var p = Project()
        p.width = project.width; p.height = project.height; p.fps = project.fps; p.bg = project.bg; p.codec = project.codec
        p.voicevoxUrl = project.voicevoxUrl; p.aquestalkCommand = project.aquestalkCommand
        p.tracks = (0...last).map { i in
            let src = project.tracks[i]
            var t = Track(name: src.name)
            t.hidden = src.hidden; t.muted = src.muted; t.solo = src.solo; t.height = src.height
            return t
        }
        for e in picked { p.tracks[e.track].clips.append(e.clip) }
        let used = usedCharacterIds(picked.map(\.clip))
        let chars = project.characters.filter { used.contains($0.id) }
        if !chars.isEmpty { p.characters = chars }
        var paths = Set<String>()
        UnusedMedia.collect(picked.map(\.clip), into: &paths)
        p.mediaPool = project.mediaPool.filter { paths.contains($0) }
        p.mediaHints = project.mediaHints.filter { paths.contains($0.key) }
        return Package(project: p, copied: picked.count)
    }

    /// ボイスクリップが使うキャラクターの id(複合クリップの中も)。
    static func usedCharacterIds(_ clips: [Clip]) -> Set<String> {
        var out = Set<String>()
        func walk(_ cs: [Clip]) {
            for c in cs {
                if c.type == .voice, let id = c.charId, !id.isEmpty { out.insert(id) }
                for tr in c.tracks ?? [] { walk(tr.clips) }
            }
        }
        walk(clips)
        return out
    }

    public struct InsertResult: Equatable {
        public var project: Project
        public var newIds: [String]
        /// ロックされたレイヤーに入るため入れなかった数。
        public var skipped: Int
        /// 行き先に足したキャラクターの数。
        public var addedCharacters: Int
    }

    /// `source`(`extract` の結果など)の全クリップを、時刻もレイヤー番号もそのまま `dest` へ入れる。
    /// 同じレイヤーの別のクリップと重なるときは、次の空きレイヤーへ(`ClipEditing.paste` と同じ)。足りないレイヤーは足す。
    /// 入れられるものが無ければ nil。
    public static func insert(from source: Project, into dest: Project) -> InsertResult? {
        var items: [ClipClipboard.Item] = []
        for (ti, tr) in source.tracks.enumerated() { for c in tr.clips { items.append(.init(track: ti, clip: c)) } }
        guard !items.isEmpty else { return nil }
        var p = dest
        // キャラクター: 同じ id → 同じ名前・エンジン → 足す
        var map: [String: String] = [:]
        var added = 0
        for id in usedCharacterIds(items.map(\.clip)) {
            guard let ch = source.characters.first(where: { $0.id == id }) else { continue }
            if p.characters.contains(where: { $0.id == id }) { continue }
            if let same = p.characters.first(where: { $0.name == ch.name && $0.engine == ch.engine }) { map[id] = same.id; continue }
            p.characters.append(ch)
            added += 1
        }
        if !map.isEmpty {
            items = items.map { it in
                var c = it.clip
                remapCharacters(&c, map)
                return .init(track: it.track, clip: c)
            }
        }
        let minStart = items.map { $0.clip.start }.min() ?? 0
        guard let r = ClipEditing.paste(ClipClipboard(items: items), in: p, at: minStart, targetTrack: nil) else { return nil }
        var out = r.project
        // 足したレイヤーには元の名前を付ける
        for i in p.tracks.count..<max(p.tracks.count, out.tracks.count) where source.tracks.indices.contains(i) && !source.tracks[i].name.isEmpty {
            out.tracks[i].name = source.tracks[i].name
        }
        var paths = Set<String>()
        UnusedMedia.collect(items.map(\.clip), into: &paths)
        UnusedMedia.register(source.mediaPool.filter { paths.contains($0) }, in: &out)
        return InsertResult(project: out, newIds: r.newIds, skipped: r.skipped, addedCharacters: added)
    }

    private static func remapCharacters(_ c: inout Clip, _ map: [String: String]) {
        if c.type == .voice, let id = c.charId, let to = map[id] { c.charId = to }
        if var tracks = c.tracks {
            for ti in tracks.indices { for ci in tracks[ti].clips.indices { remapCharacters(&tracks[ti].clips[ci], map) } }
            c.tracks = tracks
        }
    }
}
