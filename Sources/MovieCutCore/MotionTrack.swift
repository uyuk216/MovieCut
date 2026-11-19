import Foundation
import CoreGraphics
import Vision

// MARK: - 動きの追従(重ねたクリップの x・y を、下の映像の物体に合わせて動かす)

/// 追跡器の 1 コマ分の観測。`confidence` は 0〜1(Vision の `VNObservation.confidence`)で、
/// 分からない追跡器(テスト用の偽物など)は nil。その場合は信頼できるものとして扱う。
public struct TrackObservation: Equatable, Sendable {
    public var rect: CGRect?
    public var confidence: Double?
    public init(rect: CGRect?, confidence: Double?) { self.rect = rect; self.confidence = confidence }
}

/// 矩形の追跡器。`start` で最初のコマの矩形を渡し、以後のコマごとに `next` で位置を返す(見失ったら nil)。
/// 矩形は正規化した座標・左上原点(クリップの x・y と同じ向き)。テストでは偽の追跡器を差し込む。
public protocol RectTracking: AnyObject {
    func start(rect: CGRect, image: CGImage)
    func next(image: CGImage) -> CGRect?
    /// 信頼つきで次の観測を取る。差し替えない追跡器は `next` の結果を「信頼度は分からない」として包む。
    func nextObservation(image: CGImage) -> TrackObservation
}

public extension RectTracking {
    func nextObservation(image: CGImage) -> TrackObservation {
        TrackObservation(rect: next(image: image), confidence: nil)
    }
}

/// 見失いの判定(純粋な計算。Vision に依存しないので、観測列だけでテストできる)。
///
/// 根拠(R4-4 の実測と R4-5 の方針):
/// - 採用下限は信頼度 0.5。VNConfidence(0〜1)の中点で、「正しいより正しくない」観測を採らない境目。
///   合成コマでの実測(R4-5)では、正常に追えている間は 0.62〜1.00、見失った側は 0.00〜0.36 で、
///   0.5 は両者の間の谷にあたる。0.2 程度まで下げると、対象が消えた後に Vision が返し続ける
///   静止矩形(実測では信頼度 0.109)が採用されてしまう。
/// - 1 コマだけの失敗では打ち切らない(瞬間的なぶれ・圧縮ノイズで正常な追跡を切らないため)。
///   `consecutiveFailureLimit`(3 回 = 10 回/秒で 0.3 秒)続いたら見失いと確定し、確定位置は
///   「連続失敗の先頭」のサンプルとする。以後のサンプルは呼び出し側が切り捨てるので、
///   不採用の観測がキーフレームになることはない。0.3 秒は補間の許容(`ObjectTrack.maxGap` 1.0 秒)
///   より十分短く、短い欠落は従来どおり直前の位置の保持でつなぐ。
public struct TrackingLossGate: Sendable {
    /// 採用する信頼度の下限(0〜1)。
    public static let minimumConfidence = 0.5
    /// 見失いと確定するまでの連続失敗数(サンプル数)。
    public static let consecutiveFailureLimit = 3

    /// 見失いが確定したサンプルの添字(連続失敗の先頭)。未確定なら nil。
    public private(set) var lostIndex: Int?
    private var streakStart: Int?
    private var streak = 0

    public init() {}

    public var isLost: Bool { lostIndex != nil }

    /// 観測が採用できるか(矩形が有効で、信頼度が分かる場合は下限以上。信頼度が NaN のものは不採用)。
    public static func isTrusted(rect: CGRect?, confidence: Double?) -> Bool {
        guard let r = rect, r.width > 0, r.height > 0,
              r.minX.isFinite, r.minY.isFinite, r.width.isFinite, r.height.isFinite else { return false }
        if let c = confidence, !(c >= minimumConfidence) { return false }
        return true
    }

    /// 1 サンプル分の観測を判定し、採用なら true を返す。不採用の観測は呼び出し側で nil として扱う。
    /// 失敗が `consecutiveFailureLimit` 続いたら見失いを確定し、`lostIndex` に連続失敗の先頭を記録する。
    @discardableResult
    public mutating func evaluate(index: Int, rect: CGRect?, confidence: Double?) -> Bool {
        if isLost { return false }
        if Self.isTrusted(rect: rect, confidence: confidence) {
            streak = 0; streakStart = nil
            return true
        }
        if streak == 0 { streakStart = index }
        streak += 1
        if streak >= Self.consecutiveFailureLimit { lostIndex = streakStart }
        return false
    }

    /// 観測列にゲートを通した結果(採用した矩形の列と、見失った添字)。
    /// 見失いが確定したら、その先頭より前で切り捨てる。以後の観測は結果に残らない。
    public static func filter(observations: [TrackObservation]) -> (rects: [CGRect?], lostIndex: Int?) {
        var gate = TrackingLossGate()
        var out: [CGRect?] = []
        out.reserveCapacity(observations.count)
        for (i, o) in observations.enumerated() {
            out.append(gate.evaluate(index: i, rect: o.rect, confidence: o.confidence) ? o.rect : nil)
            if gate.isLost { break }
        }
        if let li = gate.lostIndex { out = Array(out.prefix(li)) }
        return (out, gate.lostIndex)
    }

    /// サンプル列のうち、キー化してよい個数。末尾の連続した見失い(nil・無効な矩形)が
    /// `consecutiveFailureLimit` 以上続く場合は、その手前までにする(末尾の保持で静止キーを焼かない)。
    /// 途中の短い欠落や、末尾でも短い欠落は従来どおり保持の対象なので数えない。
    public static func effectiveCount(samples: [CGRect?]) -> Int {
        var trailing = 0
        for r in samples.reversed() {
            if isTrusted(rect: r, confidence: nil) { break }
            trailing += 1
        }
        return trailing >= consecutiveFailureLimit ? samples.count - trailing : samples.count
    }
}

/// 追跡の実行結果。`lostAt` は見失いで打ち切った時刻(クリップ頭からの秒)。最後まで追えたら nil。
public struct TrackingRun {
    public var rects: [CGRect?]
    public var lostAt: Double?
    public init(rects: [CGRect?], lostAt: Double?) { self.rects = rects; self.lostAt = lostAt }
}

/// Vision の `VNTrackObjectRequest` による追跡。1 本の連続した流れとして、コマを順に渡す。
public final class VisionRectTracker: RectTracking {
    private let handler = VNSequenceRequestHandler()
    private var observation: VNDetectedObjectObservation?
    /// 見失いが確定したか。確定したら、それ以降は観測を返さない(静止矩形を返し続けない)。
    private var lost = false
    /// 低信頼が続いた回数。最後の正常な観測を種に保ったまま数える。
    private var lowStreak = 0

    public init() {}

    public func start(rect: CGRect, image: CGImage) {
        // Vision は左下原点なので、上下を入れ替える
        observation = VNDetectedObjectObservation(boundingBox: CGRect(x: rect.minX, y: 1 - rect.maxY, width: rect.width, height: rect.height))
        lost = false
        lowStreak = 0
    }

    public func next(image: CGImage) -> CGRect? {
        let o = nextObservation(image: image)
        guard let r = o.rect, TrackingLossGate.isTrusted(rect: r, confidence: o.confidence) else { return nil }
        return r
    }

    public func nextObservation(image: CGImage) -> TrackObservation {
        guard !lost, let current = observation else { return TrackObservation(rect: nil, confidence: 0) }
        let small = VisionFaceDetector.downscaled(image, maxSide: VisionFaceDetector.maxSide) ?? image
        let request = VNTrackObjectRequest(detectedObjectObservation: current)
        request.trackingLevel = .accurate
        do { try handler.perform([request], on: small) } catch { lost = true; observation = nil; return TrackObservation(rect: nil, confidence: 0) }
        guard let found = request.results?.first as? VNDetectedObjectObservation else { lost = true; observation = nil; return TrackObservation(rect: nil, confidence: 0) }
        let b = found.boundingBox
        let rect = CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height)
        let confidence = Double(found.confidence)
        if confidence >= TrackingLossGate.minimumConfidence {
            observation = found
            lowStreak = 0
        } else {
            // 低信頼の観測は次の追跡の種にしない(最後の正常な観測から再挑戦できるようにする)。
            // それが続いたら見失いを確定し、以後のコマでは観測を返さない。
            lowStreak += 1
            if lowStreak >= TrackingLossGate.consecutiveFailureLimit { lost = true; observation = nil }
        }
        return TrackObservation(rect: rect, confidence: confidence)
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
    /// 信頼できない観測(低信頼・無効な矩形)は採用せず、`TrackingLossGate` で見失いが確定したら
    /// 連続失敗の先頭で打ち切る(結果はそこまでのサンプルだけになり、`lostAt` にその時刻が入る)。
    public static func track(duration: Double, tracker: RectTracking, frame: (Double) -> CGImage?) -> [CGRect?] {
        trackRun(duration: duration, tracker: tracker, frame: frame).rects
    }

    /// `track` の見失い情報つき版。見失いで打ち切った場合は `lostAt` が入る。
    public static func trackRun(duration: Double, tracker: RectTracking, frame: (Double) -> CGImage?) -> TrackingRun {
        let n = max(1, Int((max(duration, 0) * sampleRate).rounded(.up)) + 1)
        var out: [CGRect?] = []
        out.reserveCapacity(n)
        var started = false
        var gate = TrackingLossGate()
        for k in 0..<n {
            guard let img = frame(Double(k) / sampleRate) else {
                if started { _ = gate.evaluate(index: k, rect: nil, confidence: 0) }
                out.append(nil)
                if gate.isLost { break }
                continue
            }
            if !started {
                tracker.start(rect: startRect, image: img)
                started = true
                out.append(startRect)
            } else {
                let o = tracker.nextObservation(image: img)
                out.append(gate.evaluate(index: k, rect: o.rect, confidence: o.confidence) ? o.rect : nil)
            }
            if gate.isLost { break }
        }
        var lostAt: Double? = nil
        if let li = gate.lostIndex {
            lostAt = Double(li) / sampleRate
            out = Array(out.prefix(li))
        }
        return TrackingRun(rects: out, lostAt: lostAt)
    }

    /// 追跡の結果から x・y のキーフレームを作る。
    /// 見失ったコマは直前の位置を保つ。基準は、追跡の最初の矩形の中心(= 画面の中央)と、クリップの今の位置(baseX, baseY)。
    /// つまり、重ねたクリップは追跡の開始時点の「物体との位置関係」を保ったまま動く。平滑化は AutoReframe.smooth。
    public static func keyframes(samples: [CGRect?], baseX: Double, baseY: Double) -> (x: [Keyframe], y: [Keyframe])? {
        guard !samples.isEmpty, samples.contains(where: { $0 != nil }) else { return nil }
        // 末尾まで見失いが続く列は、見失いの先頭で切る(直前の位置を保ったまま静止キーを最後まで焼かない)
        let usable = Array(samples.prefix(TrackingLossGate.effectiveCount(samples: samples)))
        guard usable.contains(where: { $0 != nil }) else { return nil }
        let dt = 1 / sampleRate
        var cx: [Double] = [], cy: [Double] = []
        var lastX = startRect.midX, lastY = startRect.midY
        for s in usable {
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
