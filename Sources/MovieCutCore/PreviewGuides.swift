import Foundation
import CoreGraphics

// MARK: - プレビューのガイド線(表示 ▸ ガイド線)
//
// プレビューの上に重ねるだけ。書き出し・プロジェクト・画面の外の描画には入らない。
// 設定はアプリ全体(UserDefaults)。既定は何も出さない。

public enum PreviewGuide: String, CaseIterable, Sendable {
    /// タイトルセーフ: 四辺から 5%(残りは 90%)。
    case titleSafe
    /// アクションセーフ: 四辺から 2.5%(残りは 95%)。
    case actionSafe
    /// 中心の十字線。
    case center
    /// 4 分割線(2×2)。グリッド系は排他(同時に 1 種類だけ)。
    case grid2
    /// 三分割線(3×3)。グリッド系は排他(同時に 1 種類だけ)。
    case thirds
    /// 16 分割線(4×4)。グリッド系は排他(同時に 1 種類だけ)。
    case grid4

    /// UserDefaults のキー。
    public static let defaultsKey = "previewGuides.v1"

    public var title: String {
        switch self {
        case .titleSafe: return "タイトルセーフ（90%）"
        case .actionSafe: return "アクションセーフ（95%）"
        case .center: return "中心線"
        case .grid2: return "4分割線（2×2）"
        case .thirds: return "三分割線"
        case .grid4: return "16分割線（4×4）"
        }
    }

    /// 分割グリッドの分割数(グリッド系でないものは nil)。
    public var gridDivisions: Int? {
        switch self {
        case .grid2: return 2
        case .thirds: return 3
        case .grid4: return 4
        case .titleSafe, .actionSafe, .center: return nil
        }
    }

    /// 分割グリッドかどうか(2×2・3×3・4×4 は互いに排他)。
    public var isGrid: Bool { gridDivisions != nil }

    /// グリッド系の一覧(allCases の順)。
    public static var gridCases: [PreviewGuide] { allCases.filter(\.isGrid) }

    /// 1 つ切り替えたあとの集合。グリッド系を ON にすると、他のグリッド系は外れる(排他)。
    /// タイトルセーフ・アクションセーフ・中心線はグリッドと独立に切り替わる。
    public static func toggled(_ set: Set<PreviewGuide>, _ g: PreviewGuide) -> Set<PreviewGuide> {
        var s = set
        if s.contains(g) {
            s.remove(g)
        } else {
            if g.isGrid { s.subtract(Self.gridCases) }
            s.insert(g)
        }
        return s
    }

    /// 保存された値(raw 値の配列)から復元する。未知の値は捨てる。無い・壊れていれば何も出さない。
    /// グリッド系が複数入っていたら、後ろのものを優先して 1 種類だけ残す(排他の解決)。
    public static func resolve(_ stored: [String]?) -> Set<PreviewGuide> {
        var out: Set<PreviewGuide> = []
        for raw in stored ?? [] {
            guard let g = PreviewGuide(rawValue: raw) else { continue }
            if g.isGrid { out.subtract(Self.gridCases) }
            out.insert(g)
        }
        return out
    }

    /// 表示フラグを通した「実際に使う」集合。表示 OFF なら空集合(何も出さない・スナップ先にも足さない)。
    /// 描画(redrawGuides)とスナップ先の収集(collectSnapTargets)の両方がこれを通す。
    public static func effective(_ set: Set<PreviewGuide>, visible: Bool) -> Set<PreviewGuide> {
        visible ? set : []
    }

    /// 保存する形(並びは allCases の順で固定)。
    public static func encode(_ set: Set<PreviewGuide>) -> [String] {
        allCases.filter { set.contains($0) }.map(\.rawValue)
    }
}

/// ガイドの幾何(キャンバスの画素、左上原点)。表示側はこれをビューの座標に直して描く。
public enum GuideGeometry {
    public struct Line: Equatable, Sendable {
        public var from: CGPoint
        public var to: CGPoint
        public init(from: CGPoint, to: CGPoint) { self.from = from; self.to = to }
    }

    /// 安全領域の枠(タイトル・アクション)。
    public static func safeRects(_ guides: Set<PreviewGuide>, canvas: CGSize) -> [CGRect] {
        var out: [CGRect] = []
        for (g, inset) in [(PreviewGuide.titleSafe, 0.05), (PreviewGuide.actionSafe, 0.025)] where guides.contains(g) {
            out.append(CGRect(x: canvas.width * inset, y: canvas.height * inset,
                              width: canvas.width * (1 - 2 * inset), height: canvas.height * (1 - 2 * inset)))
        }
        return out
    }

    /// `divisions` 等分の分割線(縦・横とも内側の divisions−1 本ずつ、縦→横の交互)。
    public static func divisionLines(divisions: Int, canvas: CGSize) -> [Line] {
        guard divisions >= 2 else { return [] }
        let w = canvas.width, h = canvas.height
        var out: [Line] = []
        for k in 1..<divisions {
            let x = w * Double(k) / Double(divisions), y = h * Double(k) / Double(divisions)
            out.append(Line(from: CGPoint(x: x, y: 0), to: CGPoint(x: x, y: h)))
            out.append(Line(from: CGPoint(x: 0, y: y), to: CGPoint(x: w, y: y)))
        }
        return out
    }

    /// 中心線と分割グリッド線。
    public static func lines(_ guides: Set<PreviewGuide>, canvas: CGSize) -> [Line] {
        var out: [Line] = []
        let w = canvas.width, h = canvas.height
        if guides.contains(.center) {
            out.append(Line(from: CGPoint(x: w / 2, y: 0), to: CGPoint(x: w / 2, y: h)))
            out.append(Line(from: CGPoint(x: 0, y: h / 2), to: CGPoint(x: w, y: h / 2)))
        }
        out += gridLines(guides, canvas: canvas)
        return out
    }

    /// 分割グリッド線だけ(表示側で点線に分けるため)。
    public static func gridLines(_ guides: Set<PreviewGuide>, canvas: CGSize) -> [Line] {
        var out: [Line] = []
        for g in PreviewGuide.gridCases where guides.contains(g) {
            if let d = g.gridDivisions { out += divisionLines(divisions: d, canvas: canvas) }
        }
        return out
    }

    /// スナップ先に使える縦線の x 座標(中心線・表示中のグリッド線)。昇順・重複なし。
    public static func verticalCoordinates(_ guides: Set<PreviewGuide>, canvas: CGSize) -> [Double] {
        var xs: [Double] = []
        if guides.contains(.center) { xs.append(canvas.width / 2) }
        for g in PreviewGuide.gridCases where guides.contains(g) {
            guard let d = g.gridDivisions else { continue }
            for k in 1..<d { xs.append(canvas.width * Double(k) / Double(d)) }
        }
        return sortedUnique(xs)
    }

    /// スナップ先に使える横線の y 座標(中心線・表示中のグリッド線)。昇順・重複なし。
    public static func horizontalCoordinates(_ guides: Set<PreviewGuide>, canvas: CGSize) -> [Double] {
        var ys: [Double] = []
        if guides.contains(.center) { ys.append(canvas.height / 2) }
        for g in PreviewGuide.gridCases where guides.contains(g) {
            guard let d = g.gridDivisions else { continue }
            for k in 1..<d { ys.append(canvas.height * Double(k) / Double(d)) }
        }
        return sortedUnique(ys)
    }

    /// 昇順に並べ、ほぼ同じ値(1e-9 以内)は 1 つにまとめる。
    static func sortedUnique(_ values: [Double]) -> [Double] {
        var out: [Double] = []
        for v in values.filter({ $0.isFinite }).sorted() {
            if let last = out.last, abs(v - last) <= 1e-9 { continue }
            out.append(v)
        }
        return out
    }
}
