import Foundation

/// 候補クリップを比較して差し替える(候補 36 オーディション)。選んだクリップの「素材だけ」を別の候補に取り替える。
/// 位置・大きさ・エフェクト・トランジション・キーフレーム・音量などの設定、タイムライン上の頭と長さはそのまま。
/// 候補は同じ種類(動画は動画、画像は画像、音声は音声)の、取り込み済みの素材(`mediaPool`)と他のクリップが使っている素材。
/// 画面を持たない純粋な計算(素材の長さの測定は呼び出し側)。
public enum CandidateSwap {
    public struct Candidate: Equatable, Identifiable {
        public var id: String { path }
        public var path: String
        public var kind: ClipType
        public var name: String { (path as NSString).lastPathComponent }
        public init(path: String, kind: ClipType) { self.path = path; self.kind = kind }
    }

    /// 差し替えられるクリップか: 動画・音声・画像で素材があり、フリーズ(1 コマ固定)でも、ロックされてもいない。
    public static func supports(_ c: Clip) -> Bool {
        (c.type == .video || c.type == .audio || c.type == .image) && (c.src.map { !$0.isEmpty } ?? false) && !c.isFreeze && !c.isClipLocked
    }

    /// そのクリップの候補(今の素材は除く)。取り込み済みの素材 → 他のクリップが使う素材(複合クリップの中も)→ `extra`(利用者が足したもの)の順。
    /// 種類は拡張子で決める(`ClipEditing.kindOf`)。同じパスは 1 度だけ。
    public static func candidates(for clip: Clip, in project: Project, extra: [String] = []) -> [Candidate] {
        guard supports(clip) else { return [] }
        var seen: Set<String> = [clip.src ?? ""]
        var out: [Candidate] = []
        func add(_ path: String) {
            guard !path.isEmpty, !seen.contains(path), ClipEditing.kindOf(path: path) == clip.type else { return }
            seen.insert(path)
            out.append(Candidate(path: path, kind: clip.type))
        }
        project.mediaPool.forEach(add)
        func walk(_ tracks: [Track]) {
            for tr in tracks { for c in tr.clips {
                if c.type == clip.type, let s = c.src { add(s) }
                if let inner = c.tracks { walk(inner) }
            } }
        }
        walk(project.tracks)
        extra.forEach(add)
        return out
    }

    /// 素材を取り替えたクリップ。取り替えられない(未対応・同じ素材・種類が違う)ときは nil。
    /// - `sourceDuration`: 新しい素材の長さ(動画・音声。測れなければ nil)。
    /// 素材の頭(`offset`)は 0 に戻し、速度どおりに使うと素材が足りなくなるときは、足りる長さまでクリップを短くする
    /// (速度ランプのクリップは長さを変えない)。
    public static func swapped(_ clip: Clip, to cand: Candidate, sourceDuration: Double?) -> Clip? {
        guard supports(clip), cand.kind == clip.type, cand.path != clip.src else { return nil }
        var c = clip
        c.src = cand.path
        c.offset = 0
        if clip.type == .image {
            c.srcDuration = nil
            return c
        }
        if let d = sourceDuration, d.isFinite, d > 0 {
            c.srcDuration = d
            if clip.rampPoints == nil {
                let sp = max(clip.effectiveSpeed, 1e-6)
                let room = d / sp
                if room < c.duration { c.duration = max(ClipEditing.minDuration, room) }
            }
        } else {
            c.srcDuration = clip.srcDuration
        }
        return c
    }

    /// プロジェクトの中のクリップを取り替える。
    public static func swap(in project: Project, clipId: String, to cand: Candidate, sourceDuration: Double?) -> Project? {
        guard let loc = ClipEditing.locate(clipId, in: project),
              let n = swapped(project.tracks[loc.track].clips[loc.index], to: cand, sourceDuration: sourceDuration) else { return nil }
        var p = project
        p.tracks[loc.track].clips[loc.index] = n
        return p
    }
}
