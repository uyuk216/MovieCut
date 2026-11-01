import Foundation
import CoreGraphics

// MARK: - 吹き出し(B-2): 文字クリップの任意項目

/// 文字クリップの後ろに描く吹き出し。形(丸角・雲・四角)・塗り・縁・尾(相手を指す三角)。
/// 項目は任意で、設定したクリップだけ `bubble` を書く(無いときは描かず、古いファイルは変わらない)。
/// 尾の先は、`tailChar` が無ければ正規化した点(`tailX`・`tailY`、キャンバス基準)。`tailChar` があれば、そのキャラの位置に
/// `tailDX`・`tailDY`(正規化)を足した点を指す。
public struct Bubble: Codable, Equatable, Sendable {
    public static let shapes = ["rounded", "cloud", "rect"]
    public static let defaultFill = "#ffffff"
    public static let defaultStroke = "#000000"

    /// 形: rounded(丸角)/ cloud(雲)/ rect(四角)。知らない値は rounded として扱う。
    public var shape: String = "rounded"
    public var fill: String = Bubble.defaultFill
    public var stroke: String = Bubble.defaultStroke
    /// 縁の太さ(キャンバスの px)。0 で縁なし。
    public var strokeWidth: Double = 4
    /// 尾を付けるか。
    public var tail: Bool = true
    /// 尾の先(正規化した点)。tailChar が無いときに使う。
    public var tailX: Double = 0.5
    public var tailY: Double = 0.92
    /// 尾の先を合わせるキャラの id。nil なら tailX・tailY の点。
    public var tailChar: String? = nil
    /// tailChar のときの、キャラの位置からのずれ(正規化)。既定は頭の少し上。
    public var tailDX: Double = 0
    public var tailDY: Double = -0.25

    public init() {}
    public init(shape: String = "rounded", fill: String = Bubble.defaultFill, stroke: String = Bubble.defaultStroke, strokeWidth: Double = 4,
                tail: Bool = true, tailX: Double = 0.5, tailY: Double = 0.92, tailChar: String? = nil, tailDX: Double = 0, tailDY: Double = -0.25) {
        self.shape = shape; self.fill = fill; self.stroke = stroke; self.strokeWidth = strokeWidth; self.tail = tail
        self.tailX = tailX; self.tailY = tailY; self.tailChar = tailChar; self.tailDX = tailDX; self.tailDY = tailDY
        self = normalized
    }

    public init(from decoder: Decoder) throws {
        let l = Lenient(c: try decoder.container(keyedBy: AnyKey.self), known: [])
        self.init(shape: l.string("shape") ?? "rounded", fill: l.string("fill") ?? Bubble.defaultFill,
                  stroke: l.string("stroke") ?? Bubble.defaultStroke, strokeWidth: l.double("strokeWidth") ?? 4,
                  tail: l.bool("tail") ?? true, tailX: l.double("tailX") ?? 0.5, tailY: l.double("tailY") ?? 0.92,
                  tailChar: l.string("tailChar"), tailDX: l.double("tailDX") ?? 0, tailDY: l.double("tailDY") ?? -0.25)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encode(shape, forKey: AnyKey("shape")); try c.encode(fill, forKey: AnyKey("fill")); try c.encode(stroke, forKey: AnyKey("stroke"))
        try c.encode(strokeWidth, forKey: AnyKey("strokeWidth")); try c.encode(tail, forKey: AnyKey("tail"))
        try c.encode(tailX, forKey: AnyKey("tailX")); try c.encode(tailY, forKey: AnyKey("tailY"))
        try c.encodeIfPresent(tailChar, forKey: AnyKey("tailChar"))
        try c.encode(tailDX, forKey: AnyKey("tailDX")); try c.encode(tailDY, forKey: AnyKey("tailDY"))
    }

    /// 範囲に収め、知らない形・壊れた色は既定に直す。
    public var normalized: Bubble {
        var b = self
        if !Bubble.shapes.contains(b.shape) { b.shape = "rounded" }
        if parseHexColor(b.fill) == nil { b.fill = Bubble.defaultFill }
        if parseHexColor(b.stroke) == nil { b.stroke = Bubble.defaultStroke }
        b.strokeWidth = min(60, max(0, b.strokeWidth))
        b.tailX = min(2, max(-1, b.tailX)); b.tailY = min(2, max(-1, b.tailY))
        b.tailDX = min(1, max(-1, b.tailDX)); b.tailDY = min(1, max(-1, b.tailDY))
        if let id = b.tailChar, id.isEmpty { b.tailChar = nil }
        return b
    }
}

// MARK: - 形の幾何(画面に依らない。テストで形と尾の位置を確かめる)

public enum BubbleGeometry {
    /// 本体の中心・大きさと、尾の先(キャンバスの px、尾を付けるときだけ)から、描く形の path(本体と尾の合体)を作る。
    /// 縁は呼ぶ側で「縁の色で 2 倍の太さに塗ってから、塗りで上書き」して外側だけを出す(重なった内側の線は消える)。
    public static func path(shape: String, center: CGPoint, size: CGSize, tail: CGPoint?) -> CGPath {
        let rect = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
        let path = CGMutablePath()
        switch shape {
        case "rect":
            path.addRect(rect)
        case "cloud":
            addCloud(to: path, rect: rect)
        default:
            let r = min(rect.width, rect.height) * 0.3
            path.addRoundedRect(in: rect, cornerWidth: r, cornerHeight: r)
        }
        if let t = tail { addTail(to: path, rect: rect, target: t) }
        return path
    }

    /// 雲: 内側の矩形と、その周りに並べた円の集まり。
    static func addCloud(to path: CGMutablePath, rect: CGRect) {
        let r = min(rect.width, rect.height) * 0.22
        guard r > 0 else { path.addRect(rect); return }
        let inner = rect.insetBy(dx: r, dy: r)
        if inner.width > 0, inner.height > 0 { path.addRect(inner) }
        let perimeter = 2 * (max(0, inner.width) + max(0, inner.height))
        let n = max(8, Int((perimeter / (r * 1.1)).rounded()))
        for i in 0..<n {
            let p = pointOnPerimeter(inner, fraction: Double(i) / Double(n))
            path.addEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
        }
    }

    /// 矩形の周上の点(時計回り、左上から。fraction 0〜1)。
    static func pointOnPerimeter(_ r: CGRect, fraction f: Double) -> CGPoint {
        let w = max(0, r.width), h = max(0, r.height)
        let total = 2 * (w + h)
        guard total > 0 else { return CGPoint(x: r.midX, y: r.midY) }
        var d = f * total
        if d < w { return CGPoint(x: r.minX + d, y: r.minY) }
        d -= w
        if d < h { return CGPoint(x: r.maxX, y: r.minY + d) }
        d -= h
        if d < w { return CGPoint(x: r.maxX - d, y: r.maxY) }
        d -= w
        return CGPoint(x: r.minX, y: r.maxY - d)
    }

    /// 尾: 本体の中心から見て、目標が向いている辺に三角を付ける。根元は本体の中へ少し入れて、つなぎ目を消す。
    static func addTail(to path: CGMutablePath, rect: CGRect, target t: CGPoint) {
        let cx = rect.midX, cy = rect.midY
        let hw = rect.width / 2, hh = rect.height / 2
        guard hw > 0, hh > 0 else { return }
        let dx = t.x - cx, dy = t.y - cy
        let inset: CGFloat = 2
        if abs(dx) / hw > abs(dy) / hh {
            // 左右の辺
            let edgeX = dx >= 0 ? rect.maxX - inset : rect.minX + inset
            let by = min(max(t.y, cy - rect.height * 0.3), cy + rect.height * 0.3)
            let spread = rect.height * 0.08
            path.move(to: CGPoint(x: edgeX, y: by - spread))
            path.addLine(to: t)
            path.addLine(to: CGPoint(x: edgeX, y: by + spread))
        } else {
            // 上下の辺
            let edgeY = dy >= 0 ? rect.maxY - inset : rect.minY + inset
            let bx = min(max(t.x, cx - rect.width * 0.3), cx + rect.width * 0.3)
            let spread = rect.width * 0.08
            path.move(to: CGPoint(x: bx - spread, y: edgeY))
            path.addLine(to: t)
            path.addLine(to: CGPoint(x: bx + spread, y: edgeY))
        }
        path.closeSubpath()
    }
}

// MARK: - 尾の先の決め方(キャラの位置を使う場合)

public enum BubbleTarget {
    /// キャンバスの px での尾の先。tailChar があり、そのキャラが無いときは点の指定に戻す。
    public static func point(_ b: Bubble, characters: [Character], width W: Double, height H: Double) -> CGPoint {
        if let id = b.tailChar, let ch = characters.first(where: { $0.id == id }) {
            return CGPoint(x: (ch.x + b.tailDX) * W, y: (ch.y + b.tailDY) * H)
        }
        return CGPoint(x: b.tailX * W, y: b.tailY * H)
    }
}
