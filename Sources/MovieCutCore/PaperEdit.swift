import Foundation

/// Paper Edit(Premiere Pro 26.5 の同名機能の等価): 文字起こしの文一覧から行を選び、その並び順のまま
/// 対応する区間のクリップ列を組み立てて、タイムラインまたは新しいシーンへ配置するラフ編集機能。
///
/// 既存の「文字起こしで編集」(`TranscriptTextEdit` / `ClipEditing.removeSilence`、チェックを外した文を
/// 元クリップから取り除く)とは別機能で、こちらは元クリップを一切変更しない(参照区間から新しい
/// クリップを作るだけ)。画面にも Undo にも依存しない純粋な計算。
///
/// 時刻の前提は文字起こしと同じ: 対象クリップは素材時刻とクリップ時刻が 1 対 1
/// (`TranscriptionSupport.supports`。速度・逆再生・速度ランプのあるクリップは対象外)。
/// 文(`TranscriptSentence`)の時刻はクリップの頭からの秒。
public enum PaperEdit {

    /// 組み立ての配置先。
    public enum Destination: Equatable, Sendable {
        /// 指定レイヤーの指定時刻から、隙間なく並べる。既存クリップと重なるときは失敗する。
        case timeline(trackIndex: Int, startAt: Double)
        /// 指定レイヤーの末尾(そのレイヤーの最後のクリップの終わり)から並べる。
        case appendToTrack(Int)
        /// 新しいシーン定義を作り、そのレイヤーに 0 秒から並べる。タイムライン自体には置かない
        /// (作ったシーンはシーン一覧から通常の手順で配置できる)。
        case newScene(name: String)
    }

    // MARK: 選択の解決

    /// 並び順の指定(文の番号の列)を、文の列に直す。
    /// - 並び順は指定どおり(元の時刻順とは限らない。並べ替えができる)。
    /// - 範囲外の番号は捨てる。
    /// - 同じ番号が複数回出てきたら、その回数だけ文を繰り返す(重複選択は「同じ区間を繰り返し使う」として扱う)。
    public static func orderedSentences(from sentences: [TranscriptSentence], order: [Int]) -> [TranscriptSentence] {
        order.compactMap { sentences.indices.contains($0) ? sentences[$0] : nil }
    }

    // MARK: 区間 → クリップ

    /// 文 1 件に対応する区間を、元クリップから切り出した新しいクリップにする(新しい id・配置時刻 `startAt`)。
    /// 切り出しは `ClipEditing.split` を使うので、キーフレーム・音声フェード・トランジションの
    /// 振り分けは通常の分割と同じになる。文の区間はクリップの長さの内側に収める。
    /// 元クリップが文字起こしの対象外・区間が短すぎる(1ms 以下)ときは nil。元クリップは変更しない。
    public static func subclip(source: Clip, sentence: TranscriptSentence, startAt: Double) -> Clip? {
        guard TranscriptionSupport.supports(source) else { return nil }
        let dur = source.duration
        guard dur > 0, sentence.start.isFinite, sentence.end.isFinite, startAt.isFinite, startAt >= 0 else { return nil }
        let a = min(max(0, sentence.start), dur)
        let b = min(max(a, sentence.end), dur)
        guard b - a > 1e-3 else { return nil }
        // split はプロジェクト時刻で切るので、頭を 0 にそろえた作業用コピーで切る
        var work = source
        work.start = 0
        var seg = work
        if a > ClipEditing.timeEpsilon {
            guard let (_, right) = ClipEditing.split(work, at: a) else { return nil }
            seg = right
        }
        if b < dur - ClipEditing.timeEpsilon {
            guard let (left, _) = ClipEditing.split(seg, at: b) else { return nil }
            seg = left
        }
        seg.id = newId()
        seg.start = startAt
        return seg
    }

    /// 選んだ文の列(並び順どおり)から、`startAt` から隙間なく並ぶクリップ列を作る。
    /// 1 件でも切り出せない文があれば、黙って飛ばさず全体を nil にする。
    public static func clips(source: Clip, ordered: [TranscriptSentence], startAt: Double) -> [Clip]? {
        guard !ordered.isEmpty, startAt.isFinite, startAt >= 0 else { return nil }
        var out: [Clip] = []
        var t = startAt
        for s in ordered {
            guard let c = subclip(source: source, sentence: s, startAt: t) else { return nil }
            out.append(c)
            t += c.duration
        }
        return out
    }

    // MARK: 組み立て(プロジェクトへの配置)

    /// 選んだ文からクリップ列を組み立てて、配置先へ置いた新しいプロジェクトを返す。
    /// 元のプロジェクト・元クリップは変更しない。失敗(対象が無い・対象外・選択が空・配置先が
    /// ロックされている／埋まっている・シーン名が空)のときは nil。
    /// - Returns: 新しいプロジェクト、作ったクリップの id(並び順)、シーンを作ったときはその id。
    public static func assemble(in project: Project, sourceClipId: String,
                                sentences: [TranscriptSentence], order: [Int],
                                destination: Destination) -> (project: Project, clipIds: [String], sceneId: String?)? {
        guard let loc = ClipEditing.locate(sourceClipId, in: project) else { return nil }
        let source = project.tracks[loc.track].clips[loc.index]
        guard TranscriptionSupport.supports(source) else { return nil }
        let ordered = orderedSentences(from: sentences, order: order)
        guard !ordered.isEmpty else { return nil }

        var out = project
        switch destination {
        case .newScene(let name):
            let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !n.isEmpty else { return nil }
            guard let made = clips(source: source, ordered: ordered, startAt: 0) else { return nil }
            var track = Track(name: project.tracks[loc.track].name)
            track.clips = made
            let scene = SceneDefinition(id: newId(), name: n, tracks: [track])
            out.scenes.append(scene)
            return (out, made.map(\.id), scene.id)

        case .timeline(let trackIndex, let startAt):
            guard startAt.isFinite else { return nil }
            return placeOnTimeline(project: out, source: source, ordered: ordered,
                                   trackIndex: trackIndex, startAt: max(0, startAt))

        case .appendToTrack(let trackIndex):
            guard out.tracks.indices.contains(trackIndex) else { return nil }
            let start = out.tracks[trackIndex].clips.map { $0.start + $0.duration }.filter { $0.isFinite }.max() ?? 0
            return placeOnTimeline(project: out, source: source, ordered: ordered,
                                   trackIndex: trackIndex, startAt: start)
        }
    }

    /// タイムラインの 1 レイヤーへ、クリップ列を開始時刻順に差し込む。
    /// レイヤーがロックされている・既存クリップと重なるときは nil(黙って重ねない)。
    static func placeOnTimeline(project: Project, source: Clip, ordered: [TranscriptSentence],
                                trackIndex: Int, startAt: Double) -> (project: Project, clipIds: [String], sceneId: String?)? {
        var out = project
        guard out.tracks.indices.contains(trackIndex), !out.tracks[trackIndex].isLocked else { return nil }
        guard let made = clips(source: source, ordered: ordered, startAt: startAt) else { return nil }
        let end = made.last.map { $0.start + $0.duration } ?? startAt
        let overlaps = out.tracks[trackIndex].clips.contains {
            $0.start < end - ClipEditing.timeEpsilon && $0.start + $0.duration > startAt + ClipEditing.timeEpsilon
        }
        guard !overlaps else { return nil }
        for c in made { CompoundEditing.insertByStart(c, into: &out.tracks[trackIndex].clips) }
        return (out, made.map(\.id), nil)
    }
}
