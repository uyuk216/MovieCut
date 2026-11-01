import Foundation

/// テロップ(文字クリップ)とセリフ(ボイスクリップ)の検索と一括置換。純粋な計算だけで、UI にも Undo にも依存しない。
/// 対象は文字の `text` と、ボイスの `text`(セリフ)。ロックされたレイヤーのクリップは置き換えない(数だけ `lockedMatches` に入れる)。
/// 一致は左から順に、重ならないように数える(置換も同じ数え方)。
public enum TextSearch {
    /// 大文字と小文字を区別するか。既定は区別しない(英字だけに効く。ひらがな・漢字はそのまま比べる)。
    public struct Options: Equatable {
        public var caseSensitive: Bool
        public init(caseSensitive: Bool = false) { self.caseSensitive = caseSensitive }
        var compare: String.CompareOptions { caseSensitive ? [] : [.caseInsensitive] }
    }

    /// 1 件の一致: クリップの文字の中の位置(文字数で数える、0 始まり)と長さ。
    public struct Match: Equatable {
        public var clipId: String
        public var location: Int
        public var length: Int
    }

    /// 文字が変わるクリップ。`isVoice` はボイスなら音声を作り直す必要がある、という印。
    public struct Change: Equatable {
        public var clipId: String
        public var text: String
        public var isVoice: Bool
    }

    public struct ReplaceResult {
        /// 置き換えた後のプロジェクト(何も変わらなければ元と同じ)。
        public var project: Project
        /// 文字が変わったクリップ(順番は並びどおり)。
        public var changes: [Change]
        /// 置き換えた一致の数。
        public var count: Int
        /// ロックされたレイヤーにあって置き換えなかった一致の数。
        public var lockedMatches: Int
        /// 置き換えると空になるセリフ(音声を作れないので変えなかった)の数。
        public var skippedEmptyVoices: Int
    }

    /// 対象の文字を持つクリップか(文字 / ボイスで、`text` があるもの)。
    static func isTarget(_ c: Clip) -> Bool {
        (c.type == .text || c.type == .voice) && c.text != nil
    }

    /// 文字の中の一致の範囲を、左から重ならないように返す。空の検索語は何も返さない。
    public static func ranges(of query: String, in text: String, options: Options) -> [Range<String.Index>] {
        guard !query.isEmpty else { return [] }
        var out: [Range<String.Index>] = []
        var i = text.startIndex
        while i < text.endIndex, let r = text.range(of: query, options: options.compare, range: i..<text.endIndex) {
            out.append(r)
            i = r.upperBound
        }
        return out
    }

    /// プロジェクト全体(または `scope` のクリップだけ)の一致を並びどおりに返す。ロックされたレイヤーも数える(表示用)。
    public static func matches(_ query: String, in project: Project, scope: Set<String>? = nil, options: Options = Options()) -> [Match] {
        var out: [Match] = []
        for track in project.tracks {
            for c in track.clips where isTarget(c) && (scope?.contains(c.id) ?? true) {
                let text = c.text ?? ""
                for r in ranges(of: query, in: text, options: options) {
                    let loc = text.distance(from: text.startIndex, to: r.lowerBound)
                    let len = text.distance(from: r.lowerBound, to: r.upperBound)
                    out.append(Match(clipId: c.id, location: loc, length: len))
                }
            }
        }
        return out
    }

    /// 一括置換。ロックされていないレイヤーの対象クリップだけを変える。検索語が空、または何も変わらないなら `changes` は空。
    public static func replaceAll(_ query: String, with replacement: String, in project: Project, scope: Set<String>? = nil, options: Options = Options()) -> ReplaceResult {
        var p = project
        var changes: [Change] = []
        var count = 0, locked = 0, skipped = 0
        guard !query.isEmpty else {
            return ReplaceResult(project: p, changes: [], count: 0, lockedMatches: 0, skippedEmptyVoices: 0)
        }
        for ti in project.tracks.indices {
            for ci in project.tracks[ti].clips.indices {
                let c = project.tracks[ti].clips[ci]
                guard isTarget(c), scope?.contains(c.id) ?? true else { continue }
                let text = c.text ?? ""
                let rs = ranges(of: query, in: text, options: options)
                guard !rs.isEmpty else { continue }
                if project.tracks[ti].isLocked { locked += rs.count; continue }
                // 一致を左から組み直す(数えたのと同じ並び)
                var new = ""
                var last = text.startIndex
                for r in rs {
                    new += text[last..<r.lowerBound]
                    new += replacement
                    last = r.upperBound
                }
                new += text[last...]
                guard new != text else { continue }
                if c.type == .voice, new.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    skipped += 1
                    continue
                }
                count += rs.count
                changes.append(Change(clipId: c.id, text: new, isVoice: c.type == .voice))
                p.tracks[ti].clips[ci].text = new
            }
        }
        return ReplaceResult(project: p, changes: changes, count: count, lockedMatches: locked, skippedEmptyVoices: skipped)
    }
}
