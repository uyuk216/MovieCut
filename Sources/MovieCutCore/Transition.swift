import Foundation
import CoreGraphics

// MARK: - トランジションの種類

/// クリップの頭(in)・終わり(out)につける映像の効果の種類。ファイルには文字列(rawValue)で書く。
/// 知らない文字列も `Transition.kind` にそのまま残し、描くときは何もしない(無効)。
public enum TransitionKind: String, CaseIterable, Sendable {
    case fade, zoom
    case slideLeft, slideRight, slideUp, slideDown
    case wipeLeft, wipeRight, wipeUp, wipeDown
    case wipeCircle, wipeClock
    case blur, spin

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
        }
    }

    var isSlide: Bool { [.slideLeft, .slideRight, .slideUp, .slideDown].contains(self) }
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

    /// 何も見えない形か。
    public var isEmpty: Bool {
        switch self {
        case .rect(_, _, let w, let h): return w <= 0 || h <= 0
        case .circle(let r): return r <= 0
        case .clock(let f): return f <= 0
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
    public var mask: TransitionMask?

    public init() {}

    public var isIdentity: Bool { self == TransitionState() }

    /// 位置・大きさ・回転を動かすか(文字のビットマップキャッシュを使えない)。
    public var movesGeometry: Bool { offsetX != 0 || offsetY != 0 || scaleMul != 1 || rotationAdd != 0 }

    /// 頭と終わりの両方が効く(とても短いクリップ)ときの重ね合わせ。
    func combined(with o: TransitionState) -> TransitionState {
        var s = self
        s.opacityMul *= o.opacityMul; s.scaleMul *= o.scaleMul
        s.offsetX += o.offsetX; s.offsetY += o.offsetY
        s.rotationAdd += o.rotationAdd; s.blurAdd += o.blurAdd
        s.mask = o.mask ?? mask
        return s
    }
}

// MARK: - 計算

/// トランジションの計算(UI にも描画にも依存しない純粋な関数)。
public enum TransitionMath {
    /// 「見えている度合い」u(0 = 出る前/消えた後、1 = 完全に見える)から効果を作る。
    /// center = クリップの中心(キャンバスの割合)、size = クリップの枠の大きさ(同じく割合)。スライドの移動量に使う。
    public static func state(kind: TransitionKind, edge: TransitionEdge, u rawU: Double,
                             center: (x: Double, y: Double) = (0.5, 0.5), size: (w: Double, h: Double) = (0, 0)) -> TransitionState {
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
        }
        return s
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
            out = out.combined(with: state(kind: k, edge: .in, u: u, center: c, size: size))
        }
        if let tr = clip.transitionOut, let k = tr.known, let u = outProgress(tr, rel: rel, clipDuration: clip.duration) {
            out = out.combined(with: state(kind: k, edge: .out, u: u, center: c, size: size))
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
