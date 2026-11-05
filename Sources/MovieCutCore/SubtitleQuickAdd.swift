import Foundation

/// 「字幕を追加…」: 再生位置に、字幕と同じ見た目の文字クリップを 1 つ足す。既存の字幕を同じ文で直すことも扱う。
/// 置き場所は「字幕」レイヤー(字幕の自動生成と同じ名前)。ロックされていないレイヤーで、その時間に空きがあるものを使い、
/// 無ければ「字幕 2」…を新しく作る。
public enum SubtitleQuickAdd {
    public static let defaultDuration: Double = 3
    public static let durationRange: ClosedRange<Double> = 0.1...600

    public struct Result: Equatable {
        public var project: Project
        public var clipId: String
        /// 入れたレイヤーの番号(0 始まり。新しく作ったときは末尾)。
        public var trackIndex: Int
    }

    /// 本文を整える(前後の空白と改行を落とす)。空なら nil(追加も直しもしない)。内側の改行は残す。
    public static func cleanedText(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// 長さを範囲に収める。有限でない値は既定の長さ。
    public static func clampDuration(_ d: Double) -> Double {
        guard d.isFinite else { return defaultDuration }
        return min(max(d, durationRange.lowerBound), durationRange.upperBound)
    }

    /// 再生位置 `t` から `duration` 秒の字幕を足す。`style` があれば字幕の文字スタイルを当てる(字幕の自動生成と同じ)。
    /// 本文が空なら nil(何も変えない)。
    public static func add(text: String, at t: Double, duration: Double = defaultDuration, style: TextLook? = nil,
                           to project: Project) -> Result? {
        guard let body = cleanedText(text) else { return nil }
        let start = t.isFinite ? max(0, t) : 0
        let len = clampDuration(duration)
        var clip = SubtitleImport.makeClip(SubtitleCue(start: start, end: start + len, text: body), project: project)
        if let style { style.apply(to: &clip) }
        var p = project
        let idx: Int
        if let i = TrackTarget.usableIndex(in: p, start: start, duration: len) {
            p.tracks[i].clips.append(clip)    // トラックターゲットがあれば、そこへ
            idx = i
        } else if let i = freeSubtitleLayer(in: p, start: start, end: start + len) {
            p.tracks[i].clips.append(clip)
            idx = i
        } else {
            var t = Track(name: newLayerName(in: p))
            t.clips = [clip]
            p.tracks.append(t)
            idx = p.tracks.count - 1
        }
        return Result(project: p, clipId: clip.id, trackIndex: idx)
    }

    /// 既存の字幕クリップの文(と長さ)を直す。本文が空、または対象が無いときは nil。長さを省くと今のまま。
    public static func updateText(clipId: String, text: String, duration: Double? = nil, in project: Project) -> Project? {
        guard let body = cleanedText(text) else { return nil }
        var p = project
        for ti in p.tracks.indices {
            guard let ci = p.tracks[ti].clips.firstIndex(where: { $0.id == clipId }) else { continue }
            // ロックされたレイヤー・クリップの字幕は直さない
            guard !p.tracks[ti].isLocked, !p.tracks[ti].clips[ci].isClipLocked else { return nil }
            p.tracks[ti].clips[ci].text = body
            if let d = duration { p.tracks[ti].clips[ci].duration = clampDuration(d) }
            return p
        }
        return nil
    }

    /// 「字幕」レイヤーのうち、ロックされておらず、[start, end) に重なるクリップが無い最初のもの。
    static func freeSubtitleLayer(in project: Project, start: Double, end: Double) -> Int? {
        for (i, tr) in project.tracks.enumerated() where SubtitleFile.isSubtitleLayer(tr.name) && !tr.isLocked {
            let overlaps = tr.clips.contains { c in c.start < end - 1e-9 && c.start + c.duration > start + 1e-9 }
            if !overlaps { return i }
        }
        return nil
    }

    /// 新しい字幕レイヤーの名前: 「字幕」が空いていればそれ、無ければ「字幕 2」…(既にある名前は使わない)。
    static func newLayerName(in project: Project) -> String {
        let names = Set(project.tracks.map(\.name))
        if !names.contains(SubtitleFile.layerName) { return SubtitleFile.layerName }
        var n = 2
        while names.contains("\(SubtitleFile.layerName) \(n)") { n += 1 }
        return "\(SubtitleFile.layerName) \(n)"
    }
}
