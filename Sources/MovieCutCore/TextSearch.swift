import Foundation

/// テロップ(文字クリップ)とセリフ(ボイスクリップ)の検索と一括置換。純粋な計算だけで、UI にも Undo にも依存しない。
/// 対象は文字の `text`、ボイスの `text`(読み上げ文)と `subtitleText`(字幕文)、それにプロジェクトの台本(`scriptText`)。
/// ロックされたレイヤーのクリップは置き換えない(数だけ `lockedMatches` に入れる)。台本はレイヤーに属さないので常に置き換える。
/// 一致は左から順に、重ならないように数える(置換も同じ数え方)。
/// 読み辞書(`ReadingDictionary`)との役割分担: 辞書は合成時に読みだけを変換し、元の文字は変えない。
/// こちらはテキストそのものを書き換える(字幕文は音声を作り直さない。読み上げ文が変わったボイスだけ作り直しが要る)。
public enum TextSearch {
    /// 大文字と小文字を区別するか。既定は区別しない(英字だけに効く。ひらがな・漢字はそのまま比べる)。
    public struct Options: Equatable {
        public var caseSensitive: Bool
        public init(caseSensitive: Bool = false) { self.caseSensitive = caseSensitive }
        var compare: String.CompareOptions { caseSensitive ? [] : [.caseInsensitive] }
    }

    /// 検索対象の欄。
    public enum Field: String, Equatable {
        /// 文字クリップの本文・ボイスクリップの読み上げ文。
        case text
        /// ボイスクリップの字幕文(`subtitleText` が設定されているものだけ)。
        case subtitleText
        /// プロジェクトの台本(`scriptText`)。
        case script
    }

    /// 1 件の一致: クリップの文字の中の位置(文字数で数える、0 始まり)と長さ。台本の一致は `scriptMatches` で別に数える。
    public struct Match: Equatable {
        public var clipId: String
        public var location: Int
        public var length: Int
        public var field: Field = .text
    }

    /// 文字が変わるクリップ。`isVoice` は読み上げ文が変わったボイス(音声を作り直す必要がある)、という印。
    /// 字幕文だけの変更は `isVoice` = false(音声はそのまま)。
    public struct Change: Equatable {
        public var clipId: String
        public var text: String
        public var isVoice: Bool
        public var field: Field = .text
    }

    public struct ReplaceResult {
        /// 置き換えた後のプロジェクト(何も変わらなければ元と同じ)。
        public var project: Project
        /// 文字が変わったクリップ(順番は並びどおり。同じクリップの読み上げ文と字幕文は別々の変更として並ぶ)。
        public var changes: [Change]
        /// 置き換えた一致の数(クリップ側。台本分は `scriptCount`)。
        public var count: Int
        /// 台本で置き換えた一致の数。
        public var scriptCount: Int = 0
        /// ロックされたレイヤーにあって置き換えなかった一致の数。
        public var lockedMatches: Int
        /// 置き換えると空になるセリフ(音声を作れないので変えなかった)の数。
        public var skippedEmptyVoices: Int
    }

    /// 読み上げ文・本文の対象になるクリップか(文字 / ボイスで、`text` があるもの)。
    static func isTarget(_ c: Clip) -> Bool {
        (c.type == .text || c.type == .voice) && c.text != nil
    }

    /// 字幕文の対象になるクリップか(字幕文が設定されているもの)。
    static func isSubtitleTarget(_ c: Clip) -> Bool {
        c.subtitleText != nil
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

    private static func replaced(_ text: String, ranges rs: [Range<String.Index>], with replacement: String) -> String {
        var new = ""
        var last = text.startIndex
        for r in rs {
            new += text[last..<r.lowerBound]
            new += replacement
            last = r.upperBound
        }
        new += text[last...]
        return new
    }

    /// プロジェクト全体(または `scope` のクリップだけ)の一致を並びどおりに返す。ロックされたレイヤーも数える(表示用)。
    /// 台本の一致は含まない(`scriptMatches(_:in:options:)` で別に数える)。
    public static func matches(_ query: String, in project: Project, scope: Set<String>? = nil, options: Options = Options()) -> [Match] {
        var out: [Match] = []
        for track in project.tracks {
            for c in track.clips where scope?.contains(c.id) ?? true {
                if isTarget(c) {
                    let text = c.text ?? ""
                    for r in ranges(of: query, in: text, options: options) {
                        let loc = text.distance(from: text.startIndex, to: r.lowerBound)
                        let len = text.distance(from: r.lowerBound, to: r.upperBound)
                        out.append(Match(clipId: c.id, location: loc, length: len, field: .text))
                    }
                }
                if isSubtitleTarget(c), let sub = c.subtitleText {
                    for r in ranges(of: query, in: sub, options: options) {
                        let loc = sub.distance(from: sub.startIndex, to: r.lowerBound)
                        let len = sub.distance(from: r.lowerBound, to: r.upperBound)
                        out.append(Match(clipId: c.id, location: loc, length: len, field: .subtitleText))
                    }
                }
            }
        }
        return out
    }

    /// 台本(`scriptText`)の中の一致の数。
    public static func scriptMatches(_ query: String, in project: Project, options: Options = Options()) -> Int {
        ranges(of: query, in: project.scriptText, options: options).count
    }

    /// 一括置換。ロックされていないレイヤーの対象クリップと、台本(`scope` が nil のときだけ)を変える。
    /// 検索語が空、または何も変わらないなら `changes` は空で `scriptCount` は 0。
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
                guard scope?.contains(c.id) ?? true else { continue }
                let isLocked = project.tracks[ti].isLocked || c.isClipLocked
                // 読み上げ文・本文
                if isTarget(c) {
                    let text = c.text ?? ""
                    let rs = ranges(of: query, in: text, options: options)
                    if !rs.isEmpty {
                        if isLocked { locked += rs.count }
                        else {
                            let new = replaced(text, ranges: rs, with: replacement)
                            if new != text {
                                if c.type == .voice, new.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    skipped += 1
                                } else {
                                    count += rs.count
                                    changes.append(Change(clipId: c.id, text: new, isVoice: c.type == .voice, field: .text))
                                    p.tracks[ti].clips[ci].text = new
                                }
                            }
                        }
                    }
                }
                // 字幕文(空に置き換えてもよい: 字幕なしになる。音声は作り直さない)
                if isSubtitleTarget(c), let sub = c.subtitleText {
                    let rs = ranges(of: query, in: sub, options: options)
                    if !rs.isEmpty {
                        if isLocked { locked += rs.count }
                        else {
                            let new = replaced(sub, ranges: rs, with: replacement)
                            if new != sub {
                                count += rs.count
                                changes.append(Change(clipId: c.id, text: new, isVoice: false, field: .subtitleText))
                                p.tracks[ti].clips[ci].subtitleText = new
                            }
                        }
                    }
                }
            }
        }
        // 台本(選択だけの置換では対象にしない)
        var scriptCount = 0
        if scope == nil, !project.scriptText.isEmpty {
            let rs = ranges(of: query, in: project.scriptText, options: options)
            if !rs.isEmpty {
                let new = replaced(project.scriptText, ranges: rs, with: replacement)
                if new != project.scriptText {
                    p.scriptText = new
                    scriptCount = rs.count
                }
            }
        }
        return ReplaceResult(project: p, changes: changes, count: count, scriptCount: scriptCount, lockedMatches: locked, skippedEmptyVoices: skipped)
    }
}
