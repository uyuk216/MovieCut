import Foundation

/// 音MAD 向け: 1 つのクリップを、音程を変えながら並べる(音階で複製・ビートに合わせて並べる)の純粋な計算。
/// UI にも Undo にも依存しない。呼び出し側は結果のプロジェクトを 1 回の編集として反映する(= Undo 1 回)。

/// 音階。半音の並び(1 オクターブ内)。
public enum PitchScale: String, CaseIterable, Equatable, Sendable {
    case major, minor, chromatic, pentatonic, minorPentatonic

    public var title: String {
        switch self {
        case .major: return "長音階（ドレミファソラシ）"
        case .minor: return "短音階（自然的短音階）"
        case .chromatic: return "半音階"
        case .pentatonic: return "ペンタトニック（長調）"
        case .minorPentatonic: return "ペンタトニック（短調）"
        }
    }

    /// 1 オクターブ内の音の高さ(根音からの半音数)。
    public var intervals: [Int] {
        switch self {
        case .major: return [0, 2, 4, 5, 7, 9, 11]
        case .minor: return [0, 2, 3, 5, 7, 8, 10]
        case .chromatic: return Array(0...11)
        case .pentatonic: return [0, 2, 4, 7, 9]
        case .minorPentatonic: return [0, 3, 5, 7, 10]
        }
    }

    /// i 番目(0 始まり)の音の、根音からの半音数。1 オクターブを超えたら 12 半音ずつ上がる。下降なら符号を反転して下へ。
    public func degree(_ i: Int, descending: Bool = false) -> Int {
        let n = intervals.count
        let v = (i / n) * 12 + intervals[i % n]
        return descending ? -v : v
    }
}

/// 並べる 1 つ分: 開始・長さ・追加する音程(半音、元のクリップの音程に足す)。
public struct PitchStep: Equatable, Sendable {
    public var start: Double
    public var duration: Double
    public var pitch: Double
    public init(start: Double, duration: Double, pitch: Double) { self.start = start; self.duration = duration; self.pitch = pitch }
}

public enum PitchLayout {
    /// 並べられる上限。
    public static let maxCount = 128

    public struct Result {
        public var project: Project
        /// 追加したクリップの id(元のクリップは含まない)。
        public var newIds: [String]
        /// 音程が範囲(±24 半音)を超えるため作らなかった数。
        public var truncated: Int
        /// 元のクリップのレイヤーが塞がっていたので、別のレイヤーに置いたか。
        public var movedToOtherLayer: Bool
    }

    /// 並べられるクリップか(音のあるクリップ・フリーズでない・ロックされていない)。
    public static func supports(_ c: Clip, in project: Project) -> Bool {
        AudioFxEditing.supports(c) && c.duration > 0 && !LayerEditing.isLockedClip(c.id, in: project)
    }

    // MARK: 音階

    /// 音階で並べる計画。根音の移調 `rootShift`(半音、元の音程からの差)から始め、音階の音を `count` 個。
    /// 元のクリップの終わりに次が続く(すき間なし)。元の音程に足して ±24 を超える音は作らない(後ろを切る)。
    public static func scalePlan(clip c: Clip, scale: PitchScale, rootShift: Int, count: Int, descending: Bool) -> (steps: [PitchStep], truncated: Int) {
        let n = min(max(count, 0), maxCount)
        let base = c.audioFx?.pitchSemitones ?? 0
        var steps: [PitchStep] = []
        for i in 0..<n {
            let total = base + Double(rootShift + scale.degree(i, descending: descending))
            // 範囲を超えた音が出たら、そこから後ろはすべて作らない(途中で抜けるとリズムが崩れるため)
            if total < AudioFx.pitchRange.lowerBound - 1e-9 || total > AudioFx.pitchRange.upperBound + 1e-9 { return (steps, n - i) }
            steps.append(PitchStep(start: c.start + Double(i) * c.duration, duration: c.duration, pitch: total - base))
        }
        return (steps, 0)
    }

    // MARK: ビート

    /// 並べる位置にするマーカーの時刻(`from` 以上、重複は除く、昇順)。`beatsOnly` なら名前が「ビート」のものだけ。
    public static func markerTimes(in project: Project, from: Double, beatsOnly: Bool) -> [Double] {
        var out: [Double] = []
        for m in MarkerEditing.sorted(project.markers) where m.time >= from - ClipEditing.timeEpsilon {
            if beatsOnly && m.name != "ビート" { continue }
            if let last = out.last, m.time - last < 0.005 { continue }
            out.append(m.time)
        }
        return out
    }

    /// 時刻の列に並べる計画。各クリップの長さは、次の時刻までの間隔を超えない(重ならない)。最後は元の長さ。
    /// 音程は 1 つごとに `pitchStep` 半音ずつ変わる(0 なら同じ音)。上限は `limit`(0 以下 = 全部)。±24 を超える音は後ろを作らない。
    public static func beatPlan(clip c: Clip, times: [Double], pitchStep: Double, limit: Int) -> (steps: [PitchStep], truncated: Int) {
        let cap = limit > 0 ? min(limit, maxCount) : maxCount
        let ts = Array(times.prefix(cap))
        let base = c.audioFx?.pitchSemitones ?? 0
        var steps: [PitchStep] = []
        var cut = 0
        for (i, t) in ts.enumerated() {
            let total = base + Double(i) * pitchStep
            if total < AudioFx.pitchRange.lowerBound - 1e-9 || total > AudioFx.pitchRange.upperBound + 1e-9 { cut = ts.count - i; break }
            let gap = i + 1 < ts.count ? ts[i + 1] - t : c.duration
            steps.append(PitchStep(start: t, duration: min(c.duration, gap), pitch: total - base))
        }
        return (steps, cut)
    }

    // MARK: 反映

    /// 計画をプロジェクトに反映する。1 つ目の音は元のクリップ(位置・長さ・音程を変える)、残りは新しいコピー。
    /// 元のクリップのレイヤーで全部が重ならないなら、そのレイヤーの元のクリップの後ろに入れる。
    /// 塞がっているなら、元のクリップはそのままにして、全部を空いているレイヤー(無ければ一番上に新しいレイヤー)にコピーとして置く。
    /// 計画が空・ロック・音の無いクリップなら nil。何も変わらなければ nil。
    public static func apply(in project: Project, clipId: String, steps: [PitchStep], truncated: Int = 0) -> Result? {
        guard !steps.isEmpty, let loc = ClipEditing.locate(clipId, in: project) else { return nil }
        let original = project.tracks[loc.track].clips[loc.index]
        guard supports(original, in: project) else { return nil }
        var p = project

        func make(_ s: PitchStep, fresh: Bool) -> Clip {
            var k = fresh ? CompoundEditing.freshIds(original) : original
            let before = k.audioFx?.pitchSemitones ?? 0
            k.start = s.start
            k.duration = s.duration
            _ = AudioFxEditing.setPitch(&k, before + s.pitch)
            return k
        }

        let end = { (s: PitchStep) in s.start + s.duration }
        let inPlace = steps.allSatisfy { s in
            ClipEditing.isFree(p.tracks[loc.track], start: s.start, end: end(s), excluding: clipId)
        } && Self.stepsDisjoint(steps)
        var newClips: [Clip] = []
        var moved = false
        if inPlace {
            p.tracks[loc.track].clips[loc.index] = make(steps[0], fresh: false)
            newClips = steps.dropFirst().map { make($0, fresh: true) }
            p.tracks[loc.track].clips.insert(contentsOf: newClips, at: loc.index + 1)
        } else {
            moved = true
            newClips = steps.map { make($0, fresh: true) }
            let lo = steps.map(\.start).min()!, hi = steps.map(end).max()!
            if let ti = p.tracks.indices.first(where: { !p.tracks[$0].isLocked && ClipEditing.isFree(p.tracks[$0], start: lo, end: hi) }) {
                p.tracks[ti].clips.append(contentsOf: newClips)
            } else {
                var t = Track(name: "レイヤー\(p.tracks.count + 1)")
                t.clips = newClips
                p.tracks.append(t)
            }
        }
        guard p != project else { return nil }
        return Result(project: p, newIds: newClips.map(\.id), truncated: truncated, movedToOtherLayer: moved)
    }

    /// 計画どうしが重ならない。
    static func stepsDisjoint(_ steps: [PitchStep]) -> Bool {
        let s = steps.sorted { $0.start < $1.start }
        for i in 1..<max(1, s.count) where s[i].start < s[i - 1].start + s[i - 1].duration - ClipEditing.timeEpsilon { return false }
        return true
    }
}
