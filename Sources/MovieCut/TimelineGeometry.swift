import Foundation
import CoreGraphics

/// タイムラインの寸法と時間↔座標の計算(描画から切り離して試せるようにした純粋な部分)。
/// style.css の .track(40pt)/ #ruler(22pt)/ .track-head(90pt)/ .clip(top 3, 高さ 34)と同じ値。
enum TimelineLayout {
    static let headerWidth: CGFloat = 90
    static let rulerHeight: CGFloat = 22
    static let rowHeight: CGFloat = 40
    static let clipTop: CGFloat = 3
    static let clipHeight: CGFloat = 34
    static let minClipWidth: CGFloat = 4

    static let minPps = 5.0
    static let maxPps = 400.0
    static let defaultPps = 40.0

    /// 目盛りの刻み候補(秒)。間隔が 70pt 以上になる最小のものを選ぶ。
    static let tickSteps: [Double] = [0.1, 0.2, 0.5, 1, 2, 5, 10, 30, 60]
    static let minTickSpacing = 70.0

    static func clampPps(_ v: Double) -> Double { min(maxPps, max(minPps, v)) }

    static func tickStep(pps: Double) -> Double {
        tickSteps.first { $0 * pps >= minTickSpacing - 1e-9 } ?? tickSteps[tickSteps.count - 1]
    }

    /// 全体の長さ(秒): プロジェクトの終わり + 10 秒、最低 30 秒。
    static func contentSeconds(projectEnd: Double) -> Double { max(projectEnd + 10, 30) }

    static func contentWidth(projectEnd: Double, pps: Double) -> CGFloat {
        CGFloat(contentSeconds(projectEnd: projectEnd) * pps)
    }

    /// 全体表示: max(10 秒, プロジェクトの終わり) を見える幅に収める拡大率。
    static func fitPps(visibleWidth: CGFloat, projectEnd: Double) -> Double {
        let secs = max(10, projectEnd)
        guard visibleWidth > 0 else { return defaultPps }
        return clampPps(Double(visibleWidth) / secs)
    }

    /// 目盛りのラベル。1 秒以上の刻みは "mm:ss"、それ未満は "mm:ss.f"。
    static func tickLabel(seconds s: Double, step: Double) -> String {
        if step >= 1 {
            let n = Int((s + 1e-6).rounded(.down))
            return String(format: "%02d:%02d", n / 60, n % 60)
        }
        let tenths = Int((s * 10).rounded())
        return String(format: "%02d:%02d.%d", tenths / 600, (tenths / 10) % 60, tenths % 10)
    }

    /// 行ヘッダー内の「隠す」「消音」ボタンの矩形(行の上端を 0 とした座標)。
    static func chipRects(rowTop: CGFloat) -> (hide: CGRect, mute: CGRect) {
        let y = rowTop + 21
        return (CGRect(x: 5, y: y, width: 38, height: 16), CGRect(x: 46, y: y, width: 38, height: 16))
    }
}

/// スクロール位置と拡大率から、座標を計算する。座標は左上原点(ヘッダー列とルーラーを含むビュー座標)。
struct TimelineGeometry: Equatable {
    var pps: Double = TimelineLayout.defaultPps
    var scrollX: CGFloat = 0
    var scrollY: CGFloat = 0

    func x(forTime t: Double) -> CGFloat { TimelineLayout.headerWidth + CGFloat(t * pps) - scrollX }
    func time(forX x: CGFloat) -> Double { Double(x - TimelineLayout.headerWidth + scrollX) / pps }

    func rowTop(_ index: Int) -> CGFloat { TimelineLayout.rulerHeight + CGFloat(index) * TimelineLayout.rowHeight - scrollY }

    /// y 座標が指す行(範囲外は nil)。
    func rowIndex(forY y: CGFloat, rowCount: Int) -> Int? {
        guard y >= TimelineLayout.rulerHeight else { return nil }
        let i = Int(((y - TimelineLayout.rulerHeight + scrollY) / TimelineLayout.rowHeight).rounded(.down))
        return (0..<rowCount).contains(i) ? i : nil
    }

    /// クリップの矩形。極端に短いクリップでも幅は 4pt 以上。
    func clipRect(start: Double, duration: Double, track: Int) -> CGRect {
        CGRect(x: x(forTime: start),
               y: rowTop(track) + TimelineLayout.clipTop,
               width: max(TimelineLayout.minClipWidth, CGFloat(duration * pps)),
               height: TimelineLayout.clipHeight)
    }

    static func maxScrollX(projectEnd: Double, pps: Double, viewWidth: CGFloat) -> CGFloat {
        max(0, TimelineLayout.contentWidth(projectEnd: projectEnd, pps: pps) - (viewWidth - TimelineLayout.headerWidth))
    }

    static func maxScrollY(rowCount: Int, viewHeight: CGFloat) -> CGFloat {
        max(0, CGFloat(rowCount) * TimelineLayout.rowHeight - (viewHeight - TimelineLayout.rulerHeight))
    }
}
