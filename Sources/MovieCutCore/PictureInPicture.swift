import Foundation

/// ピクチャー・イン・ピクチャーの配置プリセット(クリップ ▸ 配置 ▸ 右上に小さく など)。
/// 既存の変形(x・y・拡大)だけを書く。拡大は 0.3(フィットの 30%)、端からの余白はキャンバスの 3%。
public enum PipCorner: String, CaseIterable, Sendable {
    case topRight, bottomRight, topLeft, bottomLeft

    public var label: String {
        switch self {
        case .topRight: return "右上に小さく"
        case .bottomRight: return "右下に小さく"
        case .topLeft: return "左上に小さく"
        case .bottomLeft: return "左下に小さく"
        }
    }
}

public enum PictureInPicture {
    /// 小さくするときの拡大(フィットに対して)。
    public static let scale = 0.3
    /// 端からの余白(キャンバスに対する割合)。
    public static let margin = 0.03

    /// 位置と拡大。x・y はキャンバス比の中心(0〜1、y は下向き)。
    public struct Pose: Equatable, Sendable {
        public var x: Double
        public var y: Double
        public var scale: Double
    }

    /// 角に小さく置いたときの位置。素材の縦横比 `sourceAspect` とキャンバスの縦横比 `canvasAspect` から、
    /// 拡大 0.3 のときの見た目の幅・高さ(キャンバス比)を求めて、余白を空けて角に寄せる。
    /// 既定の 16:9 どうしなら、幅も高さも 0.3 の 1/2 ずつを中心から離す。
    public static func pose(corner: PipCorner, sourceAspect: Double = 16.0 / 9, canvasAspect: Double = 16.0 / 9) -> Pose {
        let a = sourceAspect > 0 ? sourceAspect : 16.0 / 9
        let A = canvasAspect > 0 ? canvasAspect : 16.0 / 9
        // 高さ 1 のキャンバス単位で、フィット(拡大 1)は min(A / a, 1) × 高さ。
        let k = min(A / a, 1) * scale
        let halfH = k / 2
        let halfW = k * a / A / 2
        let x = corner == .topLeft || corner == .bottomLeft ? margin + halfW : 1 - margin - halfW
        let y = corner == .topLeft || corner == .topRight ? margin + halfH : 1 - margin - halfH
        return Pose(x: x, y: y, scale: scale)
    }

    /// 映像に見える素材(画像・動画・文字)だけ。音声や ぼかし範囲には使わない。
    public static func supports(_ type: ClipType) -> Bool {
        type == .image || type == .video || type == .text
    }

    /// クリップの位置と拡大を書く。変わらないときは false。キーフレームはそのまま(キーがあれば描画ではキーが優先される)。
    /// 既定値(中心・等倍)に戻る場合は項目を書かない(任意項目の規則)。
    @discardableResult
    public static func apply(_ c: inout Clip, corner: PipCorner, sourceAspect: Double = 16.0 / 9, canvasAspect: Double = 16.0 / 9) -> Bool {
        guard supports(c.type) else { return false }
        let p = pose(corner: corner, sourceAspect: sourceAspect, canvasAspect: canvasAspect)
        let before = (c.x, c.y, c.scale)
        c.x = p.x == 0.5 ? nil : p.x
        c.y = p.y == 0.5 ? nil : p.y
        c.scale = p.scale == 1 ? nil : p.scale
        return before != (c.x, c.y, c.scale)
    }
}
