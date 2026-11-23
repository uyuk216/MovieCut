import Foundation

// MARK: - ルール画像ワイプ(#60)
//
// YMM4 式の「ルール画像」によるワイプ: グレースケール画像の明るさが、その場所が
// 見えるようになる進行度(しきい値)を決める。進行度 u が画素の値(0〜1)を
// 追い越した所から見える。ここではルール画像を「式で作る内蔵プリセット」として持ち、
// カスタム画像は輝度画素列を取り込んで同じ計算に流す(Transition の params["ruleSrc"]、
// 描画側が素材画像を輝度に直して渡す)。
// 計算はすべて純粋関数(UI・描画に依存しない)。

/// 内蔵ルール画像の種類。rawValue はファイル・パラメータに書く文字列。
public enum RuleWipeKind: String, CaseIterable, Sendable {
    case horizontal, vertical, diagonal
    case circle, square, diamond, clock
    case checker, stripesHorizontal, stripesVertical, spiral
    /// 小さなブロックが散らばった順に出る/消える(砕け散り用)。
    case scatter

    /// 画面に出す名前。
    public var label: String {
        switch self {
        case .horizontal: return "ルールワイプ（横）"
        case .vertical: return "ルールワイプ（縦）"
        case .diagonal: return "ルールワイプ（斜め）"
        case .circle: return "ルールワイプ（円）"
        case .square: return "ルールワイプ（四角）"
        case .diamond: return "ルールワイプ（菱形）"
        case .clock: return "ルールワイプ（時計回り）"
        case .checker: return "ルールワイプ（市松）"
        case .stripesHorizontal: return "ルールワイプ（横縞）"
        case .stripesVertical: return "ルールワイプ（縦縞）"
        case .spiral: return "ルールワイプ（渦巻き）"
        case .scatter: return "ルールワイプ（散らばり）"
        }
    }
}

/// ルール画像とワイプ進行の計算。
public enum RuleWipeMath {
    /// 既定の「やわらかさ」(境界のにじみ幅、進行度に対する割合)。0 でくっきり。
    public static let defaultSoftness = 0.06
    /// やわらかさの上限。
    public static let maxSoftness = 0.4

    /// やわらかさを範囲に収める(壊れた値は既定)。
    public static func clampedSoftness(_ v: Double) -> Double {
        guard v.isFinite else { return defaultSoftness }
        return min(max(v, 0), maxSoftness)
    }

    // MARK: ルール画像の値(しきい値)

    /// 決定的なハッシュ(0〜1)。ブロックの出現順などに使う。
    static func hash01(_ a: Int, _ b: Int) -> Double {
        var z = UInt64(bitPattern: Int64((a &* 73856093) ^ (b &* 19349663))) &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }

    /// 位置 (x, y)(どちらも 0〜1、左上原点)でのルール画像の値(0〜1)。
    /// `aspect` は画面の幅/高さ。円・四角・菱形・時計回り・渦巻きは中心基準で、
    /// 形が歪まないよう横方向を aspect で割ってから測る。
    public static func field(_ kind: RuleWipeKind, x: Double, y: Double, aspect: Double = 1) -> Double {
        let xx = min(max(x, 0), 1), yy = min(max(y, 0), 1)
        let a = aspect.isFinite && aspect > 0 ? aspect : 1
        // 中心基準(横は -0.5〜0.5 にそろえる)
        let dx = (xx - 0.5) * a, dy = yy - 0.5
        switch kind {
        case .horizontal: return xx
        case .vertical: return yy
        case .diagonal: return (xx + yy) / 2
        case .circle:
            let r = (dx * dx + dy * dy).squareRoot()
            let m = (0.25 * a * a + 0.25).squareRoot()
            return min(r / m, 1)
        case .square:
            return min(max(abs(dx), abs(dy)) / max(0.5 * a, 0.5), 1)
        case .diamond:
            return min((abs(dx) + abs(dy)) / (0.5 * a + 0.5), 1)
        case .clock:
            if dx == 0, dy == 0 { return 0 }
            var ang = atan2(dx, -dy)          // 12 時を 0、時計回りに増える
            if ang < 0 { ang += 2 * Double.pi }
            return ang / (2 * Double.pi)
        case .checker:
            let cols = 8, rows = 8
            let col = min(cols - 1, Int(xx * Double(cols))), row = min(rows - 1, Int(yy * Double(rows)))
            let local = (xx * Double(cols) - Double(col) + yy * Double(rows) - Double(row)) / 2
            return (Double(row * cols + col) + local) / Double(rows * cols)
        case .stripesHorizontal:
            let bands = 6
            let band = min(bands - 1, Int(yy * Double(bands)))
            return (Double(band) + xx) / Double(bands)
        case .stripesVertical:
            let bands = 6
            let band = min(bands - 1, Int(xx * Double(bands)))
            return (Double(band) + yy) / Double(bands)
        case .spiral:
            let r = min((dx * dx + dy * dy).squareRoot() / (0.25 * a * a + 0.25).squareRoot(), 1)
            var ang = atan2(dx, -dy)
            if ang < 0 { ang += 2 * Double.pi }
            return min((r * 2 + ang / (2 * Double.pi)) / 3, 1)
        case .scatter:
            let cols = 10, rows = 6
            let col = min(cols - 1, Int(xx * Double(cols))), row = min(rows - 1, Int(yy * Double(rows)))
            return hash01(col, row)
        }
    }

    // MARK: 進行度 → 見え方

    /// ルール値 `f` の場所の、進行度 `u`(0〜1)での見え具合(0=見えない、1=完全に見える)。
    /// やわらかさ `s` があると、境界が幅 s の帯でにじむ。u=0 では何も見えず、u=1 では全部見える。
    public static func alpha(field f: Double, progress u: Double, softness s: Double) -> Double {
        let uu = min(max(u, 0), 1)
        let ss = clampedSoftness(s)
        if ss <= 0 { return uu <= 0 ? 0 : (f <= uu ? 1 : 0) }
        return min(max((uu * (1 + ss) - f) / ss, 0), 1)
    }

    /// 位置での見え具合(内蔵ルール)。
    public static func alpha(_ kind: RuleWipeKind, x: Double, y: Double, progress u: Double, softness s: Double, aspect: Double = 1) -> Double {
        alpha(field: field(kind, x: x, y: y, aspect: aspect), progress: u, softness: s)
    }

    /// 見えている面積の割合(数値積分。テストと表示の目安用)。
    public static func visibleFraction(_ kind: RuleWipeKind, progress u: Double, softness s: Double, samples n: Int = 48, aspect: Double = 1) -> Double {
        let m = max(2, n)
        var sum = 0.0
        for j in 0..<m {
            for i in 0..<m {
                sum += alpha(kind, x: (Double(i) + 0.5) / Double(m), y: (Double(j) + 0.5) / Double(m), progress: u, softness: s, aspect: aspect)
            }
        }
        return sum / Double(m * m)
    }

    // MARK: 画素列の生成(描画側がマスク画像にする)

    /// ルール画像そのもの(グレースケール 0〜255、行優先・左上原点)。
    public static func grayscalePixels(_ kind: RuleWipeKind, width w: Int, height h: Int, aspect: Double? = nil) -> [UInt8] {
        guard w > 0, h > 0 else { return [] }
        let a = aspect ?? (h > 0 ? Double(w) / Double(h) : 1)
        var out = [UInt8](repeating: 0, count: w * h)
        for j in 0..<h {
            for i in 0..<w {
                let f = field(kind, x: (Double(i) + 0.5) / Double(w), y: (Double(j) + 0.5) / Double(h), aspect: a)
                out[j * w + i] = UInt8((min(max(f, 0), 1) * 255).rounded())
            }
        }
        return out
    }

    /// 進行度 u でのマスク画素(0=透明、255=不透明、行優先・左上原点)。内蔵ルール版。
    public static func maskPixels(_ kind: RuleWipeKind, progress u: Double, softness s: Double, width w: Int, height h: Int, aspect: Double? = nil) -> [UInt8] {
        guard w > 0, h > 0 else { return [] }
        let a = aspect ?? (h > 0 ? Double(w) / Double(h) : 1)
        var out = [UInt8](repeating: 0, count: w * h)
        for j in 0..<h {
            for i in 0..<w {
                let v = alpha(kind, x: (Double(i) + 0.5) / Double(w), y: (Double(j) + 0.5) / Double(h), progress: u, softness: s, aspect: a)
                out[j * w + i] = UInt8((v * 255).rounded())
            }
        }
        return out
    }

    /// カスタム画像の輝度画素(0〜255)をルール値(0〜1)へ。
    public static func fieldFromLuminance(_ pixels: [UInt8]) -> [Double] { pixels.map { Double($0) / 255 } }

    /// カスタムのルール値列(行優先、w×h)からマスク画素を作る。
    public static func maskPixels(field f: [Double], width w: Int, height h: Int, progress u: Double, softness s: Double) -> [UInt8] {
        guard w > 0, h > 0, f.count == w * h else { return [] }
        return f.map { UInt8((alpha(field: $0, progress: u, softness: s) * 255).rounded()) }
    }
}

// MARK: - 境界ぼかし(フェザー)のマスク

/// クリップの縁だけを薄くするマスクの計算(境界ぼかし解除 #61 用)。
/// `feather` は「縁から内側へ薄くなる帯の幅」(短い辺に対する割合、0〜0.5)。
public enum FeatherMath {
    /// 位置 (x, y)(0〜1)での見え具合。内側は 1、縁は 0。
    /// 帯の幅は「短い辺に対する割合」なので、距離は画素に直して比べる(横長・縦長で帯幅が軸ごとに変わらないように)。
    /// `aspect` は幅/高さ(正方形は 1)。
    public static func alpha(x: Double, y: Double, feather f: Double, aspect: Double = 1) -> Double {
        let ff = min(max(f, 0), 0.5)
        guard ff > 0 else { return 1 }
        let a = (aspect.isFinite && aspect > 0) ? aspect : 1
        // 高さを 1 とした画素距離。短い辺は min(a, 1)
        let d = min(min(x, 1 - x) * a, min(y, 1 - y))
        return min(max(d / (ff * min(a, 1)), 0), 1)
    }

    /// マスク画素(行優先・左上原点)。
    public static func maskPixels(feather f: Double, width w: Int, height h: Int) -> [UInt8] {
        guard w > 0, h > 0 else { return [] }
        var out = [UInt8](repeating: 0, count: w * h)
        for j in 0..<h {
            for i in 0..<w {
                let v = alpha(x: (Double(i) + 0.5) / Double(w), y: (Double(j) + 0.5) / Double(h), feather: f, aspect: Double(w) / Double(h))
                out[j * w + i] = UInt8((v * 255).rounded())
            }
        }
        return out
    }
}
