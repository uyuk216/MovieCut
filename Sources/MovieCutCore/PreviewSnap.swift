import Foundation
import CoreGraphics

// MARK: - プレビューの直接操作のスナップ(吸着)
//
// ドラッグ中の枠(移動)や掴んだ角の点(拡縮)を、キャンバスの端・中心、他のクリップの枠、
// 表示中のガイド線へ吸着させる純粋な計算(UI にも UserDefaults にも依存しない)。
// 座標はすべてキャンバスの画素(左上原点)。閾値もキャンバスの画素で渡す
// (画面の pt からへの換算は表示側の仕事)。
// 枠の吸着点は回転を考えない軸平行の端・中心(TransformBox の center / width / height から作る)。
// 回転した枠でも中心はそのまま使えるが、端は回転前の位置で判定する割り切り。

public enum PreviewSnap {
    /// スナップ先の線の座標列(縦線は x、横線は y)。
    public struct Targets: Equatable, Sendable {
        public var verticals: [Double]
        public var horizontals: [Double]
        public init(verticals: [Double] = [], horizontals: [Double] = []) {
            self.verticals = verticals
            self.horizontals = horizontals
        }
        public var isEmpty: Bool { verticals.isEmpty && horizontals.isEmpty }
    }

    /// 移動の補正結果: 補正後の移動量と、吸着した線(吸着しなければ nil)。
    public struct MoveResult: Equatable, Sendable {
        public var delta: CGPoint
        public var verticalLine: Double?
        public var horizontalLine: Double?
        public init(delta: CGPoint, verticalLine: Double? = nil, horizontalLine: Double? = nil) {
            self.delta = delta; self.verticalLine = verticalLine; self.horizontalLine = horizontalLine
        }
        public var snapped: Bool { verticalLine != nil || horizontalLine != nil }
    }

    /// 点(拡縮で掴んだ角)の補正結果: 補正後の点と、吸着した線(吸着しなければ nil)。
    public struct PointResult: Equatable, Sendable {
        public var point: CGPoint
        public var verticalLine: Double?
        public var horizontalLine: Double?
        public init(point: CGPoint, verticalLine: Double? = nil, horizontalLine: Double? = nil) {
            self.point = point; self.verticalLine = verticalLine; self.horizontalLine = horizontalLine
        }
        public var snapped: Bool { verticalLine != nil || horizontalLine != nil }
    }

    // MARK: スナップ先の収集

    /// スナップ先を集める: キャンバスの端・中心は常に入り、表示中のガイド線(中心線・グリッド)と
    /// 他のクリップの枠(左端・中心・右端 / 上端・中心・下端)を足す。昇順・重複なしで返す。
    public static func targets(canvas: CGSize, guides: Set<PreviewGuide> = [], otherBoxes: [TransformBox] = []) -> Targets {
        guard canvas.width > 0, canvas.height > 0 else { return Targets() }
        var v: [Double] = [0, canvas.width / 2, canvas.width]
        var h: [Double] = [0, canvas.height / 2, canvas.height]
        v += GuideGeometry.verticalCoordinates(guides, canvas: canvas)
        h += GuideGeometry.horizontalCoordinates(guides, canvas: canvas)
        for b in otherBoxes {
            v += [b.center.x - b.width / 2, b.center.x, b.center.x + b.width / 2]
            h += [b.center.y - b.height / 2, b.center.y, b.center.y + b.height / 2]
        }
        return Targets(verticals: GuideGeometry.sortedUnique(v), horizontals: GuideGeometry.sortedUnique(h))
    }

    // MARK: 最寄りの線

    /// 値 `value` から閾値以内で最も近い候補と、そこへ寄せる補正量。無ければ nil。
    /// 同じ近さの候補が複数あれば、座標の小さいほうを優先する(決定的にするため)。
    public static func nearest(value: Double, candidates: [Double], threshold: Double) -> (line: Double, correction: Double)? {
        guard value.isFinite else { return nil }
        let limit = max(0, threshold)
        var best: (line: Double, correction: Double)?
        for c in candidates where c.isFinite {
            let correction = c - value
            guard abs(correction) <= limit else { continue }
            if let b = best {
                if abs(correction) > abs(b.correction) { continue }
                if abs(correction) == abs(b.correction), c >= b.line { continue }
            }
            best = (c, correction)
        }
        return best
    }

    // MARK: 移動のスナップ

    /// 枠 `box` を移動量 `delta` で動かすときの吸着。枠の左端・中心・右端(と上端・中心・下端)を
    /// それぞれ線と比べ、軸ごとに最も近い 1 件だけ補正する(補正は移動量へ足す形で返す)。
    public static func snapMove(box: TransformBox, delta: CGPoint, targets: Targets, threshold: Double) -> MoveResult {
        guard delta.x.isFinite, delta.y.isFinite else { return MoveResult(delta: delta) }
        var out = MoveResult(delta: delta)
        let anchorsX = [box.center.x - box.width / 2, box.center.x, box.center.x + box.width / 2]
        if let hit = nearestAnchor(anchors: anchorsX, offset: delta.x, candidates: targets.verticals, threshold: threshold) {
            out.delta.x += hit.correction
            out.verticalLine = hit.line
        }
        let anchorsY = [box.center.y - box.height / 2, box.center.y, box.center.y + box.height / 2]
        if let hit = nearestAnchor(anchors: anchorsY, offset: delta.y, candidates: targets.horizontals, threshold: threshold) {
            out.delta.y += hit.correction
            out.horizontalLine = hit.line
        }
        return out
    }

    /// 点(拡縮で掴んだ角など)の吸着。軸ごとに最も近い線へ寄せる。
    public static func snapPoint(_ point: CGPoint, targets: Targets, threshold: Double) -> PointResult {
        guard point.x.isFinite, point.y.isFinite else { return PointResult(point: point) }
        var out = PointResult(point: point)
        if let hit = nearest(value: point.x, candidates: targets.verticals, threshold: threshold) {
            out.point.x += hit.correction
            out.verticalLine = hit.line
        }
        if let hit = nearest(value: point.y, candidates: targets.horizontals, threshold: threshold) {
            out.point.y += hit.correction
            out.horizontalLine = hit.line
        }
        return out
    }

    /// 複数の吸着点(端・中心)のうち、移動後に線へ最も近くなる組み合わせの補正。
    /// 同じ近さなら、先に挙げた吸着点(端→中心の順)を優先する。
    private static func nearestAnchor(anchors: [Double], offset: Double, candidates: [Double], threshold: Double) -> (line: Double, correction: Double)? {
        var best: (line: Double, correction: Double)?
        for a in anchors {
            guard let hit = nearest(value: a + offset, candidates: candidates, threshold: threshold) else { continue }
            if let b = best, abs(hit.correction) >= abs(b.correction) { continue }
            best = hit
        }
        return best
    }
}
