import Foundation
import MovieCutCore

/// 速度ランプ・フレームブレンド(インスペクタが呼ぶ)。計算は MovieCutCore の SpeedEditing / SpeedRamp に任せ、
/// ここは Undo(1 操作 = 1 回)と選択だけ。何も変わらない操作は Undo に積まない(`changeSpeedRamp` の変化なし判定)。
extension ProjectModel {
    static let rampUndoName = "速度ランプの変更"

    /// 速度ランプを変える(1 回の Undo)。`make` は今のクリップを受けて新しい点(nil で外す)を返す。変わらなければ何もしない。
    @discardableResult
    func changeSpeedRamp(clipId: String, name: String, _ make: (Clip) -> [SpeedKey]?) -> Bool {
        guard !isLocked, let c = clip(clipId), SpeedEditing.supports(c) else { return false }
        var probe = c
        guard SpeedEditing.setRamp(&probe, make(c)) else { return false }
        setClipProperty({ _ = SpeedEditing.setRamp(&$0, make($0)) }, name: name, clipId: c.id)
        return true
    }

    /// 速度ランプを作る: いまの速度のまま、頭と終わりに点を置く(形は変わらない)。
    @discardableResult
    func makeSpeedRamp(clipId: String) -> Bool {
        changeSpeedRamp(clipId: clipId, name: Self.rampUndoName) { c in
            let s = c.effectiveSpeed
            return [SpeedKey(t: 0, v: s), SpeedKey(t: c.duration, v: s)]
        }
    }

    /// 速度ランプをやめる(いまの平均の速さの一定速度になる)。
    @discardableResult
    func clearSpeedRamp(clipId: String) -> Bool {
        changeSpeedRamp(clipId: clipId, name: Self.rampUndoName) { _ in nil }
    }

    /// 点の時刻(t)か速度(v)のどちらかを直す。
    @discardableResult
    func setSpeedRampPoint(clipId: String, index: Int, t: Double? = nil, v: Double? = nil) -> Bool {
        changeSpeedRamp(clipId: clipId, name: Self.rampUndoName) { c in
            guard var pts = c.rampPoints, pts.indices.contains(index) else { return c.rampPoints }
            if let t { pts[index].t = t }
            if let v { pts[index].v = v }
            return pts
        }
    }

    /// 点を足す(その時刻の速度は、いまの曲線の上の値)。
    @discardableResult
    func addSpeedRampPoint(clipId: String, at t: Double) -> Bool {
        changeSpeedRamp(clipId: clipId, name: Self.rampUndoName) { c in
            var pts = c.rampPoints ?? []
            pts.append(SpeedKey(t: t, v: SpeedRamp.speed(pts, at: t)))
            return pts
        }
    }

    /// 点を消す(2 点は残す)。
    @discardableResult
    func removeSpeedRampPoint(clipId: String, index: Int) -> Bool {
        changeSpeedRamp(clipId: clipId, name: Self.rampUndoName) { c in
            guard var pts = c.rampPoints, pts.count > 2, pts.indices.contains(index) else { return c.rampPoints }
            pts.remove(at: index)
            return pts
        }
    }

    /// フレームブレンドの on/off(動画だけ。1 回の Undo)。
    @discardableResult
    func setFrameBlend(_ on: Bool, clipId: String) -> Bool {
        guard !isLocked, let c = clip(clipId), c.type == .video, !c.isFreeze, (c.frameBlend == true) != on else { return false }
        setClipProperty({ $0.frameBlend = on ? true : nil }, name: "フレームブレンド", clipId: c.id)
        return true
    }
}
