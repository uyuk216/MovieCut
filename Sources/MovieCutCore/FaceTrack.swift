import Foundation
import CoreGraphics

// MARK: - 顔の追従(時間方向の平滑化と補間)

/// 顔ぼかしの「追従」。クリップの中の一定間隔(既定 0.5 秒)で顔を検出し、時刻ごとの顔の枠を作る。
/// 枠の座標はキャンバスの画素・左上原点。検出が無い時刻は `rect == nil`。純粋な計算だけ(検出器は呼び出し側が差し込む)。
public struct FaceTrackSample: Equatable, Sendable {
    /// クリップの頭からの秒
    public var time: Double
    /// 顔の枠(キャンバスの画素・左上原点)。無ければ nil
    public var rect: CGRect?

    public init(time: Double, rect: CGRect?) { self.time = time; self.rect = rect }
}

public enum FaceTrack {
    /// 検出の間隔(秒)
    public static let interval = 0.5
    /// この秒数より長く検出が無いときは、補間せずに何もぼかさない(別の人へ飛ぶのを防ぐ)
    public static let maxGap = 1.0
    /// 検出の上限(長いクリップで検出が増えすぎないように)
    public static let maxSamples = 600

    /// 0 から `duration` までの検出時刻(両端を含む)。`duration` が 0 以下なら [0]。
    public static func sampleTimes(duration: Double, interval: Double = interval) -> [Double] {
        guard duration.isFinite, duration > 0, interval > 0 else { return [0] }
        let n = min(maxSamples, Int((duration / interval).rounded(.up)))
        var out: [Double] = []
        for i in 0...n { out.append(min(duration, Double(i) * interval)) }
        // 重なり(末尾の同時刻)を除く
        var dedup: [Double] = []
        for t in out where dedup.last.map({ abs($0 - t) > 1e-9 }) ?? true { dedup.append(t) }
        return dedup
    }

    /// 検出された顔から 1 つを選ぶ。前回の枠と最も重なるものを優先し、重なりが無ければ一番大きい顔(初回・取り違え防止)。
    public static func choose(_ faces: [CGRect], previous: CGRect?) -> CGRect? {
        let valid = faces.filter { $0.width > 0 && $0.height > 0 && $0.minX.isFinite && $0.minY.isFinite }
        guard !valid.isEmpty else { return nil }
        if let p = previous {
            let overlapping = valid.map { ($0, iou($0, p)) }.filter { $0.1 > 0 }
            if let best = overlapping.max(by: { $0.1 < $1.1 }) { return best.0 }
        }
        return valid.max(by: { $0.width * $0.height < $1.width * $1.height })
    }

    /// 検出の列から追従の列を作る。顔を前回の枠で選び直し、その後で時間方向に 3 点移動平均で平滑化する(枠の揺れを抑える)。
    public static func build(detections: [(time: Double, faces: [CGRect])]) -> [FaceTrackSample] {
        var picked: [FaceTrackSample] = []
        var previous: CGRect? = nil
        for d in detections.sorted(by: { $0.time < $1.time }) {
            let r = choose(d.faces, previous: previous)
            if let r { previous = r }
            picked.append(FaceTrackSample(time: d.time, rect: r))
        }
        return smooth(picked)
    }

    /// 検出のある時刻だけを、近い検出との 3 点移動平均で平滑化する(検出の無い時刻は nil のまま)。
    public static func smooth(_ s: [FaceTrackSample]) -> [FaceTrackSample] {
        s.indices.map { i in
            guard let r = s[i].rect else { return s[i] }
            var acc = CGRect.zero, n: CGFloat = 0, w: CGFloat = 0
            for j in max(0, i - 1)...min(s.count - 1, i + 1) {
                guard let q = s[j].rect else { continue }
                let weight: CGFloat = j == i ? 2 : 1
                acc = CGRect(x: acc.minX + q.minX * weight, y: acc.minY + q.minY * weight,
                             width: acc.width + q.width * weight, height: acc.height + q.height * weight)
                n += 1; w += weight
            }
            guard n > 0, w > 0 else { return FaceTrackSample(time: s[i].time, rect: r) }
            let out = CGRect(x: acc.minX / w, y: acc.minY / w, width: acc.width / w, height: acc.height / w)
            return FaceTrackSample(time: s[i].time, rect: out)
        }
    }

    /// 時刻 `t` の顔の枠。前後の検出を線形に補間する。前後どちらかの検出まで `maxGap` 秒を超える、または検出が無いときは nil。
    public static func rect(at t: Double, in s: [FaceTrackSample]) -> CGRect? {
        guard !s.isEmpty, t.isFinite else { return nil }
        let withFace = s.filter { $0.rect != nil }
        guard !withFace.isEmpty else { return nil }
        // t 以前の最後の検出と、t 以降の最初の検出
        let before = withFace.last { $0.time <= t }
        let after = withFace.first { $0.time >= t }
        switch (before, after) {
        case let (b?, a?) where b.time == a.time:
            return b.rect
        case let (b?, a?):
            // 検出が 2 × maxGap 以内の間隔なら、線形に補間する。離れていれば近い方を maxGap 秒まで使う。
            if a.time - b.time <= 2 * maxGap, let p = b.rect, let q = a.rect {
                let k = CGFloat((t - b.time) / (a.time - b.time))
                return CGRect(x: p.minX + (q.minX - p.minX) * k, y: p.minY + (q.minY - p.minY) * k,
                              width: p.width + (q.width - p.width) * k, height: p.height + (q.height - p.height) * k)
            }
            if t - b.time <= maxGap { return b.rect }
            if a.time - t <= maxGap { return a.rect }
            return nil
        case let (b?, nil):
            return t - b.time <= maxGap ? b.rect : nil
        case let (nil, a?):
            return a.time - t <= maxGap ? a.rect : nil
        default:
            return nil
        }
    }

    /// 2 つの枠の重なり(intersection over union)。0〜1。
    public static func iou(_ a: CGRect, _ b: CGRect) -> Double {
        let inter = a.intersection(b)
        guard !inter.isNull, inter.width > 0, inter.height > 0 else { return 0 }
        let ia = Double(inter.width * inter.height)
        let u = Double(a.width * a.height + b.width * b.height) - ia
        return u > 0 ? ia / u : 0
    }
}
