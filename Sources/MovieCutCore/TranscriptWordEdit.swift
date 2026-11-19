import Foundation

/// 単語単位のテキスト編集: 単語の時刻を持つ文について、選んだ単語の区間だけを取り除く
/// ことと、選んだ単語を並べた順に組み立てる(Paper Edit の単語版)こと。
///
/// 文の取り除き(`TranscriptTextEdit` + `ClipEditing.removeSilence`)の単語版で、取り除きの
/// 経路は文のときとまったく同じ(無音カットと同じ経路。`ripple` で後ろを詰める)。
/// 違うのは「どの範囲を切るか」の決め方だけ: 文の範囲ではなく、単語 1 件の範囲を使う。
/// 組み立ては、単語 1 件を「文 1 件分の区間」に直してから、配置・重なり検査・失敗の
/// 扱いまで Paper Edit(`PaperEdit.assemble`)にそのまま任せる。
///
/// 割り切り(明示): 単語の時刻が無い文は単語単位では編集できない。文の範囲へ広げるような
/// 推定はせず、時刻の無い文の単語が 1 件でも選ばれていたら全体を失敗(nil)にする。
/// 画面側は `canEditWords` / 文の `hasWordTiming` で「文単位まで」を利用者へ明示する。
/// 画面にも Undo にも依存しない純粋な計算。
public enum TranscriptWordEdit {

    /// 単語 1 件の指定(文の番号と、その文の中での単語の番号)。
    public struct Selection: Equatable, Hashable, Sendable {
        public var sentence: Int
        public var word: Int
        public init(sentence: Int, word: Int) { self.sentence = sentence; self.word = word }
    }

    /// その文が単語単位で編集できるか(単語の時刻があるか)。
    public static func canEditWords(_ sentence: TranscriptSentence) -> Bool { sentence.hasWordTiming }

    /// 文の一覧のうち、単語単位で編集できる文の番号(開始順)。
    public static func wordEditableSentenceIndices(_ sentences: [TranscriptSentence]) -> [Int] {
        sentences.enumerated().compactMap { $0.element.hasWordTiming ? $0.offset : nil }
    }

    /// 選んだ単語を、取り除く範囲(クリップの頭からの秒)に直す。開始順。
    /// - 範囲外の文番号の指定は捨てる(Paper Edit の並び順の解決と同じ扱い)。
    /// - 単語の時刻が無い文の単語が 1 件でも混ざっていたら nil(全体を失敗。推定で文に広げない)。
    /// - 選択が空・有効な単語が無いときも nil。
    public static func cuts(sentences: [TranscriptSentence], selections: Set<Selection>) -> [SilenceRange]? {
        guard !selections.isEmpty else { return nil }
        var out: [SilenceRange] = []
        for sel in selections {
            guard sentences.indices.contains(sel.sentence) else { continue }
            let s = sentences[sel.sentence]
            guard s.hasWordTiming else { return nil }
            guard s.words.indices.contains(sel.word) else { continue }
            let w = s.words[sel.word]
            guard w.start.isFinite, w.end.isFinite, w.end - w.start > 1e-3 else { continue }
            out.append(SilenceRange(start: w.start, end: w.end))
        }
        guard !out.isEmpty else { return nil }
        return out.sorted { $0.start < $1.start }
    }

    /// 選んだ単語を取り除いた新しいプロジェクトを返す。
    /// 失敗の条件は文の取り除きと同じ(対象が無い・対象外・全部を取り除く等は
    /// `ClipEditing.removeSilence` が nil を返す)に、単語の時刻が無い文が混ざる場合が加わる。
    /// 元のプロジェクトは変更しない。
    public static func removeWords(in project: Project, clipId: String,
                                   sentences: [TranscriptSentence], selections: Set<Selection>,
                                   ripple: Bool) -> (project: Project, clipIds: [String])? {
        guard let cuts = cuts(sentences: sentences, selections: selections) else { return nil }
        return ClipEditing.removeSilence(in: project, clipId: clipId, cuts: cuts, ripple: ripple)
    }

    // MARK: 単語の組み立て(Paper Edit の単語版・並べ替え)

    /// 組み立ての並び(単語の指定の列)を、単語 1 件 = 区間 1 件の列に直す。並び順どおりで、
    /// 同じ単語が複数回出てきたらその回数だけ繰り返す(文の組み立てと同じ扱い)。
    /// 取り除きの `cuts` と違い、範囲外の指定も黙って捨てない: 並びは利用者が作った
    /// 順序そのものなので、解決できない指定(範囲外・単語の時刻が無い文・単語の時刻が
    /// 不正/短すぎる)が 1 件でもあれば全体を nil にする。選択が空のときも nil。
    public static func resolvedWords(sentences: [TranscriptSentence], order: [Selection]) -> [TranscriptSentence]? {
        guard !order.isEmpty else { return nil }
        var out: [TranscriptSentence] = []
        for sel in order {
            guard sentences.indices.contains(sel.sentence) else { return nil }
            let s = sentences[sel.sentence]
            guard s.hasWordTiming, s.words.indices.contains(sel.word) else { return nil }
            let w = s.words[sel.word]
            guard w.start.isFinite, w.end.isFinite, w.end - w.start > 1e-3 else { return nil }
            out.append(TranscriptSentence(text: w.text, start: w.start, end: w.end, words: [w]))
        }
        return out
    }

    /// 選んだ単語を並び順どおりに組み立てて、配置先へ置いた新しいプロジェクトを返す。
    /// 元のプロジェクト・元クリップは変更しない。失敗の条件は文の組み立て
    /// (`PaperEdit.assemble`)と同じものに、単語が解決できない場合が加わる。
    public static func assembleWords(in project: Project, sourceClipId: String,
                                     sentences: [TranscriptSentence], order: [Selection],
                                     destination: PaperEdit.Destination) -> (project: Project, clipIds: [String], sceneId: String?)? {
        guard let resolved = resolvedWords(sentences: sentences, order: order) else { return nil }
        return PaperEdit.assemble(in: project, sourceClipId: sourceClipId, sentences: resolved,
                                  order: Array(resolved.indices), destination: destination)
    }

    /// 組み立て列(単語)の 1 件を別の位置へ動かす。計算は文の組み立て列と同じ
    /// (`PaperEdit.moving`)を番号の列経由で使い、結果だけ単語の列に戻す。
    public static func movingWords(_ order: [Selection], from: Int, to: Int) -> [Selection] {
        PaperEdit.moving(Array(order.indices), from: from, to: to).map { order[$0] }
    }

    /// SwiftUI の `onMove` と同じ意味の並べ替え(シートでのドラッグ用)。計算は `PaperEdit.reordered`。
    public static func reorderedWords(_ order: [Selection], fromOffsets: IndexSet, toOffset: Int) -> [Selection] {
        PaperEdit.reordered(Array(order.indices), fromOffsets: fromOffsets, toOffset: toOffset).map { order[$0] }
    }

    /// 組み立て列(単語)の 1 件を隣と入れ替える(上へ/下へボタン用)。計算は `PaperEdit.movingEntry`。
    public static func movingWordEntry(_ order: [Selection], at pos: Int, by delta: Int) -> [Selection] {
        PaperEdit.movingEntry(Array(order.indices), at: pos, by: delta).map { order[$0] }
    }

    /// 組み立て列(単語)の 1 件を先頭または末尾へ動かす。計算は `PaperEdit.movingEntryToEdge`。
    public static func movingWordEntryToEdge(_ order: [Selection], at pos: Int, toEnd: Bool) -> [Selection] {
        PaperEdit.movingEntryToEdge(Array(order.indices), at: pos, toEnd: toEnd).map { order[$0] }
    }
}
