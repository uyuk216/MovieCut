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
    /// 三分割線(縦横 2 本ずつ)。
    case thirds

    /// UserDefaults のキー。
    public static let defaultsKey = "previewGuides.v1"

    public var title: String {
        switch self {
        case .titleSafe: return "タイトルセーフ（90%）"
        case .actionSafe: return "アクションセーフ（95%）"
        case .center: return "中心線"
        case .thirds: return "三分割線"
        }
    }

    /// 保存された値(raw 値の配列)から復元する。未知の値は捨てる。無い・壊れていれば何も出さない。
    public static func resolve(_ stored: [String]?) -> Set<PreviewGuide> {
        Set((stored ?? []).compactMap { PreviewGuide(rawValue: $0) })
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

    /// 中心線と三分割線。
    public static func lines(_ guides: Set<PreviewGuide>, canvas: CGSize) -> [Line] {
        var out: [Line] = []
        let w = canvas.width, h = canvas.height
        if guides.contains(.center) {
            out.append(Line(from: CGPoint(x: w / 2, y: 0), to: CGPoint(x: w / 2, y: h)))
            out.append(Line(from: CGPoint(x: 0, y: h / 2), to: CGPoint(x: w, y: h / 2)))
        }
        if guides.contains(.thirds) {
            for k in 1...2 {
                let x = w * Double(k) / 3, y = h * Double(k) / 3
                out.append(Line(from: CGPoint(x: x, y: 0), to: CGPoint(x: x, y: h)))
                out.append(Line(from: CGPoint(x: 0, y: y), to: CGPoint(x: w, y: y)))
            }
        }
        return out
    }
}
