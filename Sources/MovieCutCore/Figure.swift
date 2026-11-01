import Foundation
import CoreGraphics

// MARK: - 図形(クリップの種類 shape)
//
// 素材を持たない図形: 四角・楕円・線・矢印・星。位置と大きさは `x`・`y`(中心)・`w`・`h`(キャンバスに対する割合)で、
// キーフレームで動かせる(ビジュアライザと同じ)。見た目は `figure` に、設定した項目だけ書く。
// 太さ(strokeWidth)は 1080p の画素数で書き、書き出しの解像度に比例させる。

public enum FigureKind: String, CaseIterable, Codable, Sendable {
    case rect, ellipse, line, arrow, star

    /// メニューと一覧に出す題。
    public var title: String {
        switch self {
        case .rect: return "四角形"
        case .ellipse: return "楕円"
        case .line: return "線"
        case .arrow: return "矢印"
        case .star: return "星"
        }
    }

    /// 線・矢印は塗らず、線の色と太さで描く。
    public var isStrokeOnly: Bool { self == .line || self == .arrow }

    /// 既定の大きさ(キャンバスに対する割合)。
    public var defaultSize: (w: Double, h: Double) {
        switch self {
        case .rect, .ellipse: return (0.3, 0.2)
        case .line, .arrow: return (0.4, 0.2)
        case .star: return (0.2, 0.2)
        }
    }
}

/// 図形の見た目。未設定の項目は既定値。ファイルには設定した項目だけ書く。
public struct Figure: Codable, Equatable, Sendable {
    public static let defaultFill = "#ffffff"
    /// 線・矢印の既定の太さ(1080p の画素)。
    public static let defaultStrokeOnlyWidth = 8.0
    public static let strokeWidthRange: ClosedRange<Double> = 0...60
    public static let cornerRange: ClosedRange<Double> = 0...0.5
    /// "none" は塗り・線を描かない。
    public static let noneColor = "none"

    /// 図形の種類(rect / ellipse / line / arrow / star)。未知の値は四角形。
    public var kind: String?
    /// 塗りの色(#rrggbb、または "none")。
    public var fill: String?
    /// 線の色(#rrggbb、または "none")。
    public var stroke: String?
    /// 線の太さ(1080p の画素。0 = 線なし)。線・矢印は未設定のとき 8。
    public var strokeWidth: Double?
    /// 角丸(四角形だけ。短い辺に対する割合 0〜0.5)。
    public var corner: Double?

    /// 知らないキー(新しい版が書いた項目)。そのまま書き戻す。
    public var extra: [String: JSONValue] = [:]
    static let knownKeys: Set<String> = ["kind", "fill", "stroke", "strokeWidth", "corner"]

    public init(kind: String? = nil, fill: String? = nil, stroke: String? = nil, strokeWidth: Double? = nil, corner: Double? = nil) {
        self.kind = kind; self.fill = fill; self.stroke = stroke; self.strokeWidth = strokeWidth; self.corner = corner
    }

    public init(from decoder: Decoder) throws {
        let l = Lenient(c: try decoder.container(keyedBy: AnyKey.self), known: Self.knownKeys)
        kind = l.string("kind")
        fill = l.string("fill")
        stroke = l.string("stroke")
        strokeWidth = l.double("strokeWidth")
        corner = l.double("corner")
        extra = l.extra()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        for (k, v) in extra { try c.encode(v, forKey: AnyKey(k)) }
        try c.encodeIfPresent(kind, forKey: AnyKey("kind"))
        try c.encodeIfPresent(fill, forKey: AnyKey("fill"))
        try c.encodeIfPresent(stroke, forKey: AnyKey("stroke"))
        try c.encodeIfPresent(strokeWidth, forKey: AnyKey("strokeWidth"))
        try c.encodeIfPresent(corner, forKey: AnyKey("corner"))
    }

    public var figureKind: FigureKind { FigureKind(rawValue: kind ?? "") ?? .rect }
    public var fillOrDefault: String { fill ?? Self.defaultFill }
    public var strokeOrDefault: String { stroke ?? Self.noneColor }
    public var strokeWidthOrDefault: Double {
        let w = strokeWidth ?? (figureKind.isStrokeOnly ? Self.defaultStrokeOnlyWidth : 0)
        return w.isFinite ? min(max(w, Self.strokeWidthRange.lowerBound), Self.strokeWidthRange.upperBound) : 0
    }
    public var cornerOrDefault: Double {
        let c = corner ?? 0
        return c.isFinite ? min(max(c, Self.cornerRange.lowerBound), Self.cornerRange.upperBound) : 0
    }

    /// 既定と同じ項目を外す(全部既定なら nil を返し、ファイルに何も書かない)。
    public var normalized: Figure? {
        var f = self
        if f.kind == FigureKind.rect.rawValue { f.kind = nil }
        if f.fill?.lowercased() == Self.defaultFill { f.fill = nil }
        if f.stroke == Self.noneColor { f.stroke = nil }
        if f.strokeWidth == (figureKind.isStrokeOnly ? Self.defaultStrokeOnlyWidth : 0) { f.strokeWidth = nil }
        if f.corner == 0 { f.corner = nil }
        let empty = f.kind == nil && f.fill == nil && f.stroke == nil && f.strokeWidth == nil && f.corner == nil && f.extra.isEmpty
        return empty ? nil : f
    }
}

/// 図形の path の形(中心を原点とする、幅 w・高さ h の箱の中)。描画と検査の両方に使う純粋な関数。
public enum FigureGeometry {
    /// 四角形・楕円・星・線・矢印の path。線と矢印は左上から右下へ引く(向きは反転で変える)。矢印の先は右下。
    /// `headLength` は矢印の先の長さ(画素)。
    public static func path(kind: FigureKind, w: Double, h: Double, corner: Double = 0, headLength: Double = 0) -> CGPath {
        let rect = CGRect(x: -w / 2, y: -h / 2, width: w, height: h)
        let path = CGMutablePath()
        switch kind {
        case .rect:
            let r = min(max(corner, 0), 0.5) * min(w, h)
            if r > 0 { path.addRoundedRect(in: rect, cornerWidth: r, cornerHeight: r) } else { path.addRect(rect) }
        case .ellipse:
            path.addEllipse(in: rect)
        case .line:
            path.move(to: CGPoint(x: -w / 2, y: -h / 2))
            path.addLine(to: CGPoint(x: w / 2, y: h / 2))
        case .arrow:
            let s = CGPoint(x: -w / 2, y: -h / 2), e = CGPoint(x: w / 2, y: h / 2)
            path.move(to: s)
            path.addLine(to: e)
            let len = hypot(e.x - s.x, e.y - s.y)
            if len > 0 {
                let ux = (e.x - s.x) / len, uy = (e.y - s.y) / len
                let hl = min(max(headLength, 0), len)
                let a = 30.0 * Double.pi / 180
                // 先の二本の辺: 終点から戻る向きを ±30 度回す
                for sign in [1.0, -1.0] {
                    let bx = -ux * cos(a) + sign * uy * sin(a)
                    let by = -uy * cos(a) - sign * ux * sin(a)
                    path.move(to: e)
                    path.addLine(to: CGPoint(x: e.x + bx * hl, y: e.y + by * hl))
                }
            }
        case .star:
            // 外周 5 点・内周 5 点を、箱の中の楕円に沿って交互に打つ(内側は外側の 0.45 倍)
            let rx = w / 2, ry = h / 2
            for k in 0..<10 {
                let outer = k % 2 == 0
                let ang = -Double.pi / 2 + Double(k) * Double.pi / 5
                let f = outer ? 1.0 : 0.45
                let p = CGPoint(x: rx * f * cos(ang), y: ry * f * sin(ang))
                if k == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            path.closeSubpath()
        }
        return path
    }
}

extension Clip {
    /// 図形の見た目(未設定は既定)。
    public var figureOrDefault: Figure { figure ?? Figure() }
}
