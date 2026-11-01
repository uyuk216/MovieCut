import Foundation
import CoreGraphics
import Vision

// MARK: - 動きの追従(重ねたクリップの x・y を、下の映像の物体に合わせて動かす)

/// 矩形の追跡器。`start` で最初のコマの矩形を渡し、以後のコマごとに `next` で位置を返す(見失ったら nil)。
/// 矩形は正規化した座標・左上原点(クリップの x・y と同じ向き)。テストでは偽の追跡器を差し込む。
public protocol RectTracking: AnyObject {
    func start(rect: CGRect, image: CGImage)
    func next(image: CGImage) -> CGRect?
}

/// Vision の `VNTrackObjectRequest` による追跡。1 本の連続した流れとして、コマを順に渡す。
public final class VisionRectTracker: RectTracking {
    private let handler = VNSequenceRequestHandler()
    private var observation: VNDetectedObjectObservation?

    public init() {}

    public func start(rect: CGRect, image: CGImage) {
        // Vision は左下原点なので、上下を入れ替える
        observation = VNDetectedObjectObservation(boundingBox: CGRect(x: rect.minX, y: 1 - rect.maxY, width: rect.width, height: rect.height))
    }

    public func next(image: CGImage) -> CGRect? {
        guard let current = observation else { return nil }
        let small = VisionFaceDetector.downscaled(image, maxSide: VisionFaceDetector.maxSide) ?? image
        let request = VNTrackObjectRequest(detectedObjectObservation: current)
        request.trackingLevel = .accurate
        do { try handler.perform([request], on: small) } catch { observation = nil; return nil }
        guard let found = request.results?.first as? VNDetectedObjectObservation else { observation = nil; return nil }
        observation = found
        let b = found.boundingBox
        return CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height)
    }
}

public enum MotionTrack {
    /// 追跡と x・y のキーの間隔(秒あたり回数)。
    public static let sampleRate = 10.0
    /// 最初に追跡する領域(下の映像の中央の正方形。辺は画面の割合)。
    public static let startSize = 0.3
    /// 平滑化の時定数(秒)。小さいほど追従が速く、ぶれも残る。
    public static let smoothTau = 0.15
    /// x・y の値の範囲(Animation の位置の範囲と同じ)。
    static let xRange: ClosedRange<Double> = -2...3

    /// 動きを追従させられるクリップ(文字・図形・画像の重ね)。
    public static func canTrack(_ c: Clip) -> Bool { c.type == .text || c.type == .shape || c.type == .image }

    /// 追従の元になる映像・画像: 選んだクリップより下のレイヤー(配列で前の並び)で、開始時刻にかかっている一番手前のもの。
    public static func sourceClip(for id: String, in project: Project) -> Clip? {
        guard let loc = ClipEditing.locate(id, in: project) else { return nil }
        let overlay = project.tracks[loc.track].clips[loc.index]
        guard canTrack(overlay) else { return nil }
        for tr in project.tracks[0..<loc.track].reversed() where !tr.isHidden {
            if let v = tr.clips.last(where: { ($0.type == .video || $0.type == .image) && $0.src != nil && overlay.start >= $0.start && overlay.start < $0.start + $0.duration }) {
                return v
            }
        }
        return nil
    }

    public static var startRect: CGRect {
        CGRect(x: 0.5 - startSize / 2, y: 0.5 - startSize / 2, width: startSize, height: startSize)
    }

    /// 時刻 k / sampleRate(k = 0…)のコマを順に追跡する。`frame(t)` が nil のコマは見失い扱い(結果は nil)。
    /// コマは 1 枚ずつ渡すので、長い映像でもメモリは一定。
    public static func track(duration: Double, tracker: RectTracking, frame: (Double) -> CGImage?) -> [CGRect?] {
        let n = max(1, Int((max(duration, 0) * sampleRate).rounded(.up)) + 1)
        var out: [CGRect?] = []
        out.reserveCapacity(n)
        var started = false
        for k in 0..<n {
            guard let img = frame(Double(k) / sampleRate) else { out.append(nil); continue }
            if !started {
                tracker.start(rect: startRect, image: img)
                started = true
                out.append(startRect)
            } else {
                out.append(tracker.next(image: img))
            }
        }
        return out
    }

    /// 追跡の結果から x・y のキーフレームを作る。
    /// 見失ったコマは直前の位置を保つ。基準は、追跡の最初の矩形の中心(= 画面の中央)と、クリップの今の位置(baseX, baseY)。
    /// つまり、重ねたクリップは追跡の開始時点の「物体との位置関係」を保ったまま動く。平滑化は AutoReframe.smooth。
    public static func keyframes(samples: [CGRect?], baseX: Double, baseY: Double) -> (x: [Keyframe], y: [Keyframe])? {
        guard !samples.isEmpty, samples.contains(where: { $0 != nil }) else { return nil }
        let dt = 1 / sampleRate
        var cx: [Double] = [], cy: [Double] = []
        var lastX = startRect.midX, lastY = startRect.midY
        for s in samples {
            if let r = s, r.width > 0, r.height > 0 { lastX = Double(r.midX); lastY = Double(r.midY) }
            cx.append(lastX); cy.append(lastY)
        }
        // 開始時点の中心を基準にした差を、クリップの今の位置に足す
        let xs = AutoReframe.smooth(cx.map { baseX + ($0 - Double(startRect.midX)) }, dt: dt, tau: smoothTau)
        let ys = AutoReframe.smooth(cy.map { baseY + ($0 - Double(startRect.midY)) }, dt: dt, tau: smoothTau)
        func keys(_ v: [Double]) -> [Keyframe] {
            v.enumerated().map { Keyframe(t: Double($0.offset) * dt, v: min(max($0.element, xRange.lowerBound), xRange.upperBound)) }
        }
        return (keys(xs), keys(ys))
    }

    /// 追跡の結果を、クリップの x・y のキーフレームに書く(既存の x・y のキーは置き換える)。変化が無ければ false。
    public static func apply(samples: [CGRect?], to clip: inout Clip) -> Bool {
        let bx = Animation.value(of: "x", in: clip, at: 0), by = Animation.value(of: "y", in: clip, at: 0)
        guard let k = keyframes(samples: samples, baseX: bx, baseY: by) else { return false }
        let before = clip.keyframes
        clip.keyframes["x"] = k.x
        clip.keyframes["y"] = k.y
        return clip.keyframes != before
    }
}

extension Renderer {
    /// 追跡用に、映像クリップのコマを時刻 t(プロジェクトの時刻)で取る。映像でなければ nil。
    public func trackingFrame(of c: Clip, at t: Double) -> CGImage? {
        guard let src = c.src, c.type == .video || c.type == .image else { return nil }
        return c.type == .image ? assets.image(at: src) : videoFrame(c, src: src, at: t)
    }
}
