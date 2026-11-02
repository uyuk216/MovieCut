import Foundation

// MARK: - 重なったクリップの音だけを試聴(スクラブ試聴)
//
// 音のクリップが同じ時刻に重なっていると、全体のミックスでは「どのクリップがどう鳴っているか」が聞き分けにくい。
// 試聴は、選んだ 1 つのクリップだけを(他のクリップを混ぜず)再生位置から短く鳴らす。
// - 対象は `CompoundEditing.audibleClips`(レイヤーの消音・ソロを反映し、複合クリップの中まで平らにしたもの)。
// - 鳴らす音は `AudioMixer` を、そのクリップだけのプロジェクトに対して短い範囲で回して作る(速度・音量・エフェクト・フェードはそのまま効く)。
// - プロジェクトは変えない(Undo に載らない)。他のクリップがいないので、ダッキングは効かない。
public enum AudioAudition {
    /// スクラブ 1 回で鳴らす長さ(秒)。
    public static let snippetLength = 0.5
    /// これより短い残りは鳴らさない(秒)。
    public static let minSnippet = 0.02

    /// 音を出すクリップか(音声・ボイス・動画で、素材があり、フリーズでなく、長さがある)。
    static func makesSound(_ c: Clip) -> Bool {
        guard c.type == .audio || c.type == .voice || c.type == .video else { return false }
        guard let s = c.src, !s.isEmpty, c.duration > 0, !c.isFreeze else { return false }
        return true
    }

    /// 時刻 t に鳴っているクリップ(下のレイヤーから順。複合クリップの中身は、絶対時刻にして平らにしたもの)。
    public static func audibleClips(at t: Double, in p: Project) -> [Clip] {
        guard t.isFinite else { return [] }
        return CompoundEditing.audibleClips(in: p).filter {
            makesSound($0) && t >= $0.start - ClipEditing.timeEpsilon && t < $0.start + $0.duration - ClipEditing.timeEpsilon
        }
    }

    /// 時刻 t に鳴っているクリップの id。
    public static func audibleIds(at t: Double, in p: Project) -> [String] {
        audibleClips(at: t, in: p).map(\.id)
    }

    /// 巡回: `current` の次の id(最後なら先頭へ)。`current` が候補に無ければ先頭。候補が無ければ nil。
    public static func next(after current: String?, in ids: [String]) -> String? {
        guard !ids.isEmpty else { return nil }
        guard let c = current, let i = ids.firstIndex(of: c) else { return ids[0] }
        return ids[(i + 1) % ids.count]
    }

    /// 試聴の対象を決める。いまの対象が時刻 t に鳴っていればそれ、無ければ選択中のクリップ、それも無ければ先頭の候補。
    public static func target(current: String?, selected: String?, at t: Double, in p: Project) -> String? {
        let ids = audibleIds(at: t, in: p)
        if let c = current, ids.contains(c) { return c }
        if let s = selected, ids.contains(s) { return s }
        return ids.first
    }

    /// 鳴らす範囲: 時刻 t から `length` 秒(クリップの終わりまで)。残りが短すぎるときは nil。
    public static func snippetRange(clip: Clip, at t: Double, length: Double = snippetLength) -> ExportRange? {
        let s = max(t, clip.start)
        let e = min(t + max(length, 0), clip.start + clip.duration)
        guard s.isFinite, e.isFinite, e - s >= minSnippet else { return nil }
        return ExportRange(start: s, end: e)
    }

    /// そのクリップだけを置いたプロジェクト(絶対時刻のまま。複合クリップの中のクリップも、平らにした位置で)。見つからなければ nil。
    public static func soloProject(_ p: Project, clipId: String) -> Project? {
        guard let c = CompoundEditing.audibleClips(in: p).first(where: { $0.id == clipId && makesSound($0) }) else { return nil }
        var out = Project()
        out.width = p.width; out.height = p.height; out.fps = p.fps
        out.characters = []
        var tr = Track(name: "試聴")
        tr.clips = [c]
        out.tracks = [tr]
        return out
    }

    /// 試聴用の短い音を `url`(CAF)に書き、書いた長さ(秒)を返す。鳴らせないとき(対象が無い・範囲が短い)は nil。
    /// 読めない素材は例外(呼び出し側で状態欄に出す)。
    @discardableResult
    public static func renderSnippet(project p: Project, clipId: String, at t: Double, length: Double = snippetLength, to url: URL) throws -> Double? {
        guard let solo = soloProject(p, clipId: clipId), let clip = solo.tracks.first?.clips.first,
              let r = snippetRange(clip: clip, at: t, length: length) else { return nil }
        let res = try AudioMixer.mixdownDetailed(project: solo, to: url, range: r)
        return res.sourceCount > 0 ? res.duration : nil
    }
}
