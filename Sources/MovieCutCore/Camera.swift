import Foundation
import CoreGraphics

// MARK: - カメラ(W3-02 / YMM4 監査 #54)
//
// プロジェクト全体にかかるカメラワーク: 位置(カメラ中心)・注目点(回り込みの軸)・
// 回り込み(注目点を中心とした回転)・視野角(ズーム相当)。
// 変換は「注目点を軸に回転＋拡大し、カメラ位置が画面中央に来るよう平行移動する」
// 2.5D の相似変換として、Renderer の最終合成段で 1 回だけかける。
// 既定値(位置・注目点とも中央、回り込み 0、視野角 = 既定)のときは変換そのものを
// 行わないので、カメラ未使用のプロジェクトの描画は従来と画素単位で完全一致する。
// キーフレームの時刻はプロジェクト時刻(カメラはプロジェクト単位なので、
// クリップのキーと違いクリップ頭基準ではない)。

/// カメラの時刻ごとの解決済みの値(範囲に収めたもの)。
public struct CameraState: Equatable, Sendable {
    /// カメラ位置(画面中央に映る点。キャンバスに対する割合・左上原点)。
    public var x: Double
    public var y: Double
    /// 注目点(回り込み・拡大の軸。キャンバスに対する割合・左上原点)。
    public var targetX: Double
    public var targetY: Double
    /// 回り込み(度。画面上で時計回りが正)。
    public var orbit: Double
    /// 視野角(度。小さいほど望遠 = 拡大)。
    public var fov: Double

    public init(x: Double, y: Double, targetX: Double, targetY: Double, orbit: Double, fov: Double) {
        self.x = x; self.y = y; self.targetX = targetX; self.targetY = targetY
        self.orbit = orbit; self.fov = fov
    }

    /// 視野角から決まる拡大率(既定の視野角で 1)。
    public var zoom: Double { CameraSettings.zoom(forFov: fov) }

    /// 恒等変換か(位置が中央・回り込み 0・拡大 1)。注目点は、回転も拡大も無いときは絵に影響しない。
    public var isIdentity: Bool {
        abs(x - 0.5) < 1e-12 && abs(y - 0.5) < 1e-12 && abs(orbit) < 1e-12 && abs(zoom - 1) < 1e-12
    }
}

public struct CameraSettings: Codable, Equatable, Sendable {
    /// カメラ位置 X(割合)。既定 0.5。
    public var x: Double = 0.5
    /// カメラ位置 Y(割合)。既定 0.5。
    public var y: Double = 0.5
    /// 注目点 X(割合)。既定 0.5。
    public var targetX: Double = 0.5
    /// 注目点 Y(割合)。既定 0.5。
    public var targetY: Double = 0.5
    /// 回り込み(度)。既定 0。
    public var orbit: Double = 0
    /// 視野角(度)。既定 60。
    public var fov: Double = CameraSettings.defaultFov
    /// キーフレーム(項目名 "x" "y" "targetX" "targetY" "orbit" "fov" → キー列)。時刻はプロジェクト時刻(秒)。
    /// 空のときはファイルに書かない。
    public var keyframes: [String: [Keyframe]] = [:]

    public static let defaultFov = 60.0
    /// キーフレームで動かせる項目。
    public static let paramKeys = ["x", "y", "targetX", "targetY", "orbit", "fov"]

    public init() {}

    public init(x: Double, y: Double, targetX: Double, targetY: Double, orbit: Double, fov: Double, keyframes: [String: [Keyframe]] = [:]) {
        self.x = x; self.y = y; self.targetX = targetX; self.targetY = targetY
        self.orbit = orbit; self.fov = fov; self.keyframes = keyframes
    }

    /// 項目ごとの値の範囲。
    public static func range(of key: String) -> ClosedRange<Double> {
        switch key {
        case "x", "y", "targetX", "targetY": return -1...2
        case "orbit": return -360...360
        case "fov": return 10...170
        default: return -1e9...1e9
        }
    }

    /// 項目の静的な(キーが無いときの)既定値。
    public static func defaultValue(of key: String) -> Double {
        switch key {
        case "orbit": return 0
        case "fov": return defaultFov
        default: return 0.5
        }
    }

    /// 画面に出す名前。
    public static func label(of key: String) -> String {
        switch key {
        case "x": return "カメラ位置 X"
        case "y": return "カメラ位置 Y"
        case "targetX": return "注目点 X"
        case "targetY": return "注目点 Y"
        case "orbit": return "回り込み（°）"
        case "fov": return "視野角（°）"
        default: return key
        }
    }

    public static func clamp(_ key: String, _ v: Double) -> Double {
        let r = range(of: key)
        guard v.isFinite else { return defaultValue(of: key) }
        return min(max(v, r.lowerBound), r.upperBound)
    }

    /// 視野角 → 拡大率。zoom = tan(既定/2) / tan(fov/2)。
    public static func zoom(forFov fov: Double) -> Double {
        let f = clamp("fov", fov) * Double.pi / 180
        let d = defaultFov * Double.pi / 180
        let t = tan(f / 2)
        guard t > 1e-9 else { return 1 }
        return tan(d / 2) / t
    }

    /// 既定値そのものか(キーフレームも無い)。このとき Project はファイルに書かず、描画も従来経路のまま。
    public var isDefault: Bool {
        x == 0.5 && y == 0.5 && targetX == 0.5 && targetY == 0.5 && orbit == 0 && fov == Self.defaultFov
            && keyframes.values.allSatisfy { $0.isEmpty }
    }

    /// 値とキーを範囲・整列に直したもの(読み込み時に使う)。
    public var normalized: CameraSettings {
        var o = self
        o.x = Self.clamp("x", x); o.y = Self.clamp("y", y)
        o.targetX = Self.clamp("targetX", targetX); o.targetY = Self.clamp("targetY", targetY)
        o.orbit = Self.clamp("orbit", orbit); o.fov = Self.clamp("fov", fov)
        var ks: [String: [Keyframe]] = [:]
        for (key, list) in keyframes where Self.paramKeys.contains(key) {
            let n = Animation.normalized(list.map { Keyframe(t: max(0, $0.t), v: Self.clamp(key, $0.v), ease: $0.ease) })
            if !n.isEmpty { ks[key] = n }
        }
        o.keyframes = ks
        return o
    }

    /// 項目の静的な値(キーを見ない)。
    public func staticValue(of key: String) -> Double {
        switch key {
        case "x": return x
        case "y": return y
        case "targetX": return targetX
        case "targetY": return targetY
        case "orbit": return orbit
        case "fov": return fov
        default: return Self.defaultValue(of: key)
        }
    }

    /// 項目名で静的な値を書く。
    public mutating func setStaticValue(_ v: Double, of key: String) {
        let c = Self.clamp(key, v)
        switch key {
        case "x": x = c
        case "y": y = c
        case "targetX": targetX = c
        case "targetY": targetY = c
        case "orbit": orbit = c
        case "fov": fov = c
        default: break
        }
    }

    /// 時刻 t(プロジェクト時刻)での項目の値。キーがあれば補間、無ければ静的な値。範囲に収める。
    public func value(of key: String, at t: Double) -> Double {
        if let ks = keyframes[key], let v = Animation.interpolate(ks, at: t) { return Self.clamp(key, v) }
        return Self.clamp(key, staticValue(of: key))
    }

    /// その項目にキーがあるか。
    public func isAnimated(_ key: String) -> Bool { !(keyframes[key]?.isEmpty ?? true) }

    /// 時刻 t での解決済みのカメラ。
    public func state(at t: Double) -> CameraState {
        CameraState(x: value(of: "x", at: t), y: value(of: "y", at: t),
                    targetX: value(of: "targetX", at: t), targetY: value(of: "targetY", at: t),
                    orbit: value(of: "orbit", at: t), fov: value(of: "fov", at: t))
    }

    // MARK: ファイル形式(既定と違う項目だけ書く)

    static let knownKeys: Set<String> = ["x", "y", "targetX", "targetY", "orbit", "fov", "keyframes"]
    public var extra: [String: JSONValue] = [:]

    public init(from decoder: Decoder) throws {
        let l = Lenient(c: try decoder.container(keyedBy: AnyKey.self), known: Self.knownKeys)
        x = l.double("x") ?? x
        y = l.double("y") ?? y
        targetX = l.double("targetX") ?? targetX
        targetY = l.double("targetY") ?? targetY
        orbit = l.double("orbit") ?? orbit
        fov = l.double("fov") ?? fov
        extra = l.extra()
        if let raw: JSONValue = l.value("keyframes") {
            if let ks: [String: [Keyframe]] = l.value("keyframes") { keyframes = ks } else { extra["keyframes"] = raw }
        }
        self = normalized
        // normalized で落とした未知キーは extra に残っている(normalized は extra をそのまま運ぶ)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        for (k, v) in extra { try c.encode(v, forKey: AnyKey(k)) }
        if x != 0.5 { try c.encode(x, forKey: AnyKey("x")) }
        if y != 0.5 { try c.encode(y, forKey: AnyKey("y")) }
        if targetX != 0.5 { try c.encode(targetX, forKey: AnyKey("targetX")) }
        if targetY != 0.5 { try c.encode(targetY, forKey: AnyKey("targetY")) }
        if orbit != 0 { try c.encode(orbit, forKey: AnyKey("orbit")) }
        if fov != Self.defaultFov { try c.encode(fov, forKey: AnyKey("fov")) }
        let ks = keyframes.filter { !$0.value.isEmpty }
        if !ks.isEmpty { try c.encode(ks, forKey: AnyKey("keyframes")) }
    }
}

// MARK: - カメラ変換の計算

public enum CameraMath {
    /// 状態 → キャンバス画素座標(左上原点)でのアフィン変換。
    /// p' = C + R(θ)·z·(p − L) + z·(L − P)
    /// (C = 画面中央、P = カメラ位置、L = 注目点、z = 拡大率、R = 画面上で時計回りの回転)
    public static func transform(state s: CameraState, width W: Double, height H: Double) -> CGAffineTransform {
        let m = matrix(state: s, width: W, height: H)
        return CGAffineTransform(a: CGFloat(m.a), b: CGFloat(m.b), c: CGFloat(m.c), d: CGFloat(m.d),
                                 tx: CGFloat(m.tx), ty: CGFloat(m.ty))
    }

    /// 状態 → 1 点の変換(テスト・プレビューの当たり判定用。`transform` と同じ計算)。
    public static func map(_ p: CGPoint, state s: CameraState, width W: Double, height H: Double) -> CGPoint {
        let m = matrix(state: s, width: W, height: H)
        return CGPoint(x: m.a * Double(p.x) + m.c * Double(p.y) + m.tx,
                       y: m.b * Double(p.x) + m.d * Double(p.y) + m.ty)
    }

    /// 変換の逆(画面の点 → キャンバスの点)。行列式が 0 に近いときは入力のまま。
    public static func unmap(_ p: CGPoint, state s: CameraState, width W: Double, height H: Double) -> CGPoint {
        let m = matrix(state: s, width: W, height: H)
        let det = m.a * m.d - m.b * m.c
        guard abs(det) > 1e-12 else { return p }
        let dx = Double(p.x) - m.tx, dy = Double(p.y) - m.ty
        return CGPoint(x: (m.d * dx - m.c * dy) / det, y: (-m.b * dx + m.a * dy) / det)
    }

    private static func matrix(state s: CameraState, width W: Double, height H: Double)
        -> (a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double) {
        let z = s.zoom
        let th = s.orbit * Double.pi / 180
        let co = cos(th), si = sin(th)
        // M = z · R(θ)(左上原点・y 下向きの座標では、この符号で画面上の時計回りになる)
        let a = z * co, b = z * si, c = -z * si, d = z * co
        let px = s.x * W, py = s.y * H          // カメラ位置 P
        let lx = s.targetX * W, ly = s.targetY * H  // 注目点 L
        // t = C + z·(L − P) − M·L
        let tx = W / 2 + z * (lx - px) - (a * lx + c * ly)
        let ty = H / 2 + z * (ly - py) - (b * lx + d * ly)
        return (a, b, c, d, tx, ty)
    }
}
