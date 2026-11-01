import Foundation

// MARK: - 複合クリップ
//
// 複数のクリップを 1 つの `compound` クリップにまとめる(クリップ ▸ 複合クリップにまとめる)。
// 中身は複合クリップの `tracks`(子のレイヤー)。子の `start` は複合クリップの頭からの秒で保存する。
// - 描画: `Renderer` が子のタイムラインを時刻 `t − start` で再帰的に描き、その画像を親と同じ経路(位置・効果・不透明度・トランジション)に載せる。
// - 音声: `audibleClips(in:)` が子を平らにして、`AudioMixer` が親と同じ列として混ぜる。
// - 解除: 子を元のレイヤー(同じ id)へ戻す。時刻は 1e-9 秒の格子に丸めてから足すので、まとめ・解除の往復で値が変わらない。
// - 並び: レイヤーの中のクリップは開始時刻の順に挿し込む。開始時刻が同じクリップの前後は、まとめ・解除で入れ替わることがある。

public enum CompoundEditing {
    /// 入れ子の深さの上限(クリップ自身を 1 として数える)。これより深いまとめは拒否し、読み込みでも深すぎる中身は描かない・混ぜない。
    public static let maxDepth = 8

    public static func supports(_ c: Clip) -> Bool { c.type == .compound }

    /// 時刻を 1e-9 秒の格子に丸める。UI の値は高々ミリ秒の桁なので、丸めても値は変わらない(往復で誤差が残らないための処理)。
    static func grid(_ x: Double) -> Double {
        guard x.isFinite, abs(x) < 1e6 else { return x }
        return (x * 1e9).rounded() / 1e9
    }

    /// 深さ(クリップ自身が 1。中身にさらに複合があれば、その深さを足す)。
    public static func depth(of c: Clip) -> Int {
        guard c.type == .compound else { return 1 }
        let inner = (c.tracks ?? []).flatMap { $0.clips }.map { depth(of: $0) }.max() ?? 0
        return 1 + inner
    }

    /// 循環があるか: 中身(または自分)に、祖先と同じ id の複合クリップがある。木の形の JSON では、id が重複したときだけ起きる。
    public static func hasCycle(_ c: Clip) -> Bool { cycle(c, ancestors: []) }

    private static func cycle(_ c: Clip, ancestors: Set<String>) -> Bool {
        guard c.type == .compound else { return false }
        if ancestors.contains(c.id) { return true }
        let next = ancestors.union([c.id])
        for tr in c.tracks ?? [] {
            for k in tr.clips where cycle(k, ancestors: next) { return true }
        }
        return false
    }

    /// 選んだクリップを 1 つの複合クリップにまとめる。2 つ未満・見つからないもの・ロックされたレイヤーのもの・
    /// 深さの上限を超えるもの・循環のあるものは nil。まとめた複合クリップは選んだクリップのうち最も前の元のレイヤーに、開始時刻順で入る。
    public static func group(_ p: Project, clipIds: [String]) -> (project: Project, compoundId: String)? {
        let wanted = Set(clipIds)
        guard wanted.count >= 2 else { return nil }
        var found: [(ti: Int, ci: Int)] = []
        for (ti, tr) in p.tracks.enumerated() {
            for (ci, c) in tr.clips.enumerated() where wanted.contains(c.id) { found.append((ti, ci)) }
        }
        guard found.count == wanted.count else { return nil }
        guard !found.contains(where: { p.tracks[$0.ti].isLocked }) else { return nil }
        let picked = found.map { p.tracks[$0.ti].clips[$0.ci] }
        guard picked.allSatisfy({ !hasCycle($0) }), 1 + (picked.map { depth(of: $0) }.max() ?? 0) <= maxDepth else { return nil }

        let m = picked.map(\.start).min() ?? 0
        let end = picked.map { $0.start + $0.duration }.max() ?? m

        // 中身: 元のレイヤーごとに、同じ id・名前・状態のレイヤーへ、選んだクリップだけを入れる(時刻は頭からの秒)
        var out = p
        var kids: [Track] = []
        for ti in Set(found.map(\.ti)).sorted() {
            var kt = p.tracks[ti]
            kt.clips = p.tracks[ti].clips.filter { wanted.contains($0.id) }.map { c in
                var k = c
                k.start = grid(c.start - m)
                return k
            }
            kids.append(kt)
            out.tracks[ti].clips.removeAll { wanted.contains($0.id) }
        }
        var compound = Clip()
        compound.type = .compound
        compound.start = m
        compound.duration = grid(end - m)
        compound.tracks = kids
        let home = found.map(\.ti).min() ?? 0
        insertByStart(compound, into: &out.tracks[home].clips)
        return (out, compound.id)
    }

    /// 複合クリップを解除する: 中身を元のレイヤー(同じ id。無ければ複合クリップのあったレイヤー)へ、開始時刻順に戻す。
    /// 複合クリップでない・見つからない・戻す先がロックされている場合は nil。戻した clip の id の並びを返す。
    public static func ungroup(_ p: Project, clipId: String) -> (project: Project, clipIds: [String])? {
        guard let loc = ClipEditing.locate(clipId, in: p) else { return nil }
        let comp = p.tracks[loc.track].clips[loc.index]
        guard comp.type == .compound, !p.tracks[loc.track].isLocked else { return nil }
        let kids = comp.tracks ?? []
        let targets = kids.map { kt in p.tracks.firstIndex { $0.id == kt.id } ?? loc.track }
        guard !targets.contains(where: { p.tracks[$0].isLocked }) else { return nil }
        var out = p
        out.tracks[loc.track].clips.remove(at: loc.index)
        var ids: [String] = []
        for (kt, target) in zip(kids, targets) {
            for k in kt.clips {
                var c = k
                c.start = grid(comp.start + k.start)
                insertByStart(c, into: &out.tracks[target].clips)
                ids.append(c.id)
            }
        }
        return (out, ids)
    }

    /// 中身を窓 [x, x + d)(複合の頭からの秒)で切り取り、窓の頭を 0 に詰める。窓の外のクリップは落とし、窓をまたぐものは切る
    /// (切るのは `ClipEditing.split` なので、フェード・キーフレーム・素材の位置も振り分けられる)。
    static func window(_ clips: [Clip], from x: Double, duration d: Double) -> [Clip] {
        var out: [Clip] = []
        for c in clips {
            var k = c
            let s = c.start, e = c.start + c.duration
            if e <= x + ClipEditing.timeEpsilon || s >= x + d - ClipEditing.timeEpsilon { continue }
            if s < x - ClipEditing.timeEpsilon, let (_, right) = ClipEditing.split(k, at: x) { k = right }
            if k.start + k.duration > x + d + ClipEditing.timeEpsilon, let (left, _) = ClipEditing.split(k, at: x + d) { k = left }
            k.start = grid(k.start - x)
            out.append(k)
        }
        return out
    }

    /// 複製・貼り付け用: クリップと、その中のすべての子に新しい id を振る(元と id が重ならないように)。
    public static func freshIds(_ c: Clip) -> Clip {
        var k = c
        k.id = newId()
        if let tr = c.tracks {
            k.tracks = tr.map { t in
                var u = t
                u.clips = t.clips.map(freshIds)
                return u
            }
        }
        return k
    }

    /// 開始時刻の順に挿す(同じ開始時刻なら後ろ。既に並んでいるクリップの順は変えない)。
    static func insertByStart(_ c: Clip, into clips: inout [Clip]) {
        let at = clips.firstIndex { $0.start > c.start } ?? clips.count
        clips.insert(c, at: at)
    }

    /// 音声の混ぜ用: レイヤーの消音・ソロ(`Project.isAudible`)を見て、音の出るクリップを、複合クリップの中まで平らにした列にする。
    /// 返すクリップの `start` は、プロジェクトの頭からの絶対時刻(複合クリップの中のものは親の頭を足す)。
    /// 中身の消音・ソロは、その複合クリップの中のレイヤーの間だけで決める。深すぎる・循環する複合クリップは混ぜない。
    public static func audibleClips(in p: Project) -> [Clip] {
        var out: [Clip] = []
        for tr in p.tracks where p.isAudible(tr) {
            flatten(tr.clips, base: nil, stack: [], into: &out)
        }
        return out
    }

    private static func flatten(_ clips: [Clip], base: Double?, stack: Set<String>, into out: inout [Clip]) {
        for c in clips {
            if c.type == .compound {
                guard stack.count < maxDepth, !stack.contains(c.id) else { continue }
                let abs = base.map { grid($0 + c.start) } ?? c.start
                let kids = c.tracks ?? []
                let solo = kids.contains { $0.isSolo }
                for kt in kids where !kt.isMuted && (!solo || kt.isSolo) {
                    // 描画と同じ窓: 複合の頭からの時刻 offset ... offset + duration の中身だけを、窓の頭へ詰めて流す
                    flatten(window(kt.clips, from: c.offset, duration: c.duration), base: abs, stack: stack.union([c.id]), into: &out)
                }
            } else {
                var x = c
                if let b = base { x.start = grid(b + c.start) }
                out.append(x)
            }
        }
    }
}
