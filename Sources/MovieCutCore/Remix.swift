import Foundation

// MARK: - Remix ツール(Premiere Pro の Remix の等価機能)
//
// 音楽クリップと目標の尺を指定すると、ビート位置(取れなければ無音・波形の切り替わり点)を
// 候補に区間を選び直し(繰り返し/省略)、クロスフェードでつないで目標尺に合わせた
// 新しいクリップ列を生成する。計算は画面にも Undo にも依存しない純粋な処理で、
// 元クリップは変更しない。配置まで含めた組み立ても、失敗のときはプロジェクトを変えない。
//
// 時刻の前提はビート検出と同じ: 対象クリップは素材時刻とクリップ時刻が 1 対 1
// (`BeatDetector.supports`。速度・逆再生・速度ランプのあるクリップは対象外)。
// 区間の時刻はすべてクリップの頭からの秒。

/// Remix の設定。
public struct RemixParams: Equatable, Sendable {
    public static let crossfadeRange: ClosedRange<Double> = 0 ... 0.5
    public static let phraseBeatsRange: ClosedRange<Int> = 1 ... 16
    public static let fallbackPhraseRange: ClosedRange<Double> = 0.5 ... 8

    /// 目標の尺(秒)。
    public var targetDuration: Double
    /// つなぎ目のクロスフェードの長さ(秒)。既定 0.1。
    public var crossfadeDuration: Double
    /// フレーズの長さ(拍数)。ビート候補のとき、候補間隔の中央値 × この拍数をフレーズの目安にする。既定 4。
    public var phraseBeats: Int
    /// フォールバック候補のときのフレーズの長さ(秒)。既定 2。
    public var fallbackPhraseSeconds: Double

    public init(targetDuration: Double, crossfadeDuration: Double = 0.1, phraseBeats: Int = 4, fallbackPhraseSeconds: Double = 2.0) {
        self.targetDuration = targetDuration
        self.crossfadeDuration = crossfadeDuration
        self.phraseBeats = phraseBeats
        self.fallbackPhraseSeconds = fallbackPhraseSeconds
    }

    /// 範囲に収めた値(目標尺はそのまま。呼び出し側で検証する)。
    public var clamped: RemixParams {
        func cd(_ v: Double, _ r: ClosedRange<Double>, _ d: Double) -> Double { v.isFinite ? min(max(v, r.lowerBound), r.upperBound) : d }
        return RemixParams(targetDuration: targetDuration,
                           crossfadeDuration: cd(crossfadeDuration, Self.crossfadeRange, 0.1),
                           phraseBeats: phraseBeats.isFiniteInt ? min(max(phraseBeats, Self.phraseBeatsRange.lowerBound), Self.phraseBeatsRange.upperBound) : 4,
                           fallbackPhraseSeconds: cd(fallbackPhraseSeconds, Self.fallbackPhraseRange, 2.0))
    }
}

private extension Int {
    var isFiniteInt: Bool { true }   // Int は常に有限。上の clamped の書き方をそろえるための目印
}

/// Remix の 1 区間(素材の範囲。クリップの頭からの秒)。
public struct RemixSegment: Equatable, Sendable {
    public var sourceStart: Double
    public var sourceEnd: Double
    public init(sourceStart: Double, sourceEnd: Double) { self.sourceStart = sourceStart; self.sourceEnd = sourceEnd }
    public var length: Double { sourceEnd - sourceStart }
}

/// Remix の計画(選んだ区間列と、出来上がりの尺)。
public struct RemixPlan: Equatable, Sendable {
    /// 選び直した区間列(素材の時刻順とは限らない。延長時は繰り返しが入る)。
    public var segments: [RemixSegment]
    /// 出来上がりの尺(秒) = 区間長の合計。クロスフェードはフェードのペアで表すので尺は変わらない。
    public var totalDuration: Double
    /// クロスフェードの長さ(秒、実効値)。境界ごとに短い側の区間の半分までに収める。
    public var crossfadeDuration: Double
    /// ビートが取れず、無音・波形の切り替わり点で計画したか。
    public var usedFallback: Bool
    /// 選んだフレーズの数(連続フレーズを 1 区間にまとめる前の数)。
    public var selectedPhraseCount: Int

    public init(segments: [RemixSegment], totalDuration: Double, crossfadeDuration: Double, usedFallback: Bool, selectedPhraseCount: Int) {
        self.segments = segments; self.totalDuration = totalDuration; self.crossfadeDuration = crossfadeDuration
        self.usedFallback = usedFallback; self.selectedPhraseCount = selectedPhraseCount
    }
}

/// Remix ができない理由。黙って壊れた結果を作らず、この理由を表示して止める。
public enum RemixError: Equatable, Sendable, Error {
    case unsupportedClip      // 対象外のクリップ(速度・逆再生・ランプ、素材なし等)
    case invalidTarget        // 目標尺が不正(0 以下・非有限)
    case noCandidates         // ビートも切り替わり点も無い
    case cannotReachTarget    // 候補の組み合わせでは目標尺に近づけない
    case lockedOrBlocked      // レイヤー・クリップがロックされている
    case noAudio              // 音が読めない

    public var message: String {
        switch self {
        case .unsupportedClip: return "Remixできるのは、速度変更・逆再生・速度ランプの無い音のクリップだけです"
        case .invalidTarget: return "目標の尺が正しくありません"
        case .noCandidates: return "ビートも音の切り替わり点も見つかりませんでした"
        case .cannotReachTarget: return "区間の組み合わせでは目標の尺に近づけませんでした"
        case .lockedOrBlocked: return "レイヤーかクリップがロックされています"
        case .noAudio: return "音声を読み取れませんでした"
        }
    }
}

public enum Remix {
    /// Remix できるクリップか(ビート検出と同じ条件: 素材時刻とクリップ時刻が 1 対 1)。
    public static func supports(_ c: Clip) -> Bool { BeatDetector.supports(c) }

    // MARK: 候補 → 境界 → フレーズ

    /// 候補(クリップ頭からの秒)を整えて、境界列 [0, 候補…, duration] を返す。
    /// 有限でない・範囲外の候補は捨て、近すぎる重複(1e-6 秒以内)は 1 つにする。
    public static func boundaries(duration: Double, candidates: [Double]) -> [Double] {
        guard duration.isFinite, duration > 0 else { return [] }
        let pts = candidates.filter { $0.isFinite && $0 > 0 && $0 < duration }.sorted()
        var inner: [Double] = []
        for p in pts where inner.last.map({ p - $0 > 1e-6 }) ?? true { inner.append(p) }
        return [0] + inner + [duration]
    }

    /// フレーズの目安の長さ(秒)。ビート候補では候補間隔の中央値 × `phraseBeats`、
    /// フォールバックでは `fallbackPhraseSeconds`。候補が足りなければフォールバックの値。
    public static func nominalPhraseDuration(duration: Double, candidates: [Double], params: RemixParams, usedFallback: Bool) -> Double {
        let p = params.clamped
        if usedFallback { return p.fallbackPhraseSeconds }
        let b = boundaries(duration: duration, candidates: candidates)
        guard b.count >= 3 else { return p.fallbackPhraseSeconds }
        let diffs = zip(b.dropFirst(), b).map { $0 - $1 }.sorted()
        let median = diffs[diffs.count / 2]
        guard median > 0 else { return p.fallbackPhraseSeconds }
        return median * Double(p.phraseBeats)
    }

    /// 境界列を、目安以上の長さになるまで貪欲にまとめたフレーズ列。最後のフレーズは目安より短くてもよい。
    public static func phrases(duration: Double, candidates: [Double], nominalPhraseDuration nominal: Double) -> [RemixSegment] {
        let b = boundaries(duration: duration, candidates: candidates)
        guard b.count >= 2 else { return [] }
        let want = max(0.25, nominal.isFinite ? nominal : 2.0)
        var out: [RemixSegment] = []
        var start = b[0]
        for i in 1..<b.count {
            let end = b[i]
            if end - start >= want - 1e-9 || i == b.count - 1 {
                out.append(RemixSegment(sourceStart: start, sourceEnd: end))
                start = end
            }
        }
        return out
    }

    // MARK: 計画(区間の選び直し)

    /// 目標尺に合わせた区間列を計画する。
    ///
    /// 選び方: フレーズ列を素材の順序どおりに走査し、取る/取らないを決める部分集合選択
    /// (ビームサーチ、決定的)。目標が元の尺以上なら、フレーズ列を繰り返した仮想列から選ぶ
    /// (曲を繰り返して延ばす)。最初のフレーズは必ず取る(曲の頭から始める)。
    /// 連続して取ったフレーズ(同一周回内で素材上も連続)は 1 区間にまとめる。
    /// 出来上がりの尺と目標の差が許容誤差 `tolerance` を超える計画しか作れないときは
    /// `.cannotReachTarget` で失敗する。
    public static func plan(duration: Double, candidates: [Double], params: RemixParams, usedFallback: Bool) -> Result<RemixPlan, RemixError> {
        let p = params.clamped
        guard duration.isFinite, duration > 0 else { return .failure(.invalidTarget) }
        guard p.targetDuration.isFinite, p.targetDuration > 0 else { return .failure(.invalidTarget) }
        let target = p.targetDuration
        let inner = boundaries(duration: duration, candidates: candidates).dropFirst().dropLast()
        guard !inner.isEmpty else { return .failure(.noCandidates) }
        let nominal = nominalPhraseDuration(duration: duration, candidates: candidates, params: p, usedFallback: usedFallback)
        let phraseList = phrases(duration: duration, candidates: candidates, nominalPhraseDuration: nominal)
        guard phraseList.count >= 2 else { return .failure(.noCandidates) }
        let tolerance = max(0.2, nominal * 0.25)

        // 仮想フレーズ列: 延長時はフレーズ列を繰り返す(周回番号を持つ)
        struct VItem { var seg: RemixSegment; var cycle: Int }
        var virtual: [VItem] = []
        let maxPhrase = phraseList.map(\.length).max() ?? 0
        var cycle = 0
        var accum = 0.0
        while true {
            for ph in phraseList {
                // 巨大な目標で固まらないよう、2 周目以降は仮想列が上限を超えたら足さない
                if cycle > 0, virtual.count >= 4_000 { break }
                virtual.append(VItem(seg: ph, cycle: cycle)); accum += ph.length
            }
            cycle += 1
            if target < duration - 1e-9 || accum >= target + maxPhrase { break }
            if cycle >= 1_000 || virtual.count >= 4_000 { break }
        }

        // 上限で打ち切った仮想列の合計が目標に届かないなら、探索せずに失敗にする
        guard accum >= target - tolerance - 1e-9 else { return .failure(.cannotReachTarget) }

        // ビームサーチの状態
        struct State {
            var taken: [Int] = []
            var sum: Double = 0
            var runs: Int = 0
            var prevTaken = false
            var prevEnd: Double = 0
            var prevCycle: Int = -1
        }
        let first = virtual[0]
        guard first.seg.length <= target + tolerance + 1e-9 else { return .failure(.cannotReachTarget) }
        var states: [State] = [State(taken: [0], sum: first.seg.length, runs: 1, prevTaken: true, prevEnd: first.seg.sourceEnd, prevCycle: first.cycle)]
        // 残り合計(サフィックス)。到達可能性の目安に使う
        var suffix = [Double](repeating: 0, count: virtual.count + 1)
        for i in stride(from: virtual.count - 1, through: 0, by: -1) { suffix[i] = suffix[i + 1] + virtual[i].seg.length }
        let beamWidth = virtual.count > 2_000 ? 64 : 256
        func lexLess(_ a: [Int], _ b: [Int]) -> Bool {
            for i in 0..<min(a.count, b.count) where a[i] != b[i] { return a[i] < b[i] }
            return a.count < b.count
        }
        for i in 1..<virtual.count {
            let item = virtual[i]
            var next: [State] = []
            next.reserveCapacity(states.count * 2)
            for s in states {
                var skip = s; skip.prevTaken = false
                next.append(skip)
                let newSum = s.sum + item.seg.length
                if newSum <= target + tolerance + 1e-9 {
                    var take = s
                    let merges = s.prevTaken && s.prevCycle == item.cycle && abs(s.prevEnd - item.seg.sourceStart) < 1e-9
                    take.taken.append(i); take.sum = newSum; take.runs += merges ? 0 : 1
                    take.prevTaken = true; take.prevEnd = item.seg.sourceEnd; take.prevCycle = item.cycle
                    next.append(take)
                }
            }
            // この時点で比べられる物差し: [sum, sum + 残り] の区間に目標が入るか + つなぎ目の少なさ + 進み具合
            let remaining = suffix[i + 1]
            next.sort { a, b in
                func dist(_ s: State) -> Double {
                    if target < s.sum { return s.sum - target }
                    if target > s.sum + remaining { return target - (s.sum + remaining) }
                    return 0
                }
                let da = dist(a), db = dist(b)
                if abs(da - db) > 1e-9 { return da < db }
                if a.runs != b.runs { return a.runs < b.runs }
                if abs(a.sum - b.sum) > 1e-9 { return a.sum > b.sum }
                return lexLess(a.taken, b.taken)
            }
            states = Array(next.prefix(beamWidth))
        }
        guard let best = states.min(by: { a, b in
            let ea = abs(a.sum - target), eb = abs(b.sum - target)
            if abs(ea - eb) > 1e-9 { return ea < eb }
            if a.runs != b.runs { return a.runs < b.runs }
            return lexLess(a.taken, b.taken)
        }) else { return .failure(.cannotReachTarget) }
        guard abs(best.sum - target) <= tolerance + 1e-9, !best.taken.isEmpty else { return .failure(.cannotReachTarget) }

        // 取ったフレーズを区間へ(仮想列で連続し、同一周回内で素材上も連続するものはまとめる)
        var segments: [RemixSegment] = []
        var prevTakenIdx: Int? = nil
        for idx in best.taken {
            let item = virtual[idx]
            if let p = prevTakenIdx, p == idx - 1, virtual[p].cycle == item.cycle,
               abs(virtual[p].seg.sourceEnd - item.seg.sourceStart) < 1e-9, var last = segments.last {
                last.sourceEnd = item.seg.sourceEnd
                segments[segments.count - 1] = last
            } else {
                segments.append(item.seg)
            }
            prevTakenIdx = idx
        }
        return .success(RemixPlan(segments: segments, totalDuration: best.sum, crossfadeDuration: p.crossfadeDuration,
                                  usedFallback: usedFallback, selectedPhraseCount: best.taken.count))
    }

    /// クリップを対象にした計画。対象外なら `.unsupportedClip`。
    public static func plan(source: Clip, candidates: [Double], params: RemixParams, usedFallback: Bool) -> Result<RemixPlan, RemixError> {
        guard supports(source) else { return .failure(.unsupportedClip) }
        return plan(duration: source.duration, candidates: candidates, params: params, usedFallback: usedFallback)
    }

    // MARK: 区間 → クリップ

    /// 区間 1 つを、元クリップから切り出した新しいクリップにする(PaperEdit と同じく `ClipEditing.split` 経由)。
    /// 元クリップは変更しない。区間が短すぎる(1ms 以下)ときは nil。
    public static func subclip(source: Clip, segment: RemixSegment, startAt: Double) -> Clip? {
        guard supports(source) else { return nil }
        let dur = source.duration
        guard dur > 0, segment.sourceStart.isFinite, segment.sourceEnd.isFinite, startAt.isFinite, startAt >= 0 else { return nil }
        let a = min(max(0, segment.sourceStart), dur)
        let b = min(max(a, segment.sourceEnd), dur)
        guard b - a > 1e-3 else { return nil }
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

    /// 計画の区間列を、`startAt` から隙間なく並ぶクリップ列にする。
    /// つなぎ目にはクロスフェードとしてフェードのペア(前の fadeOut + 次の fadeIn、等パワー)を付ける。
    /// 同一レイヤーでクリップを重ねない不変条件があるため、重ね合わせによるクロスフェードはしない。
    /// 1 区間でも切り出せなければ全体を nil にする。
    public static func clips(source: Clip, plan: RemixPlan, startAt: Double) -> [Clip]? {
        guard supports(source), !plan.segments.isEmpty, startAt.isFinite, startAt >= 0 else { return nil }
        var out: [Clip] = []
        var t = startAt
        for seg in plan.segments {
            guard let c = subclip(source: source, segment: seg, startAt: t) else { return nil }
            out.append(c)
            t += c.duration
        }
        if plan.crossfadeDuration > 0, out.count > 1 {
            for i in 1..<out.count {
                let cf = min(plan.crossfadeDuration, 0.5 * min(out[i - 1].duration, out[i].duration))
                guard cf > 1e-9 else { continue }
                out[i - 1].fadeOut = cf
                out[i].fadeIn = cf
                out[i - 1].fadeCurve = "equalPower"
                out[i].fadeCurve = "equalPower"
            }
        }
        return out
    }

    // MARK: 組み立て(プロジェクトへの配置)

    /// 計画を作り、元クリップのあるレイヤーの末尾へクリップ列を置いた新しいプロジェクトを返す。
    /// 元のプロジェクト・元クリップは変更しない。失敗のときは理由を返す。
    public static func assemble(in project: Project, sourceClipId: String, candidates: [Double],
                                params: RemixParams, usedFallback: Bool) -> Result<(project: Project, clipIds: [String], plan: RemixPlan), RemixError> {
        guard let loc = ClipEditing.locate(sourceClipId, in: project) else { return .failure(.unsupportedClip) }
        let source = project.tracks[loc.track].clips[loc.index]
        let planned: RemixPlan
        switch plan(source: source, candidates: candidates, params: params, usedFallback: usedFallback) {
        case .failure(let e): return .failure(e)
        case .success(let pl): planned = pl
        }
        guard !project.tracks[loc.track].isLocked, !source.isClipLocked else { return .failure(.lockedOrBlocked) }
        let startAt = project.tracks[loc.track].clips.map { $0.start + $0.duration }.filter { $0.isFinite }.max() ?? 0
        guard let made = clips(source: source, plan: planned, startAt: startAt) else { return .failure(.cannotReachTarget) }
        var out = project
        for c in made { CompoundEditing.insertByStart(c, into: &out.tracks[loc.track].clips) }
        return .success((out, made.map(\.id), planned))
    }
}

// MARK: - フォールバック候補(ビートが取れない素材)

/// ビート検出ができない素材のための候補: 無音と有音の切り替わり点と、
/// 波形の立ち上がり(オンセット)のピーク。どちらも取れなければ空(呼び出し側が理由を表示して止める)。
public enum RemixFallback {
    /// 無音とみなす大きさ(dBFS)。無音検出の既定と同じ。
    public static let silenceThresholdDb: Double = -40
    /// オンセットピーク同士の最小間隔(秒)。
    public static let minPeakGap = 0.3
    /// 候補同士の最小間隔(秒)。
    public static let minCandidateGap = 0.1

    public static func candidates(profile: LevelProfile) -> [Double] {
        candidates(levels: profile.levels, duration: profile.duration)
    }

    public static func candidates(levels: [Float], duration: Double) -> [Double] {
        guard duration.isFinite, duration > 0, levels.count >= 2 else { return [] }
        let w = LevelProfile.windowSeconds
        var points: [Double] = []
        // (a) 無音 ↔ 有音の切り替わり
        let thr = Float(silenceThresholdDb)
        var prevSilent = levels[0] < thr
        for i in 1..<levels.count {
            let s = levels[i] < thr
            if s != prevSilent { points.append(Double(i) * w); prevSilent = s }
        }
        // (b) オンセットのピーク(平均 + 1.5 × 標準偏差 以上、最低 1 dB)
        let onset = BeatDetector.onsetEnvelope(levels)
        let positives = onset.filter { $0 > 0 }
        if !positives.isEmpty {
            let mean = positives.reduce(0, +) / Double(positives.count)
            let variance = positives.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(positives.count)
            let threshold = max(1.0, mean + 1.5 * variance.squareRoot())
            var peaks: [(t: Double, v: Double)] = []
            for i in onset.indices where onset[i] >= threshold {
                let left = i > 0 ? onset[i - 1] : 0
                let right = i < onset.count - 1 ? onset[i + 1] : 0
                guard onset[i] >= left, onset[i] >= right else { continue }
                peaks.append((Double(i) * w, onset[i]))
            }
            var kept: [(t: Double, v: Double)] = []
            for pk in peaks {
                if let last = kept.last, pk.t - last.t < minPeakGap {
                    if pk.v > last.v { kept[kept.count - 1] = pk }
                } else { kept.append(pk) }
            }
            points += kept.map(\.t)
        }
        // 内側だけ・昇順・最小間隔で重複除去
        let sorted = points.filter { $0 > 0.05 && $0 < duration - 0.05 }.sorted()
        var out: [Double] = []
        for p in sorted where out.last.map({ p - $0 >= minCandidateGap }) ?? true { out.append(p) }
        return out
    }
}
