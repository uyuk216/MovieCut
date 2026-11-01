import Foundation

/// 台本から字幕トラックを作る(B-3 の残り。画面にも Undo にも依存しない純粋な処理)。
///
/// ボイス(セリフ)は描画の時点で字幕として出る(`subtitle != false`)。そのまま文字クリップを足すと二重に出るので、
/// 生成するときは元のボイスの「字幕を出す」を切る(`subtitle = false`)。文字クリップが字幕の表示を引き継ぐ。
/// 切ったボイスは次の生成の対象から外れるので、もう一度実行しても何も足さない(冪等)。
public enum SubtitleGeneration {
    public struct Result: Equatable {
        public var project: Project
        /// 生成した文字クリップの数(ボイスの数と同じ)。
        public var count: Int
    }

    /// 対象のボイス: 字幕オン(未設定は描画と同じくオン)・本文がある・長さが 0 より大きい・非表示でもロックでもないトラック。
    static func targets(in project: Project) -> [(track: Int, clip: Int, cue: SubtitleCue)] {
        var out: [(track: Int, clip: Int, cue: SubtitleCue)] = []
        for (ti, tr) in project.tracks.enumerated() where !tr.isHidden && !tr.isLocked {
            for (ci, c) in tr.clips.enumerated() where c.type == .voice && c.subtitle != false && c.duration > 0 {
                let body = SubtitleFile.cleanBody(c.text ?? "")
                guard !body.isEmpty else { continue }
                out.append((ti, ci, SubtitleCue(start: c.start, end: c.start + c.duration, text: body)))
            }
        }
        return out
    }

    /// 生成できるボイスが 1 つでもあるか(メニューの有効・無効に使う)。
    public static func hasTargets(_ project: Project) -> Bool { !targets(in: project).isEmpty }

    /// 台本(ボイス)から字幕の文字クリップを作る。`style` があれば文字の見た目(色・縁・装飾)を当てる。
    /// 生成が無ければ nil(何も変えない)。新しい文字クリップは「字幕」「字幕 2」…の新しいレイヤーに、重ならないように入れる。
    public static func generate(_ project: Project, style: TextLook?) -> Result? {
        let found = targets(in: project)
        guard !found.isEmpty else { return nil }
        var p = project
        var clips: [Clip] = []
        for t in found.sorted(by: { ($0.cue.start, $0.track, $0.clip) < ($1.cue.start, $1.track, $1.clip) }) {
            var clip = SubtitleImport.makeClip(t.cue, project: project)
            if let style { style.apply(to: &clip) }
            clips.append(clip)
        }
        for t in found { p.tracks[t.track].clips[t.clip].subtitle = false }
        SubtitleImport.appendLanes(clips, to: &p)
        return Result(project: p, count: clips.count)
    }
}
