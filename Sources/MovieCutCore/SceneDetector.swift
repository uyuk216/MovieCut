import Foundation
import CoreGraphics
import AVFoundation

// MARK: - シーン境界の検出(カット点で分割)
//
// 映像を小さく(16×16)潰して前後のコマとの色の差を測り、大きく変わった所をカット点とみなす。
// ハードカット(画面が一瞬で切り替わる)はよく拾えるが、ディゾルブなどの緩やかな切り替えや
// 少しずつ変わる映像は差が分散して拾いにくい。サンプリング間隔より細かい精度も出ない。

/// シーン検出の設定。
public struct SceneParams: Equatable, Sendable {
    public static let thresholdRange: ClosedRange<Double> = 0.05 ... 0.95
    public static let intervalRange: ClosedRange<Double> = 0.1 ... 2
    public static let minSceneRange: ClosedRange<Double> = 0.1 ... 10
    public static let `default` = SceneParams()

    /// これ以上コマが変わったらシーンの切り替わりとみなす(0 = 同じ、1 = まったく違う)。
    public var threshold: Double
    /// 何秒おきにコマを比べるか(小さいほど細かく拾えるが遅い)。
    public var sampleInterval: Double
    /// これより短いシーンは作らない(秒)。近いカット点は強い方を残す。
    public var minScene: Double

    public init(threshold: Double = 0.35, sampleInterval: Double = 0.25, minScene: Double = 0.5) {
        self.threshold = threshold; self.sampleInterval = sampleInterval; self.minScene = minScene
    }

    /// 範囲に収めた値。
    public var clamped: SceneParams {
        func c(_ v: Double, _ r: ClosedRange<Double>, _ d: Double) -> Double { v.isFinite ? min(max(v, r.lowerBound), r.upperBound) : d }
        return SceneParams(threshold: c(threshold, Self.thresholdRange, 0.35),
                           sampleInterval: c(sampleInterval, Self.intervalRange, 0.25),
                           minScene: c(minScene, Self.minSceneRange, 0.5))
    }
}

/// 測った結果: サンプルの時刻と、直前のサンプルとの差。一度測れば、しきい値を動かしても作り直さずにカット点を求められる。
public struct SceneProfile: Equatable, Sendable {
    /// サンプルの時刻(クリップの頭から。昇順)。
    public var times: [Double]
    /// `diffs[i]` は `times[i]` → `times[i + 1]` の差(0...1)。`times.count - 1` 件。
    public var diffs: [Double]
    /// 測った長さ(クリップの長さ、秒)。
    public var duration: Double

    public init(times: [Double], diffs: [Double], duration: Double) {
        self.times = times; self.diffs = diffs; self.duration = duration
    }

    /// カット点(クリップの頭からの時刻、昇順)。しきい値以上の差のうち、
    /// 強いものから順に「前後・両端から `minScene` 以上離れている」ものだけ残す。
    public func cutPoints(_ params: SceneParams) -> [Double] {
        let p = params.clamped
        var cand: [(time: Double, diff: Double)] = []
        for i in diffs.indices where diffs[i] >= p.threshold && i + 1 < times.count {
            cand.append((times[i + 1], diffs[i]))
        }
        cand.sort { $0.diff != $1.diff ? $0.diff > $1.diff : $0.time < $1.time }
        var kept: [Double] = []
        for c in cand {
            guard c.time >= p.minScene - 1e-9, duration - c.time >= p.minScene - 1e-9 else { continue }
            guard kept.allSatisfy({ abs($0 - c.time) >= p.minScene - 1e-9 }) else { continue }
            kept.append(c.time)
        }
        return kept.sorted()
    }
}

public enum SceneDetector {
    /// 比較用の縮小サイズ(片辺)。
    public static let signatureSize = 16

    /// コマの「指紋」: 16×16 に潰した RGB(0...1)。同じ映像なら同じ値になる。
    public static func signature(of image: CGImage) -> [Double] {
        let n = signatureSize
        var px = [UInt8](repeating: 0, count: n * n * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &px, width: n, height: n, bitsPerComponent: 8,
                                  bytesPerRow: n * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: Double(n), height: Double(n)))
        var out: [Double] = []
        out.reserveCapacity(n * n * 3)
        for i in 0 ..< (n * n) {
            out.append(Double(px[i * 4]) / 255)
            out.append(Double(px[i * 4 + 1]) / 255)
            out.append(Double(px[i * 4 + 2]) / 255)
        }
        return out
    }

    /// 2 つの指紋の差(各要素の絶対差の平均。0 = 同じ、1 = 正反対)。
    public static func difference(_ a: [Double], _ b: [Double]) -> Double {
        guard !a.isEmpty, a.count == b.count else { return 0 }
        var s = 0.0
        for i in a.indices { s += abs(a[i] - b[i]) }
        return s / Double(a.count)
    }

    /// シーン分割できるクリップか: 動画で、速度・逆再生・フリーズ・速度ランプが無い
    /// (素材の時間とタイムラインの時間が 1 対 1 でないと、カット点を素材の時刻に置けない)。
    public static func supports(_ c: Clip) -> Bool {
        c.type == .video && (c.src?.isEmpty == false) && c.duration > 0
            && (c.speed == nil || abs((c.speed ?? 1) - 1) < 1e-9)
            && c.reverse != true && c.freeze != true && (c.speedRamp?.isEmpty ?? true)
    }

    /// クリップの範囲をサンプリングして、コマの差の変化を測る。読めなければ nil。
    public static func analyze(clip c: Clip, interval: Double = SceneParams.default.sampleInterval) -> SceneProfile? {
        guard supports(c), let src = c.src, !src.isEmpty else { return nil }
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: src)))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 320, height: 320)
        let tol = CMTime(value: 1, timescale: 30)
        gen.requestedTimeToleranceBefore = tol
        gen.requestedTimeToleranceAfter = tol
        let step = max(0.05, interval)
        var times: [Double] = []
        var diffs: [Double] = []
        var prev: [Double]?
        var t = 0.0
        while t < c.duration - 1e-9 {
            let img = try? gen.copyCGImage(at: CMTime(seconds: c.offset + t, preferredTimescale: 600), actualTime: nil)
            if let img {
                let sig = signature(of: img)
                if let p = prev { diffs.append(difference(p, sig)) }
                prev = sig
                times.append(t)
            }
            t += step
        }
        guard times.count >= 2, diffs.count == times.count - 1 else { return nil }
        return SceneProfile(times: times, diffs: diffs, duration: c.duration)
    }

    /// カット点(クリップの頭からの時刻)で同じトラックのクリップを順に割る。
    /// 端から `ClipEditing.minDuration` 未満の所は飛ばす。1 箇所も割れなければ nil。
    public static func splitAtScenes(in project: Project, clipId: String, cuts: [Double]) -> (project: Project, clipIds: [String])? {
        guard let ti = project.tracks.firstIndex(where: { $0.clips.contains { $0.id == clipId } }),
              let origin = project.tracks[ti].clips.first(where: { $0.id == clipId }) else { return nil }
        var p = project
        var ids: [String] = []
        for cut in cuts.sorted() {
            let global = origin.start + cut
            guard let target = p.tracks[ti].clips.first(where: {
                global - $0.start >= ClipEditing.minDuration - 1e-9 && $0.start + $0.duration - global >= ClipEditing.minDuration - 1e-9
            }), let r = ClipEditing.split(in: p, clipId: target.id, at: global) else { continue }
            p = r.project
            ids.append(r.rightId)
        }
        guard !ids.isEmpty else { return nil }
        // 分割でできた全断片(元のクリップと右側たち)の id を並べ直す
        let all = p.tracks[ti].clips.filter { $0.start >= origin.start - 1e-9 && $0.start < origin.start + origin.duration - 1e-9 }.map { $0.id }
        return (p, all.isEmpty ? ids : all)
    }
}
