import Foundation

/// キーフレームのイージング曲線エディタの純粋な計算(UI にも Undo にも依存しない)。
/// 表現は既存の `Ease`(`bezier:x1,y1,x2,y2`)のまま。ファイル形式は変えない。
public enum EaseCurve {
    /// 制御点 y の範囲(行き過ぎ・戻りを許す)。x は 0〜1。
    public static let yRange: ClosedRange<Double> = -2...3

    /// 画面のプリセット(左から並べる順)。
    public static let presets: [(label: String, ease: Ease)] = [
        ("リニア", .linear),
        ("イーズイン", .easeIn),
        ("イーズアウト", .easeOut),
        ("イーズインアウト", .easeInOut),
        ("バウンス風", .bezier(0.34, 1.56, 0.64, 1)),
        ("急→緩", .bezier(0.16, 1, 0.3, 1)),
        ("緩→急", .bezier(0.7, 0, 0.84, 0)),
    ]

    /// リセット先(リニア)。
    public static let reset: Ease = .linear

    /// 制御点 (x1,y1,x2,y2)。hold は曲線を持たないのでリニアの位置(編集を始めると bezier になる)。
    public static func controlPoints(_ e: Ease) -> (x1: Double, y1: Double, x2: Double, y2: Double) {
        switch e {
        case .linear, .hold: return (0, 0, 1, 1)
        case .easeIn: return (0.42, 0, 1, 1)
        case .easeOut: return (0, 0, 0.58, 1)
        case .easeInOut: return (0.42, 0, 0.58, 1)
        case .bezier(let a, let b, let c, let d): return (a, b, c, d)
        }
    }

    /// 制御点の値を範囲に収め、小数 3 桁に丸める(ファイルを短く保つ)。
    public static func clampedPoints(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> (x1: Double, y1: Double, x2: Double, y2: Double) {
        func r(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
        func cx(_ v: Double) -> Double { v.isFinite ? r(min(max(v, 0), 1)) : 0 }
        func cy(_ v: Double) -> Double { v.isFinite ? r(min(max(v, yRange.lowerBound), yRange.upperBound)) : 0 }
        return (cx(x1), cy(y1), cx(x2), cy(y2))
    }

    /// 制御点から Ease を作る。プリセットと同じ形なら、その名前付きの Ease(linear など)に戻す。
    public static func ease(x1: Double, y1: Double, x2: Double, y2: Double) -> Ease {
        let p = clampedPoints(x1, y1, x2, y2)
        let e = Ease.bezier(p.x1, p.y1, p.x2, p.y2)
        for (_, preset) in presets {
            let q = controlPoints(preset)
            if q == (p.x1, p.y1, p.x2, p.y2) { return preset }
        }
        return e
    }

    /// 一致するプリセットの名前(無ければ nil)。
    public static func presetLabel(of e: Ease) -> String? {
        let p = controlPoints(e)
        if case .hold = e { return nil }
        return presets.first { controlPoints($0.ease) == p }?.label
    }

    /// 曲線の標本(u: 0〜1 の n+1 点、v = ease.apply(u))。プレビューの線に使う。
    public static func samples(_ e: Ease, count n: Int = 64) -> [(u: Double, v: Double)] {
        let m = max(2, n)
        return (0...m).map { i in
            let u = Double(i) / Double(m)
            return (u, e.apply(u))
        }
    }
}

extension KeyframeEditing {
    /// その項目の、再生ヘッド(`t`)にあるキーの「次のキーまでの動き方」。キーが無い・最後のキー(次の区間が無い)は nil。
    public static func segmentEase(_ clip: Clip, key: String, at t: Double, tolerance tol: Double) -> Ease? {
        guard let i = keyIndex(clip, key: key, at: t, tolerance: tol), let ks = clip.keyframes[key], i + 1 < ks.count else { return nil }
        return ks[i].ease
    }

    /// 再生ヘッドにあるキーのイージングを書く。キーが無い・同じなら何もせず false(Undo に積まない)。
    @discardableResult
    public static func setEase(_ clip: inout Clip, key: String, _ ease: Ease, at t: Double, tolerance tol: Double) -> Bool {
        guard let i = keyIndex(clip, key: key, at: t, tolerance: tol), var ks = clip.keyframes[key], ks[i].ease != ease else { return false }
        ks[i].ease = ease
        clip.keyframes[key] = ks
        return true
    }
}
