import Foundation

/// 台本(文字起こし)の文 1 件。時刻は **素材時刻**(クリップの `offset` と同じ軸)で、その文が「受け持つ」範囲。
/// 連動を始めるときに素材を文の頭で切り分けるので、範囲は隣の文の頭までに広がる(文と文の間の無音は前の文に含める)。
/// 速度・逆再生の無いクリップだけが対象(`TranscriptionSupport.supports`)なので、素材時刻とクリップ時刻は 1 対 1。
public struct ScriptSentence: Codable, Equatable, Identifiable, Sendable {
    public var id: String = newId()
    public var text: String
    public var start: Double
    public var end: Double
    /// 台本の上で文字を打ち直した文(誤認識の修正)。打ち直しは台本の文字だけを変え、音声・タイムラインは変えない。
    public var edited: Bool? = nil
    public init(id: String? = nil, text: String, start: Double, end: Double, edited: Bool? = nil) {
        self.id = id ?? newId(); self.text = text; self.start = start; self.end = end; self.edited = edited
    }
}

/// 1 つの素材(`src`)についての台本。文の並び(配列の順)が「台本としての並び」。
/// タイムラインとの対応は `Clip.scriptSentenceId` が持つ(クリップ側に永続化)。対応の状態(対応済み・一部・対応なし)は
/// クリップの素材範囲と文の範囲から毎回再計算するので、保存するのはこの文の一覧とクリップの印だけ。
public struct TranscriptScript: Codable, Equatable, Identifiable, Sendable {
    public var id: String = newId()
    public var src: String
    public var sentences: [ScriptSentence]
    public init(id: String? = nil, src: String, sentences: [ScriptSentence]) {
        self.id = id ?? newId(); self.src = src; self.sentences = sentences
    }
}

/// 台本とタイムラインの双方向編集。画面にも Undo にも依存しない純粋な計算(Undo はアプリ側が `edit` 1 回で包む)。
///
/// - 対応付け: クリップの `scriptSentenceId` が文を指す。素材範囲(`offset`〜`offset + duration`)と文の範囲の重なりで、
///   文がどれだけタイムラインに残っているか(`Coverage`)を毎回求める。クリップを分割しても両方の印は残り、
///   削除・トリムすれば範囲が欠けて「一部」「対応なし」になる(黙って消さない)。
/// - 台本→タイムライン: 文の削除(対応クリップを取り除く)・並べ替え(対応クリップを台本の順に敷き直す)。
/// - タイムライン→台本: 状態は再計算で追随し、台本の表示順もタイムライン上の順に追随する(`rows`)。
/// - 対象外: 速度変更・逆再生・速度ランプのクリップ(開始時に断る)。
public enum TranscriptScripting {

    /// 文がタイムラインにどれだけ残っているか。
    public enum Coverage: Equatable, Sendable {
        /// 文の範囲が全部ある。
        case linked
        /// 一部だけ残っている(クリップが削られた・片方だけ消された)。
        case partial
        /// 対応するクリップが無い(削除された・外された)。
        case unlinked
    }

    /// 台本ビューの 1 行。
    public struct Row: Equatable, Sendable {
        public var sentence: ScriptSentence
        public var coverage: Coverage
        /// 対応するクリップ(タイムライン上の開始順)。
        public var clipIds: [String]
        /// 対応クリップの一番早い開始時刻(対応なしは nil)。
        public var timelineStart: Double?
    }

    static let eps = 1e-3

    // MARK: 検索

    public static func script(withId id: String, in project: Project) -> TranscriptScript? {
        project.transcriptScripts.first { $0.id == id }
    }

    /// その素材の台本(無ければ nil)。
    public static func script(forSrc src: String, in project: Project) -> TranscriptScript? {
        project.transcriptScripts.first { $0.src == src }
    }

    /// 文に対応するクリップの場所(トップレベルのレイヤーだけ)。
    static func linkedLocations(_ sentenceId: String, src: String, in project: Project) -> [(track: Int, index: Int)] {
        var out: [(Int, Int)] = []
        for (ti, tr) in project.tracks.enumerated() {
            for (ci, c) in tr.clips.enumerated() where c.scriptSentenceId == sentenceId && c.src == src { out.append((ti, ci)) }
        }
        return out
    }

    /// 文の範囲のうち、対応クリップが覆っている割合から状態を求める(重複は和集合で数える)。
    public static func coverage(of sentence: ScriptSentence, src: String, in project: Project) -> Coverage {
        let locs = linkedLocations(sentence.id, src: src, in: project)
        guard !locs.isEmpty else { return .unlinked }
        let span = sentence.end - sentence.start
        guard span > eps else { return .linked }
        var ivs: [(Double, Double)] = []
        for l in locs {
            let c = project.tracks[l.track].clips[l.index]
            let a = max(sentence.start, c.offset), b = min(sentence.end, c.offset + c.duration)
            if b - a > 1e-6 { ivs.append((a, b)) }
        }
        guard !ivs.isEmpty else { return .unlinked }
        ivs.sort { $0.0 < $1.0 }
        var covered = 0.0
        var cur = ivs[0]
        for iv in ivs.dropFirst() {
            if iv.0 <= cur.1 { cur.1 = max(cur.1, iv.1) } else { covered += cur.1 - cur.0; cur = iv }
        }
        covered += cur.1 - cur.0
        return covered >= span - eps ? .linked : .partial
    }

    /// 台本ビューの行。表示順は、タイムラインに残っている文は **タイムライン上の順** に並べ(文を並べ替えた・
    /// クリップを動かした結果が台本へ追随する)、対応なしの文は台本の元の位置(他の文の間の隙間)に残す。
    public static func rows(of script: TranscriptScript, in project: Project) -> [Row] {
        var rows: [Row] = script.sentences.map { s in
            let locs = linkedLocations(s.id, src: script.src, in: project)
            let clips = locs.map { project.tracks[$0.track].clips[$0.index] }.sorted { $0.start < $1.start }
            return Row(sentence: s, coverage: coverage(of: s, src: script.src, in: project),
                       clipIds: clips.map(\.id), timelineStart: clips.first?.start)
        }
        let slots = rows.indices.filter { rows[$0].coverage != .unlinked }
        let placed = slots.map { rows[$0] }.enumerated()
            .sorted { a, b in
                let ta = a.element.timelineStart ?? 0, tb = b.element.timelineStart ?? 0
                return ta != tb ? ta < tb : a.offset < b.offset
            }.map(\.element)
        for (k, slot) in slots.enumerated() { rows[slot] = placed[k] }
        return rows
    }

    // MARK: 連動の開始

    /// 選んだクリップを文の頭で切り分けて、台本と連動させる。
    /// 切れ目は文の開始(最初の文はクリップの頭、最後の文はクリップの終わりまで)。タイムライン上の見た目・長さは変わらない。
    /// 失敗(nil): 対象外のクリップ(速度・逆再生・ランプ)・ロックされている・文が無い・文の開始が単調増加でない(重なる・
    /// 1ms 以内)・同じ素材に台本が既にある。
    public static func link(in project: Project, clipId: String,
                            sentences: [TranscriptSentence]) -> (project: Project, scriptId: String)? {
        guard let loc = ClipEditing.locate(clipId, in: project) else { return nil }
        let clip = project.tracks[loc.track].clips[loc.index]
        guard TranscriptionSupport.supports(clip), let src = clip.src, !project.tracks[loc.track].isLocked,
              clip.locked != true, !sentences.isEmpty,
              script(forSrc: src, in: project) == nil else { return nil }
        let dur = clip.duration
        let ordered = sentences.sorted { $0.start < $1.start }
        // 切れ目(クリップの頭からの秒)。最初は 0、以降は文の開始をクリップの内側に収めたもの
        var bounds: [Double] = [0]
        for s in ordered.dropFirst() {
            guard s.start.isFinite else { return nil }
            let b = min(max(0, s.start), dur)
            guard b > bounds.last! + eps, b < dur - eps else { return nil }
            bounds.append(b)
        }
        bounds.append(dur)
        var scripted: [ScriptSentence] = []
        var pieces: [Clip] = []
        var rest = clip
        for (i, s) in ordered.enumerated() {
            let a = bounds[i], b = bounds[i + 1]
            var piece = rest
            if i < ordered.count - 1 {
                guard let (l, r) = ClipEditing.split(rest, at: clip.start + b) else { return nil }
                piece = l; rest = r
            }
            let sent = ScriptSentence(text: s.text, start: clip.offset + a, end: clip.offset + b)
            piece.scriptSentenceId = sent.id
            pieces.append(piece)
            scripted.append(sent)
        }
        var out = project
        out.tracks[loc.track].clips.replaceSubrange(loc.index...loc.index, with: pieces)
        let sc = TranscriptScript(src: src, sentences: scripted)
        out.transcriptScripts.append(sc)
        return (out, sc.id)
    }

    // MARK: 台本 → タイムライン

    /// 文を削除する: 対応クリップをタイムラインから取り除く。文自体は台本に「対応なし」として残る(元に戻す・
    /// 復元ができる)。`ripple` なら、取り除いた分だけ同じレイヤーの後ろを詰める。
    /// 失敗(nil): 台本・文が無い・対応クリップが無い・ロックされたレイヤー/クリップが含まれる。
    public static func deleteSentence(in project: Project, scriptId: String, sentenceId: String, ripple: Bool) -> Project? {
        guard let sc = script(withId: scriptId, in: project), sc.sentences.contains(where: { $0.id == sentenceId }) else { return nil }
        let locs = linkedLocations(sentenceId, src: sc.src, in: project)
        guard !locs.isEmpty else { return nil }
        var out = project
        for ti in Set(locs.map(\.track)) {
            guard !out.tracks[ti].isLocked else { return nil }
            let victims = out.tracks[ti].clips.filter { $0.scriptSentenceId == sentenceId && $0.src == sc.src }
            guard victims.allSatisfy({ $0.locked != true }) else { return nil }
            let ids = Set(victims.map(\.id))
            out.tracks[ti].clips.removeAll { ids.contains($0.id) }
            if ripple {
                // 後ろのクリップから順に、取り除いたクリップの長さだけ左へ詰める
                for v in victims.sorted(by: { $0.start > $1.start }) {
                    let end = v.start + v.duration
                    for i in out.tracks[ti].clips.indices where out.tracks[ti].clips[i].start >= end - ClipEditing.timeEpsilon {
                        out.tracks[ti].clips[i].start = max(0, out.tracks[ti].clips[i].start - v.duration)
                    }
                }
            }
        }
        return out
    }

    /// 台本の並び(文の id の列)を `order` に直し、対応クリップをその順に敷き直す。
    /// 敷き直しは、レイヤーごとに「対応クリップの先頭の開始時刻」から隙間なく並べる(文の中のクリップの相対位置は保つ)。
    /// 対応していないクリップと重なるとき・ロックされているときは nil(黙って重ねない)。
    public static func applyOrder(in project: Project, scriptId: String, order: [String]) -> Project? {
        guard let si = project.transcriptScripts.firstIndex(where: { $0.id == scriptId }) else { return nil }
        let sc = project.transcriptScripts[si]
        guard order.count == sc.sentences.count, Set(order) == Set(sc.sentences.map(\.id)) else { return nil }
        let byId = Dictionary(uniqueKeysWithValues: sc.sentences.map { ($0.id, $0) })
        var out = project
        out.transcriptScripts[si].sentences = order.compactMap { byId[$0] }
        return relayout(project: out, scriptIndex: si)
    }

    /// 台本ビューの表示順(`rows`)で、`fromOffsets` の行を `toOffset` へ動かして、タイムラインへ反映する。
    /// 並べ替えの計算は Paper Edit と同じ(`PaperEdit.reordered`)。不正な指定・敷き直せないときは nil。
    public static func reorder(in project: Project, scriptId: String, fromOffsets: IndexSet, toOffset: Int) -> Project? {
        guard let sc = script(withId: scriptId, in: project) else { return nil }
        let ids = rows(of: sc, in: project).map(\.sentence.id)
        let idx = PaperEdit.reordered(Array(ids.indices), fromOffsets: fromOffsets, toOffset: toOffset)
        guard idx != Array(ids.indices) else { return nil }
        return applyOrder(in: project, scriptId: scriptId, order: idx.map { ids[$0] })
    }

    /// 対応なしの文をタイムラインへ戻す: 同じ台本の別のクリップを雛形に、文の範囲のクリップを作り、台本の並びの位置へ敷く。
    /// 雛形になる対応クリップが無い・重なる・ロック時は nil。
    public static func restoreSentence(in project: Project, scriptId: String, sentenceId: String) -> Project? {
        guard let si = project.transcriptScripts.firstIndex(where: { $0.id == scriptId }) else { return nil }
        let sc = project.transcriptScripts[si]
        guard let s = sc.sentences.first(where: { $0.id == sentenceId }),
              coverage(of: s, src: sc.src, in: project) == .unlinked,
              let anyLoc = sc.sentences.lazy.compactMap({ linkedLocations($0.id, src: sc.src, in: project).first }).first else { return nil }
        let tpl = project.tracks[anyLoc.track].clips[anyLoc.index]
        guard !project.tracks[anyLoc.track].isLocked, s.end - s.start > eps else { return nil }
        var c = tpl
        c.id = newId()
        c.scriptSentenceId = s.id
        c.offset = s.start
        c.duration = s.end - s.start
        c.fadeIn = nil; c.fadeOut = nil; c.transitionIn = nil; c.transitionOut = nil
        c.keyframes = [:]
        let end = project.tracks[anyLoc.track].clips.map { $0.start + $0.duration }.max() ?? 0
        c.start = end
        var out = project
        CompoundEditing.insertByStart(c, into: &out.tracks[anyLoc.track].clips)
        return relayout(project: out, scriptIndex: si)
    }

    /// 台本の文字を打ち直す(誤認識の修正)。台本の文字だけが変わり、音声・タイムラインは変わらない。
    /// 空白だけ・同じ文字・文が無いときは nil。
    public static func retext(in project: Project, scriptId: String, sentenceId: String, text: String) -> Project? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let si = project.transcriptScripts.firstIndex(where: { $0.id == scriptId }),
              let ci = project.transcriptScripts[si].sentences.firstIndex(where: { $0.id == sentenceId }),
              project.transcriptScripts[si].sentences[ci].text != t else { return nil }
        var out = project
        out.transcriptScripts[si].sentences[ci].text = t
        out.transcriptScripts[si].sentences[ci].edited = true
        return out
    }

    /// 台本を外す(連動をやめる): 台本とクリップの印を消す。クリップは変えない。
    public static func unlink(in project: Project, scriptId: String) -> Project? {
        guard let sc = script(withId: scriptId, in: project) else { return nil }
        var out = project
        let ids = Set(sc.sentences.map(\.id))
        for ti in out.tracks.indices {
            for ci in out.tracks[ti].clips.indices {
                if let sid = out.tracks[ti].clips[ci].scriptSentenceId, ids.contains(sid) { out.tracks[ti].clips[ci].scriptSentenceId = nil }
            }
        }
        out.transcriptScripts.removeAll { $0.id == scriptId }
        return out
    }

    // MARK: 敷き直し

    /// 台本の文の順に、対応クリップをレイヤーごとに敷き直す。
    static func relayout(project: Project, scriptIndex si: Int) -> Project? {
        let sc = project.transcriptScripts[si]
        let ids = Set(sc.sentences.map(\.id))
        var out = project
        for ti in out.tracks.indices {
            let all = out.tracks[ti].clips
            let linked = all.filter { c in c.src == sc.src && (c.scriptSentenceId.map(ids.contains) ?? false) }
            guard !linked.isEmpty else { continue }
            guard !out.tracks[ti].isLocked, linked.allSatisfy({ $0.locked != true }) else { return nil }
            let others = all.filter { c in !linked.contains { $0.id == c.id } }
            var cursor = linked.map(\.start).min() ?? 0
            var placed: [Clip] = []
            for s in sc.sentences {
                let group = linked.filter { $0.scriptSentenceId == s.id }.sorted { $0.start < $1.start }
                guard let first = group.first else { continue }
                var groupEnd = cursor
                for var c in group {
                    c.start = cursor + (c.start - first.start)
                    groupEnd = max(groupEnd, c.start + c.duration)
                    placed.append(c)
                }
                cursor = groupEnd
            }
            let blockStart = placed.map(\.start).min() ?? 0
            let overlaps = others.contains { o in
                o.start < cursor - ClipEditing.timeEpsilon && o.start + o.duration > blockStart + ClipEditing.timeEpsilon
            }
            guard !overlaps else { return nil }
            out.tracks[ti].clips = (others + placed).enumerated()
                .sorted { $0.element.start != $1.element.start ? $0.element.start < $1.element.start : $0.offset < $1.offset }
                .map(\.element)
        }
        return out
    }
}
