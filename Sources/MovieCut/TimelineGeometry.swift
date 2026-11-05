import Foundation
import CoreGraphics
import MovieCutCore

/// タイムラインの寸法と時間↔座標の計算(描画から切り離して試せるようにした純粋な部分)。
/// style.css の .track(40pt)/ #ruler(22pt)/ .track-head(90pt)/ .clip(top 3, 高さ 34)と同じ値。
enum TimelineLayout {
    static let headerWidth: CGFloat = 112
    static let rulerHeight: CGFloat = 22
    static let rowHeight: CGFloat = 40
    static let clipTop: CGFloat = 3
    static let clipHeight: CGFloat = 34
    /// 行の高さに対するクリップの高さ(上 3pt・下 3pt の余白)。標準の行(40pt)で 34pt。
    static func clipHeight(forRow h: CGFloat) -> CGFloat { h - 2 * clipTop }
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

    /// 選択の長さ `span` 秒が、見える幅 `visibleWidth` の 9 割に収まる拡大率(範囲内に収める)。
    static func zoomPps(visibleWidth: CGFloat, span: Double) -> Double {
        guard visibleWidth > 0, span.isFinite, span > 0 else { return defaultPps }
        return clampPps(Double(visibleWidth) * 0.9 / span)
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

    /// 行ヘッダー内の「隠す」「消音」ボタンの矩形(`rowTop` は行の上端の y。ボタンは行の下寄せ)。
    static func chipRects(rowTop: CGFloat, rowHeight h: CGFloat = rowHeight) -> (hide: CGRect, mute: CGRect) {
        let y = rowTop + h - 19
        return (CGRect(x: 5, y: y, width: 38, height: 16), CGRect(x: 46, y: y, width: 38, height: 16))
    }

    /// 行ヘッダーのロックとソロのボタン(名前の行の右端)。
    static func lockRect(rowTop: CGFloat) -> CGRect { CGRect(x: headerWidth - 39, y: rowTop + 2, width: 17, height: 17) }
    /// 行ヘッダーのトラックターゲットの印(ロックの左)。
    static func targetRect(rowTop: CGFloat) -> CGRect { CGRect(x: headerWidth - 57, y: rowTop + 2, width: 17, height: 17) }
    static func soloRect(rowTop: CGFloat) -> CGRect { CGRect(x: headerWidth - 21, y: rowTop + 2, width: 17, height: 17) }
    /// 行ヘッダーの右下の × (レイヤーを削除)。チップの行に置く(隠す・消音の右)。
    static func deleteRect(rowTop: CGFloat, rowHeight h: CGFloat = rowHeight) -> CGRect { CGRect(x: headerWidth - 22, y: rowTop + h - 19, width: 16, height: 16) }
}

/// スクロール位置と拡大率から、座標を計算する。座標は左上原点(ヘッダー列とルーラーを含むビュー座標)。
struct TimelineGeometry: Equatable {
    var pps: Double = TimelineLayout.defaultPps
    var scrollX: CGFloat = 0
    var scrollY: CGFloat = 0
    /// 各行の上端の位置(行の高さの累積。個数は行数 + 1)。空なら全部の行が標準の高さ。
    var rowOffsets: [CGFloat] = []

    /// 行ごとの高さを設定する(レイヤーの高さ)。
    mutating func setRowHeights(_ heights: [CGFloat]) {
        if heights.allSatisfy({ $0 == TimelineLayout.rowHeight }) { rowOffsets = []; return }
        var acc: [CGFloat] = [0]
        for h in heights { acc.append(acc[acc.count - 1] + h) }
        rowOffsets = acc
    }

    /// 行 i のコンテンツ内の上端(スクロール前)。範囲外は標準の高さで続ける。
    func rowOffset(_ i: Int) -> CGFloat {
        if rowOffsets.isEmpty { return CGFloat(i) * TimelineLayout.rowHeight }
        if i < 0 { return CGFloat(i) * TimelineLayout.rowHeight }
        if i < rowOffsets.count { return rowOffsets[i] }
        return rowOffsets[rowOffsets.count - 1] + CGFloat(i - (rowOffsets.count - 1)) * TimelineLayout.rowHeight
    }

    func rowHeight(_ i: Int) -> CGFloat { rowOffset(i + 1) - rowOffset(i) }

    /// 行 `count` 本ぶんの高さの合計。
    func totalRowsHeight(rowCount: Int) -> CGFloat { rowOffset(rowCount) }

    func maxScrollY(rowCount: Int, viewHeight: CGFloat) -> CGFloat {
        max(0, totalRowsHeight(rowCount: rowCount) - (viewHeight - TimelineLayout.rulerHeight))
    }

    func x(forTime t: Double) -> CGFloat { TimelineLayout.headerWidth + CGFloat(t * pps) - scrollX }
    func time(forX x: CGFloat) -> Double { Double(x - TimelineLayout.headerWidth + scrollX) / pps }

    func rowTop(_ index: Int) -> CGFloat { TimelineLayout.rulerHeight + rowOffset(index) - scrollY }

    /// y 座標が指す行(範囲外は nil)。
    func rowIndex(forY y: CGFloat, rowCount: Int) -> Int? {
        guard y >= TimelineLayout.rulerHeight else { return nil }
        let cy = y - TimelineLayout.rulerHeight + scrollY
        guard cy >= 0 else { return nil }
        if rowOffsets.isEmpty {
            let i = Int((cy / TimelineLayout.rowHeight).rounded(.down))
            return (0..<rowCount).contains(i) ? i : nil
        }
        for i in 0..<min(rowCount, rowOffsets.count - 1) where cy < rowOffsets[i + 1] { return i }
        return nil
    }

    /// クリップの矩形。極端に短いクリップでも幅は 4pt 以上。
    func clipRect(start: Double, duration: Double, track: Int) -> CGRect {
        CGRect(x: x(forTime: start),
               y: rowTop(track) + TimelineLayout.clipTop,
               width: max(TimelineLayout.minClipWidth, CGFloat(duration * pps)),
               height: TimelineLayout.clipHeight(forRow: rowHeight(track)))
    }

    static func maxScrollX(projectEnd: Double, pps: Double, viewWidth: CGFloat) -> CGFloat {
        max(0, TimelineLayout.contentWidth(projectEnd: projectEnd, pps: pps) - (viewWidth - TimelineLayout.headerWidth))
    }

    static func maxScrollY(rowCount: Int, viewHeight: CGFloat) -> CGFloat {
        max(0, CGFloat(rowCount) * TimelineLayout.rowHeight - (viewHeight - TimelineLayout.rulerHeight))
    }
}

/// クリップ上のマウス操作の判定(描画から切り離した純粋な規則)。
enum TimelineHit {
    /// ダブルクリックで、プロパティ欄の文字入力へ移るクリップか(文字・セリフ)。
    static func editsTextOnDoubleClick(_ type: ClipType) -> Bool { type == .text || type == .voice }

    /// 押した位置が端(トリム)か中身(移動)か。端の幅は `zone` と幅の 1/3 の小さいほう。
    enum Zone: Equatable { case left, right, body }
    static func zone(x: CGFloat, minX: CGFloat, maxX: CGFloat, edgeZone: CGFloat) -> Zone {
        let z = min(edgeZone, (maxX - minX) / 3)
        if x - minX < z { return .left }
        if maxX - x < z { return .right }
        return .body
    }
}
