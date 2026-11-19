import Foundation
import CoreGraphics

// MARK: - トランジションの種類

/// トランジションの種類のグループ(選択 UI の見出し)。
public enum TransitionCategory: String, CaseIterable, Sendable {
    case basic, wipe, ruleWipe, effect

    public var label: String {
        switch self {
        case .basic: return "フェード・移動"
        case .wipe: return "ワイプ"
        case .ruleWipe: return "ルールワイプ"
        case .effect: return "演出"
        }
    }
}

/// クリップの頭(in)・終わり(out)につける映像の効果の種類。ファイルには文字列(rawValue)で書く。
/// 知らない文字列も `Transition.kind` にそのまま残し、描くときは何もしない(無効)。
public enum TransitionKind: String, CaseIterable, Sendable {
    case fade, zoom
    case slideLeft, slideRight, slideUp, slideDown
    case wipeLeft, wipeRight, wipeUp, wipeDown
    case wipeCircle, wipeClock
    case blur, spin
    // ルール画像ワイプ(#60)。ruleCustom は params の "ruleSrc"(素材の場所)の輝度を使う
    case ruleHorizontal, ruleVertical, ruleDiagonal, ruleCircle, ruleSquare, ruleDiamond
    case ruleClock, ruleChecker, ruleStripesH, ruleStripesV, ruleSpiral, ruleCustom
    // 登場/退場の演出(#61)
    case fadeZoom, pop, blurRelease, mosaicRelease, edgeBlurRelease, skewIn, shatter, bounceIn, riseIn
    case regionLeft, regionRight, regionUp, regionDown
    case driftLeft, driftRight, driftUp, driftDown
    // モーフカット: クリップの境界を、前後のコマのオプティカルフロー補間でつなぐ
    case morphCut

    /// 画面に出す名前。
    public var label: String {
        switch self {
        case .fade: return "フェード"
        case .zoom: return "ズーム"
        case .slideLeft: return "スライド（左）"
        case .slideRight: return "スライド（右）"
        case .slideUp: return "スライド（上）"
        case .slideDown: return "スライド（下）"
        case .wipeLeft: return "ワイプ（左）"
        case .wipeRight: return "ワイプ（右）"
        case .wipeUp: return "ワイプ（上）"
        case .wipeDown: return "ワイプ（下）"
        case .wipeCircle: return "円形ワイプ"
        case .wipeClock: return "時計回りワイプ"
        case .blur: return "ぼかし"
        case .spin: return "回転"
        case .ruleCustom: return "ルールワイプ（カスタム画像）"
        case .fadeZoom: return "フェードズーム"
        case .pop: return "ポップ拡大"
        case .blurRelease: return "ぼかし解除"
        case .mosaicRelease: return "モザイク解除"
        case .edgeBlurRelease: return "境界ぼかし解除"
        case .skewIn: return "傾斜変形"
        case .shatter: return "砕け散り"
        case .bounceIn: return "バウンス"
        case .riseIn: return "起き上がり"
        case .regionLeft: return "領域外（左）"
        case .regionRight: return "領域外（右）"
        case .regionUp: return "領域外（上）"
        case .regionDown: return "領域外（下）"
        case .driftLeft: return "移動フェード（左）"
        case .driftRight: return "移動フェード（右）"
        case .driftUp: return "移動フェード（上）"
        case .driftDown: return "移動フェード（下）"
        case .morphCut: return "モーフカット"
        default: return ruleKind?.label ?? rawValue
        }
    }

    /// 選択 UI のグループ。
    public var category: TransitionCategory {
        switch self {
        case .fade, .fadeZoom, .zoom, .pop, .slideLeft, .slideRight, .slideUp, .slideDown,
             .regionLeft, .regionRight, .regionUp, .regionDown, .driftLeft, .driftRight, .driftUp, .driftDown:
            return .basic
        case .wipeLeft, .wipeRight, .wipeUp, .wipeDown, .wipeCircle, .wipeClock:
            return .wipe
        case .ruleHorizontal, .ruleVertical, .ruleDiagonal, .ruleCircle, .ruleSquare, .ruleDiamond,
             .ruleClock, .ruleChecker, .ruleStripesH, .ruleStripesV, .ruleSpiral, .ruleCustom:
            return .ruleWipe
        case .blur, .spin, .blurRelease, .mosaicRelease, .edgeBlurRelease, .skewIn, .shatter, .bounceIn, .riseIn, .morphCut:
            return .effect
        }
    }

    /// 内蔵ルール画像の種類(ルールワイプのとき)。カスタム画像は nil。
    public var ruleKind: RuleWipeKind? {
        switch self {
        case .ruleHorizontal: return .horizontal
        case .ruleVertical: return .vertical
        case .ruleDiagonal: return .diagonal
        case .ruleCircle: return .circle
        case .ruleSquare: return .square
        case .ruleDiamond: return .diamond
        case .ruleClock: return .clock
        case .ruleChecker: return .checker
        case .ruleStripesH: return .stripesHorizontal
        case .ruleStripesV: return .stripesVertical
        case .ruleSpiral: return .spiral
        default: return nil
        }
    }

    /// ルール画像ワイプか(やわらかさ等の設定が効く)。
    public var isRuleWipe: Bool { ruleKind != nil || self == .ruleCustom }

    /// モーフカットか(強さ・顔の位置合わせの設定が効く)。
    public var isMorphCut: Bool { self == .morphCut }

    var isSlide: Bool { [.slideLeft, .slideRight, .slideUp, .slideDown].contains(self) }

    /// 移動量の計算にクリップの枠の大きさが要る種類(描画側が大きさを測る)。
    public var needsSize: Bool {
        isSlide || [.regionLeft, .regionRight, .regionUp, .regionDown].contains(self)
    }
}

/// 頭(in)と終わり(out)。
public enum TransitionEdge: Sendable {
    case `in`, out

    public var label: String { self == .in ? "開始" : "終了" }
}

// MARK: - トランジション

/// 1 つのトランジション。`kind` は知らない文字列も保つ。`duration` は秒、`ease` は進み方(既定 easeInOut)。
public struct Transition: Equatable, Codable, Sendable {
    public var kind: String
    public var duration: Double
    public var ease: Ease
    /// 将来の拡張用の引数(いまは使わない。そのまま保つ)。
    public var params: JSONValue?
    /// 知らないキー(保持して書き戻す)
    public var extra: [String: JSONValue] = [:]

    public static let defaultDuration = 0.5
    public static let defaultEase = Ease.easeInOut
    /// 長さの下限・上限(秒)。上限はさらにクリップの長さの半分まで。
    public static let minDuration = 0.05
    public static let maxDuration = 5.0

    static let knownKeys: Set<String> = ["kind", "duration", "ease", "params"]

    public init(kind: String, duration: Double = Transition.defaultDuration, ease: Ease = Transition.defaultEase, params: JSONValue? = nil) {
        self.kind = kind; self.duration = duration; self.ease = ease; self.params = params
    }

    public init(_ kind: TransitionKind, duration: Double = Transition.defaultDuration, ease: Ease = Transition.defaultEase) {
        self.init(kind: kind.rawValue, duration: duration, ease: ease)
    }

    /// 描ける種類。知らない文字列は nil(何もしない)。
    public var known: TransitionKind? { TransitionKind(rawValue: kind) }

    public init(from decoder: Decoder) throws {
        let l = Lenient(c: try decoder.container(keyedBy: AnyKey.self), known: Self.knownKeys)
        kind = l.string("kind") ?? ""
        let d = l.double("duration") ?? Self.defaultDuration
        duration = d.isFinite ? d : Self.defaultDuration
        ease = l.value("ease") ?? Self.defaultEase
        params = l.value("params")
        extra = l.extra()
    }

    /// ease が既定(easeInOut)のときは書かない。
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        for (k, v) in extra { try c.encode(v, forKey: AnyKey(k)) }
        try c.encode(kind, forKey: AnyKey("kind"))
        try c.encode(duration, forKey: AnyKey("duration"))
        if ease != Self.defaultEase { try c.encode(ease, forKey: AnyKey("ease")) }
        try c.encodeIfPresent(params, forKey: AnyKey("params"))
    }

    /// 長さを収める範囲: 0.05〜min(5, クリップの長さ / 2)。クリップが極端に短くて半分が 0.05 未満なら、半分まで。
    /// 頭と終わりがそれぞれ半分までなので、重ならない。
    public static func clampedDuration(_ d: Double, clipDuration: Double) -> Double {
        let hi = max(0, min(maxDuration, clipDuration / 2))
        let lo = min(minDuration, hi)
        guard d.isFinite else { return lo }
        return min(max(d, lo), hi)
    }

    /// このクリップの上での、実際に効く長さ。
    public func effectiveDuration(clipDuration: Double) -> Double {
        Self.clampedDuration(duration, clipDuration: clipDuration)
    }

    // MARK: ルールワイプの引数(params)

    /// ルールワイプの「やわらかさ」(params の "softness")。無ければ既定。
    public var ruleSoftness: Double {
        if case .object(let o) = params, case .number(let v) = o["softness"] { return RuleWipeMath.clampedSoftness(v) }
        return RuleWipeMath.defaultSoftness
    }

    /// カスタムルール画像の素材の場所(params の "ruleSrc")。無ければ nil(横ルールに倒す)。
    public var ruleSource: String? {
        if case .object(let o) = params, case .string(let s) = o["ruleSrc"], !s.isEmpty { return s }
        return nil
    }
}

// MARK: - 計算の結果

/// 描画を切り抜く形(キャンバスに対する割合)。
public enum TransitionMask: Equatable, Sendable {
    /// 見せる四角(x, y, 幅, 高さ。0〜1。左上原点)
    case rect(x: Double, y: Double, w: Double, h: Double)
    /// 中心から広がる円。半径は「キャンバスの対角線の半分」に対する割合(0〜1)
    case circle(Double)
    /// 12 時から時計回りに見せる割合(0〜1)
    case clock(Double)
    /// ルール画像ワイプ: (ルールの名前(RuleWipeKind の rawValue か "custom")、見えている度合い 0〜1、
    /// やわらかさ、カスタム画像の素材の場所)
    case ruleImage(String, Double, Double, String?)

    /// 何も見えない形か。
    public var isEmpty: Bool {
        switch self {
        case .rect(_, _, let w, let h): return w <= 0 || h <= 0
        case .circle(let r): return r <= 0
        case .clock(let f): return f <= 0
        case .ruleImage(_, let p, _, _): return p <= 0
        }
    }
}

/// 時刻 t でトランジションが、キーフレームの値に「上から」かける補正。
public struct TransitionState: Equatable, Sendable {
    public var opacityMul = 1.0
    public var scaleMul = 1.0
    /// キャンバスに対する割合(x は幅、y は高さ)。足す
    public var offsetX = 0.0
    public var offsetY = 0.0
    /// 度。足す
    public var rotationAdd = 0.0
    /// 1920×1080 のときの px。足す(解像度が違えば描画側で比例させる)
    public var blurAdd = 0.0
    /// モザイクのブロックの大きさ(1920×1080 のときの px)。大きい方を取る
    public var pixelateAdd = 0.0
    /// 傾斜変形(横方向のずらし、度)。足す
    public var skewXAdd = 0.0
    /// 境界ぼかしの帯の幅(短い辺に対する割合 0〜0.5)。大きい方を取る
    public var feather = 0.0
    public var mask: TransitionMask?
    /// モーフカット(境界の相手のコマとの変形補間)。他のフィールドは変えない
    public var morphCut: MorphCutVisualState?

    public init() {}

    public var isIdentity: Bool { self == TransitionState() }

    /// 位置・大きさ・回転を動かすか(文字のビットマップキャッシュを使えない)。
    public var movesGeometry: Bool { offsetX != 0 || offsetY != 0 || scaleMul != 1 || rotationAdd != 0 || skewXAdd != 0 }

    /// 頭と終わりの両方が効く(とても短いクリップ)ときの重ね合わせ。
    func combined(with o: TransitionState) -> TransitionState {
        var s = self
        s.opacityMul *= o.opacityMul; s.scaleMul *= o.scaleMul
        s.offsetX += o.offsetX; s.offsetY += o.offsetY
        s.rotationAdd += o.rotationAdd; s.blurAdd += o.blurAdd
        s.pixelateAdd = max(s.pixelateAdd, o.pixelateAdd)
        s.skewXAdd += o.skewXAdd
        s.feather = max(s.feather, o.feather)
        s.mask = o.mask ?? mask
        s.morphCut = o.morphCut ?? morphCut
        return s
    }
}

// MARK: - 計算

/// トランジションの計算(UI にも描画にも依存しない純粋な関数)。
public enum TransitionMath {
    /// 「見えている度合い」u(0 = 出る前/消えた後、1 = 完全に見える)から効果を作る。
    /// center = クリップの中心(キャンバスの割合)、size = クリップの枠の大きさ(同じく割合)。スライドの移動量に使う。
    public static func state(kind: TransitionKind, edge: TransitionEdge, u rawU: Double,
                             center: (x: Double, y: Double) = (0.5, 0.5), size: (w: Double, h: Double) = (0, 0),
                             softness: Double = RuleWipeMath.defaultSoftness, ruleSource: String? = nil) -> TransitionState {
        let u = min(max(rawU, 0), 1)
        var s = TransitionState()
        if u >= 1 { return s }
        let r = 1 - u
        switch kind {
        case .fade:
            s.opacityMul = u
        case .zoom:
            s.scaleMul = max(u, 1e-4)
        case .slideLeft:
            s.offsetX = -r * (center.x + size.w / 2)
        case .slideRight:
            s.offsetX = r * (1 - center.x + size.w / 2)
        case .slideUp:
            s.offsetY = -r * (center.y + size.h / 2)
        case .slideDown:
            s.offsetY = r * (1 - center.y + size.h / 2)
        case .wipeLeft, .wipeRight, .wipeUp, .wipeDown:
            // 出るときは見せる範囲が「向きの側」へ広がる。消えるときは同じ向きに消していく(線の動く向きが同じ)
            var k = kind
            if edge == .out {
                switch kind {
                case .wipeLeft: k = .wipeRight
                case .wipeRight: k = .wipeLeft
                case .wipeUp: k = .wipeDown
                default: k = .wipeUp
                }
            }
            switch k {
            case .wipeRight: s.mask = .rect(x: 0, y: 0, w: u, h: 1)
            case .wipeLeft: s.mask = .rect(x: 1 - u, y: 0, w: u, h: 1)
            case .wipeDown: s.mask = .rect(x: 0, y: 0, w: 1, h: u)
            default: s.mask = .rect(x: 0, y: 1 - u, w: 1, h: u)
            }
        case .wipeCircle:
            s.mask = .circle(u)
        case .wipeClock:
            s.mask = .clock(u)
        case .blur:
            s.opacityMul = u
            s.blurAdd = 60 * r
        case .spin:
            s.opacityMul = u
            s.rotationAdd = (edge == .in ? -90 : 90) * r
        // MARK: ルール画像ワイプ(#60): 見えている度合い u をそのままルールの進行度にする
        // (退場は u が 1→0 に戻るので、現れた順と逆に消える)
        case .ruleHorizontal, .ruleVertical, .ruleDiagonal, .ruleCircle, .ruleSquare, .ruleDiamond,
             .ruleClock, .ruleChecker, .ruleStripesH, .ruleStripesV, .ruleSpiral:
            s.mask = .ruleImage(kind.ruleKind?.rawValue ?? RuleWipeKind.horizontal.rawValue, u, RuleWipeMath.clampedSoftness(softness), nil)
        case .ruleCustom:
            s.mask = .ruleImage("custom", u, RuleWipeMath.clampedSoftness(softness), ruleSource)
        // MARK: 登場/退場の演出(#61)
        case .fadeZoom:
            s.opacityMul = u
            s.scaleMul = 0.9 + 0.1 * u
        case .pop:
            s.scaleMul = max(easeOutBack(u), 1e-4)
            s.opacityMul = min(1, u * 2)
        case .blurRelease:
            s.blurAdd = 60 * r
        case .mosaicRelease:
            s.pixelateAdd = 64 * r
        case .edgeBlurRelease:
            s.blurAdd = 40 * r
            s.feather = 0.35 * r
        case .skewIn:
            s.skewXAdd = (edge == .in ? -35 : 35) * r
            s.opacityMul = u
        case .shatter:
            // ブロック単位に散らばった順で出る/消える + わずかな回転と縮小
            s.mask = .ruleImage(RuleWipeKind.scatter.rawValue, u, 0, nil)
            s.rotationAdd = (edge == .in ? -6 : 6) * r
            s.scaleMul = 0.92 + 0.08 * u
        case .bounceIn:
            s.offsetY = (1 - easeOutBounce(u)) * 0.45
        case .riseIn:
            s.rotationAdd = (edge == .in ? -75 : 75) * r
            s.offsetY = 0.18 * r
            s.opacityMul = u
        case .regionLeft:
            s.offsetX = -r * (size.w + 0.02)
        case .regionRight:
            s.offsetX = r * (size.w + 0.02)
        case .regionUp:
            s.offsetY = -r * (size.h + 0.02)
        case .regionDown:
            s.offsetY = r * (size.h + 0.02)
        case .driftLeft:
            s.offsetX = -0.25 * r
            s.opacityMul = u
        case .driftRight:
            s.offsetX = 0.25 * r
            s.opacityMul = u
        case .driftUp:
            s.offsetY = -0.25 * r
            s.opacityMul = u
        case .driftDown:
            s.offsetY = 0.25 * r
            s.opacityMul = u
        case .morphCut:
            s.morphCut = MorphCutVisualState(isIn: edge == .in, weight: edge == .in ? u : 1 - u)
        }
        return s
    }

    /// 跳ねる進み方(easeOutBounce)。u=0 で 0、u=1 で 1、途中で数回跳ねる。
    public static func easeOutBounce(_ rawU: Double) -> Double {
        let u = min(max(rawU, 0), 1)
        let n1 = 7.5625, d1 = 2.75
        if u < 1 / d1 { return n1 * u * u }
        if u < 2 / d1 { let v = u - 1.5 / d1; return n1 * v * v + 0.75 }
        if u < 2.5 / d1 { let v = u - 2.25 / d1; return n1 * v * v + 0.9375 }
        let v = u - 2.625 / d1
        return n1 * v * v + 0.984375
    }

    /// 行き過ぎて戻る進み方(easeOutBack)。u=0 で 0、途中で 1 を少し超えて u=1 で 1。
    public static func easeOutBack(_ rawU: Double) -> Double {
        let u = min(max(rawU, 0), 1)
        let c1 = 1.70158, c3 = c1 + 1
        return 1 + c3 * pow(u - 1, 3) + c1 * pow(u - 1, 2)
    }

    /// 頭の u: 0 から clipの頭からの秒 rel が長さ d に達するまで ease で 0→1。範囲外は nil(効かない)。
    static func inProgress(_ tr: Transition, rel: Double, clipDuration: Double) -> Double? {
        let d = tr.effectiveDuration(clipDuration: clipDuration)
        guard d > 0, rel < d else { return nil }
        return tr.ease.apply(max(0, rel) / d)
    }

    /// 終わりの u: 終わりまでの残りが d 以内のとき、経った割合に ease をかけて 1→0。
    static func outProgress(_ tr: Transition, rel: Double, clipDuration: Double) -> Double? {
        let d = tr.effectiveDuration(clipDuration: clipDuration)
        let remaining = clipDuration - rel
        guard d > 0, remaining < d else { return nil }
        return 1 - tr.ease.apply(min(1, max(0, 1 - remaining / d)))
    }

    /// 時刻 t(プロジェクトの時刻)でのクリップの効果。トランジションが無い・知らない種類・効く時間の外なら単位(何もしない)。
    public static func apply(_ clip: Clip, t: Double, center: (x: Double, y: Double)? = nil, size: (w: Double, h: Double) = (0, 0)) -> TransitionState {
        var out = TransitionState()
        let rel = t - clip.start
        let c = center ?? (clip.xOrDefault, clip.yOrDefault)
        if let tr = clip.transitionIn, let k = tr.known, let u = inProgress(tr, rel: rel, clipDuration: clip.duration) {
            out = out.combined(with: state(kind: k, edge: .in, u: u, center: c, size: size, softness: tr.ruleSoftness, ruleSource: tr.ruleSource))
        }
        if let tr = clip.transitionOut, let k = tr.known, let u = outProgress(tr, rel: rel, clipDuration: clip.duration) {
            out = out.combined(with: state(kind: k, edge: .out, u: u, center: c, size: size, softness: tr.ruleSoftness, ruleSource: tr.ruleSource))
        }
        return out
    }
}

// MARK: - 音声のフェード

/// 音量のフェード(サンプル単位)。純粋な関数。
public enum AudioFade {
    public static let curves = ["linear", "equalPower"]

    /// クリップの頭から `pos` 番目のサンプル(0 始まり、全体で `length` サンプル)にかける倍率。
    /// フェードインは 0 から 1 へ(pos 0 は 0)、フェードアウトは 1 から終わりのサンプルでほぼ 0 へ。
    public static func gain(pos: Int, length: Int, fadeIn: Int, fadeOut: Int, equalPower: Bool) -> Float {
        var g: Float = 1
        if fadeIn > 0, pos < fadeIn {
            let r = Float(max(0, pos)) / Float(fadeIn)
            g *= equalPower ? sinf(r * .pi / 2) : r
        }
        let remaining = length - pos
        if fadeOut > 0, remaining <= fadeOut {
            let r = Float(max(0, remaining)) / Float(fadeOut)
            g *= equalPower ? sinf(r * .pi / 2) : r
        }
        return g
    }
}
