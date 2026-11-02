import Foundation
import CoreGraphics

/// 素材が見つからないクリップの表示(プレビューの代わりの札・タイムラインの赤い斜線)。画面に依存しない判断と配置。
public enum MissingMediaPlaceholder {
    public static let title = "メディアが見つかりません"
    public static let timelineHelp = "メディアが見つかりません。素材の場所を再指定してください(ファイル ▸ 素材の場所を再指定…)"
    /// 札の色(暗い赤)・縁・文字。
    public static let cardHex = "#5a1010"
    public static let borderHex = "#c43a3a"
    public static let textHex = "#ffffff"

    /// 札の配置(左上原点・ピクセル)。キャンバスの中央に置く。
    public struct Layout: Equatable {
        public var card: CGRect
        public var titleSize: Double
        public var nameSize: Double
        public var titleY: Double
        public var nameY: Double
        public var nameText: String
    }

    public static func layout(canvasWidth W: Double, canvasHeight H: Double, fileName: String, centerX: Double = 0.5, centerY: Double = 0.5) -> Layout {
        let cw = W * 0.62, ch = H * 0.34
        let cx = W * centerX, cy = H * centerY
        let card = CGRect(x: cx - cw / 2, y: cy - ch / 2, width: cw, height: ch)
        let titleSize = max(8, H * 0.055), nameSize = max(6, H * 0.04)
        return Layout(card: card, titleSize: titleSize, nameSize: nameSize,
                      titleY: cy - ch * 0.12, nameY: cy + ch * 0.2, nameText: shortName(fileName, limit: 32))
    }

    /// 長いファイル名は真ん中を省く(拡張子を残す)。
    public static func shortName(_ name: String, limit: Int) -> String {
        guard name.count > limit, limit > 4 else { return name }
        let head = (limit - 1) * 2 / 3, tail = limit - 1 - head
        return String(name.prefix(head)) + "…" + String(name.suffix(tail))
    }

    /// 札を描く(左上原点の ctx)。文字は呼び出し側が `drawText` で重ねる。
    public static func drawCard(_ l: Layout, in ctx: CGContext) {
        guard let fill = parseHexColor(cardHex), let border = parseHexColor(borderHex) else { return }
        ctx.saveGState()
        let r = min(l.card.width, l.card.height) * 0.06
        let path = CGPath(roundedRect: l.card, cornerWidth: r, cornerHeight: r, transform: nil)
        ctx.setFillColor(fill)
        ctx.addPath(path); ctx.fillPath()
        ctx.setStrokeColor(border)
        ctx.setLineWidth(max(2, l.card.height * 0.02))
        ctx.addPath(path); ctx.strokePath()
        ctx.restoreGState()
    }

    /// 素材が見つからないクリップか(`src` が空のものは数えない)。
    public static func isMissing(_ c: Clip, exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Bool {
        guard let src = c.src, !src.isEmpty else { return false }
        return !exists(src)
    }

    /// タイムラインのクリップの印。素材が無ければ赤い斜線と ⚠ とヘルプ文。細いクリップでは ⚠ を出さない。
    public struct TimelineMark: Equatable {
        public var hatch: Bool
        public var showsBadge: Bool
        public var help: String
    }

    public static func timelineMark(for c: Clip, width: Double, exists: (String) -> Bool) -> TimelineMark? {
        guard isMissing(c, exists: exists) else { return nil }
        return TimelineMark(hatch: width >= 2, showsBadge: width >= 22, help: timelineHelp)
    }
}
