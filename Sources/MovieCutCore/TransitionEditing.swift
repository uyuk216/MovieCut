import Foundation

/// トランジションと音声フェードの編集の純粋な計算(UI にも Undo にも依存しない)。
/// 変えたときだけ true を返す(何も変わらない編集は Undo に登録しない)。
public enum TransitionEditing {
    /// 映像のトランジションを付けられるクリップの種類。
    public static func supportsVideo(_ type: ClipType) -> Bool { [.image, .video, .text].contains(type) }
    /// 音声のフェードを付けられるクリップの種類。
    public static func supportsAudio(_ type: ClipType) -> Bool { [.audio, .voice, .video].contains(type) }
    /// クイック操作の既定の長さ(秒)。
    public static let quickFadeSeconds = 0.5
    /// クロスフェードにできる重なりの下限(秒)。
    public static let minCrossfadeOverlap = Transition.minDuration

    private static func round3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }

    public static func transition(_ c: Clip, _ edge: TransitionEdge) -> Transition? {
        edge == .in ? c.transitionIn : c.transitionOut
    }

    static func store(_ c: inout Clip, _ edge: TransitionEdge, _ tr: Transition?) {
        if edge == .in { c.transitionIn = tr } else { c.transitionOut = tr }
    }

    /// 長さの入力欄に出す値の範囲。
    public static func durationRange(clipDuration: Double) -> ClosedRange<Double> {
        let hi = max(0, min(Transition.maxDuration, clipDuration / 2))
        return min(Transition.minDuration, hi)...hi
    }

    // MARK: 種類・長さ・進み方

    /// 種類を選ぶ。nil で外す。すでにあれば長さと進み方を引き継ぐ。新しく付けるときは 0.5 秒・なめらか(クリップの半分まで)。
    @discardableResult
    public static func setKind(_ c: inout Clip, edge: TransitionEdge, kind: TransitionKind?) -> Bool {
        guard supportsVideo(c.type) else { return false }
        let before = c
        if let kind {
            var tr = transition(c, edge) ?? Transition(kind, duration: Transition.clampedDuration(Transition.defaultDuration, clipDuration: c.duration))
            tr.kind = kind.rawValue
            store(&c, edge, tr)
        } else {
            store(&c, edge, nil)
        }
        return c != before
    }

    /// 長さ(秒)。なければ何もしない。範囲に収め、小数 3 桁に丸める。
    @discardableResult
    public static func setDuration(_ c: inout Clip, edge: TransitionEdge, _ d: Double) -> Bool {
        guard var tr = transition(c, edge) else { return false }
        let new = round3(Transition.clampedDuration(d, clipDuration: c.duration))
        guard new != tr.duration else { return false }
        tr.duration = new
        store(&c, edge, tr)
        return true
    }

    @discardableResult
    public static func setEase(_ c: inout Clip, edge: TransitionEdge, _ e: Ease) -> Bool {
        guard var tr = transition(c, edge), tr.ease != e else { return false }
        tr.ease = e
        store(&c, edge, tr)
        return true
    }

    /// インスペクタの進み方の選択肢。
    public static let easeChoices: [(label: String, ease: Ease)] = [
        ("なめらか", .easeInOut), ("一定", .linear), ("ゆっくり開始", .easeIn), ("ゆっくり終了", .easeOut),
    ]

    // MARK: まとめて付ける・外す

    /// 両方にフェード(長さは、すでにあればそのまま、無ければ 0.5 秒)。
    @discardableResult
    public static func fadeBoth(_ c: inout Clip) -> Bool {
        guard supportsVideo(c.type) else { return false }
        let before = c
        for edge in [TransitionEdge.in, .out] {
            var tr = transition(c, edge) ?? Transition(.fade, duration: Transition.clampedDuration(Transition.defaultDuration, clipDuration: c.duration))
            tr.kind = TransitionKind.fade.rawValue
            store(&c, edge, tr)
        }
        return c != before
    }

    /// 映像のトランジションをすべて外す(音声のフェードはそのまま)。
    @discardableResult
    public static func clearAll(_ c: inout Clip) -> Bool {
        guard c.hasTransition else { return false }
        c.transitionIn = nil; c.transitionOut = nil
        return true
    }

    /// クイック操作「フェードイン・アウトを付ける」: 映像(画像・動画・文字)は頭と終わりにフェード、
    /// 音声(音声・ボイス・動画)は音量のフェード。どちらも `seconds` 秒(クリップの半分まで)。
    @discardableResult
    public static func fadeInOut(_ c: inout Clip, seconds: Double = quickFadeSeconds) -> Bool {
        let before = c
        let d = round3(Transition.clampedDuration(seconds, clipDuration: c.duration))
        if supportsVideo(c.type) {
            for edge in [TransitionEdge.in, .out] {
                var tr = transition(c, edge) ?? Transition(.fade, duration: d)
                tr.kind = TransitionKind.fade.rawValue
                tr.duration = d
                store(&c, edge, tr)
            }
        }
        if supportsAudio(c.type) {
            c.fadeIn = d; c.fadeOut = d
        }
        return c != before
    }

    // MARK: 音声のフェード

    /// フェード秒(0 以下は外す)。クリップの長さまで。
    @discardableResult
    public static func setAudioFade(_ c: inout Clip, edge: TransitionEdge, _ seconds: Double) -> Bool {
        guard supportsAudio(c.type) else { return false }
        let before = c
        let v = seconds.isFinite ? min(max(seconds, 0), max(0, c.duration)) : 0
        let r: Double? = v > 0 ? round3(v) : nil
        if edge == .in { c.fadeIn = r } else { c.fadeOut = r }
        if !c.hasAudioFade { c.fadeCurve = nil }
        return c != before
    }

    /// 曲線("linear" / "equalPower")。linear は既定なので書かない。
    @discardableResult
    public static func setFadeCurve(_ c: inout Clip, equalPower: Bool) -> Bool {
        guard supportsAudio(c.type) else { return false }
        let before = c
        c.fadeCurve = equalPower ? "equalPower" : nil
        return c != before
    }

    /// 「映像のトランジションと同じ長さで音声もフェード」がいま成り立っているか:
    /// 映像のトランジションが 1 つ以上あり、音声フェードがその長さ(無い側は 0)と一致している。
    public static func isAudioLinked(_ c: Clip) -> Bool {
        guard supportsVideo(c.type), supportsAudio(c.type), c.hasTransition else { return false }
        return linkedFades(c) == (c.fadeInOrDefault, c.fadeOutOrDefault)
    }

    static func linkedFades(_ c: Clip) -> (Double, Double) {
        func f(_ tr: Transition?) -> Double { tr.map { round3($0.effectiveDuration(clipDuration: c.duration)) } ?? 0 }
        return (f(c.transitionIn), f(c.transitionOut))
    }

    /// トグル: オンなら映像のトランジションの長さを音声のフェードに書き、オフなら音声フェードを外す。
    @discardableResult
    public static func setAudioLinked(_ c: inout Clip, _ on: Bool) -> Bool {
        guard supportsVideo(c.type), supportsAudio(c.type) else { return false }
        let before = c
        if on {
            let (i, o) = linkedFades(c)
            c.fadeIn = i > 0 ? i : nil
            c.fadeOut = o > 0 ? o : nil
        } else {
            c.fadeIn = nil; c.fadeOut = nil
        }
        if !c.hasAudioFade { c.fadeCurve = nil }
        return c != before
    }

    /// 映像のトランジションの長さ・種類を変える編集に付き添う: 編集の前に音声が連動していたら、編集の後も合わせ直す。
    public static func edit(_ c: inout Clip, keepAudioLinked: Bool = true, _ change: (inout Clip) -> Void) {
        let linked = keepAudioLinked && isAudioLinked(c)
        change(&c)
        if linked { setAudioLinked(&c, true) }
    }

    // MARK: クロスフェード

    public enum CrossfadeResult: Equatable {
        case applied(Project, seconds: Double, underId: String)
        case notSupported        // 映像のクリップではない
        case noClipBelow         // 下(前)にクリップが無い
        case noOverlap           // 重なりが短すぎる(伸ばさない)
    }

    /// 選んだクリップの頭で下(前)にあるクリップを探し、頭のトランジションをフェードにして、長さを重なりに合わせる。
    /// 下のクリップ = 頭の時刻に重なっている映像クリップのうち、一番手前の下のレイヤー(同じレイヤーなら配列で前のもの)。
    /// クリップの長さは伸ばさない。重なりが 0.05 秒未満なら何もしない。長さは重なり(クリップの半分まで、5 秒まで)。
    public static func crossfade(in project: Project, clipId: String) -> CrossfadeResult {
        guard let loc = ClipEditing.locate(clipId, in: project) else { return .notSupported }
        let c = project.tracks[loc.track].clips[loc.index]
        guard supportsVideo(c.type) else { return .notSupported }
        let eps = ClipEditing.timeEpsilon
        var best: (track: Int, index: Int)?
        for ti in stride(from: loc.track, through: 0, by: -1) {
            for (ci, o) in project.tracks[ti].clips.enumerated() where o.id != c.id && supportsVideo(o.type) {
                if ti == loc.track && ci >= loc.index { continue }       // 同じレイヤーでは、前にあるものだけ
                let oEnd = o.start + o.duration
                guard o.start <= c.start + eps, oEnd > c.start + eps else { continue }
                if best == nil || ti > best!.track || (ti == best!.track && ci > best!.index) { best = (ti, ci) }
            }
            if best != nil { break }
        }
        guard let b = best else { return .noClipBelow }
        let o = project.tracks[b.track].clips[b.index]
        let overlap = min(o.start + o.duration, c.start + c.duration) - c.start
        guard overlap >= minCrossfadeOverlap - eps else { return .noOverlap }
        var p = project
        var nc = c
        let d = round3(Transition.clampedDuration(overlap, clipDuration: c.duration))
        var tr = c.transitionIn ?? Transition(.fade, duration: d)
        tr.kind = TransitionKind.fade.rawValue
        tr.duration = d
        nc.transitionIn = tr
        p.tracks[loc.track].clips[loc.index] = nc
        return .applied(p, seconds: d, underId: o.id)
    }
}
