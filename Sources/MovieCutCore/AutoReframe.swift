import Foundation
import CoreGraphics
import Vision

// MARK: - 被写体の検出(差し替え可能)

/// 1 枚の画像から被写体の矩形を返す。矩形は 0〜1 の正規化・左上原点。実装は Vision(`VisionSubjectDetector`)、テストは偽物を使う。
public protocol SubjectDetecting: Sendable {
    func subjects(in image: CGImage) -> [CGRect]
}

/// クリップの頭からの時刻 `t`(秒)での被写体の矩形。
public struct SubjectSample: Equatable, Sendable {
    public var t: Double
    public var rects: [CGRect]
    public init(t: Double, rects: [CGRect]) { self.t = t; self.rects = rects }
}

/// 顔を優先し、無ければ注目(サリエンシー)の物体を返す。小さく縮めてから調べる(`VisionFaceDetector` と同じ縮小)。
public struct VisionSubjectDetector: SubjectDetecting {
    public init() {}

    public func subjects(in image: CGImage) -> [CGRect] {
        guard let small = VisionFaceDetector.downscaled(image, maxSide: VisionFaceDetector.maxSide) else { return [] }
        let faceRequest = VNDetectFaceRectanglesRequest()
        let saliency = VNGenerateAttentionBasedSaliencyImageRequest()
        do { try VNImageRequestHandler(cgImage: small, options: [:]).perform([faceRequest, saliency]) } catch { return [] }
        let faces = (faceRequest.results ?? []).map { Self.topLeft($0.boundingBox) }
        if !faces.isEmpty { return faces }
        let observation = saliency.results?.first as? VNSaliencyImageObservation
        return (observation?.salientObjects ?? []).map { Self.topLeft($0.boundingBox) }
    }

    static func topLeft(_ b: CGRect) -> CGRect { CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height) }
}

// MARK: - 自動リフレーム(16:9 → 9:16 などの切り抜きを、被写体に追従させる)

/// 横長の素材を縦のキャンバスに収めるとき、素材の高さをキャンバスいっぱいに拡大し、横の「窓」(キャンバスに見える部分)を
/// 被写体の中心へ動かす。動きは x のキーフレーム、拡大は一定(scale)で表す。計算は純粋な関数(UI・Undo に依存しない)。
///
/// 窓が常に素材の内側に収まるので、キャンバスの縁に空きは出ない。
public enum AutoReframe {
    /// 検出の間隔(秒あたり回数)。
    public static let sampleRate = 5.0
    /// 動きをならす時定数(秒)。大きいほど窓がゆっくり動く。
    public static let smoothingSeconds = 0.8
    /// 既定の出力先(縦の 1080×1920)。
    public static let portraitWidth = 1080.0
    public static let portraitHeight = 1920.0

    public struct Plan: Equatable, Sendable {
        /// クリップの拡大(`Clip.scale`)。
        public var scale: Double
        /// 横位置 `x` のキーフレーム(クリップの頭からの秒)。
        public var keys: [Keyframe]
        /// 窓の中心(素材の幅に対する割合 0〜1)。`keys` と同じ並び。
        public var centers: [Double]
        /// 窓の幅(素材の幅に対する割合)。
        public var windowWidth: Double
    }

    /// 被写体の横の中心(面積で重み付けした平均)。矩形が無ければ nil。
    public static func focusX(_ rects: [CGRect]) -> Double? {
        var total = 0.0, sum = 0.0
        for r in rects where r.width > 0 && r.height > 0 {
            let a = Double(r.width * r.height)
            total += a
            sum += a * Double(r.midX)
        }
        return total > 0 ? sum / total : nil
    }

    /// 等間隔の列を、前から後ろへ・後ろから前へ、一次の低域通過で 2 回かける(位相のずれが出ない平滑化)。`tau` は時定数(秒)。
    public static func smooth(_ v: [Double], dt: Double, tau: Double) -> [Double] {
        guard v.count > 1, tau > 0, dt > 0 else { return v }
        let a = 1 - exp(-dt / tau)
        var f = v
        for i in 1..<f.count { f[i] = f[i - 1] + a * (v[i] - f[i - 1]) }
        var b = f
        for i in stride(from: b.count - 2, through: 0, by: -1) { b[i] = b[i + 1] + a * (f[i] - b[i + 1]) }
        return b
    }

    /// 素材が横長(幅/高さ > キャンバスの比)のときだけ作れる。縦長・同じ比では nil。
    public static func plan(samples: [SubjectSample], sourceWidth w0: Double, sourceHeight h0: Double,
                            canvasWidth W: Double = portraitWidth, canvasHeight H: Double = portraitHeight,
                            smoothing tau: Double = smoothingSeconds) -> Plan? {
        guard !samples.isEmpty, w0 > 0, h0 > 0, W > 0, H > 0, w0 / h0 > W / H + 1e-9 else { return nil }
        let windowWidth = (W / H) / (w0 / h0)          // 窓の幅(素材の幅に対する割合)
        let half = windowWidth / 2
        // 高さをキャンバスに合わせる拡大(renderer の fit × scale が H / h0 になる値)
        let scale = (H / h0) / min(W / w0, H / h0)
        // 絵の幅(キャンバスの幅に対する割合)。窓の中心を画面の中央へ置く横位置を求める
        let pictureWidth = (H / h0) * w0 / W

        var raw: [Double] = []
        var last = 0.5
        for s in samples {
            if let x = focusX(s.rects) { last = x }
            raw.append(last)
        }
        let dt = samples.count > 1 ? max(1e-6, (samples[samples.count - 1].t - samples[0].t) / Double(samples.count - 1)) : 1 / sampleRate
        let centers = smooth(raw, dt: dt, tau: tau).map { min(max($0, half), 1 - half) }
        let keys = zip(samples, centers).map { Keyframe(t: $0.0.t, v: 0.5 + (0.5 - $0.1) * pictureWidth) }
        return Plan(scale: scale, keys: keys, centers: centers, windowWidth: windowWidth)
    }

    /// クリップに計画を書く(拡大は静的、横位置は x のキーフレーム、縦位置と既存の拡大・縦位置のキーは外す)。
    public static func apply(_ plan: Plan, to clip: inout Clip) {
        clip.scale = abs(plan.scale - 1) < 1e-9 ? nil : plan.scale
        clip.x = nil
        clip.y = nil
        clip.keyframes["scale"] = nil
        clip.keyframes["y"] = nil
        clip.keyframes["x"] = plan.keys
    }
}

// MARK: - 描画側の検出(Renderer と同じ素材の時刻で拾う)

extension Renderer {
    /// クリップの被写体を `AutoReframe.sampleRate` 間隔で検出する。画像は 1 回だけ検出して全部に使う。映像・画像以外や素材が無いときは nil。
    public func reframeSamples(of c: Clip, detector: SubjectDetecting) -> (w: Double, h: Double, list: [SubjectSample])? {
        guard c.type == .image || c.type == .video, let src = c.src else { return nil }
        let n = max(1, Int((max(c.duration, 0) * AutoReframe.sampleRate).rounded(.up)) + 1)
        var size: (w: Double, h: Double)? = nil
        var still: [CGRect]? = nil
        var out: [SubjectSample] = []
        for k in 0..<n {
            let r = Double(k) / AutoReframe.sampleRate
            if c.type == .image {
                if still == nil {
                    guard let img = assets.image(at: src) else { return nil }
                    size = (Double(img.width), Double(img.height))
                    still = detector.subjects(in: img)
                }
                out.append(SubjectSample(t: r, rects: still ?? []))
            } else {
                guard let img = videoFrame(c, src: src, at: c.start + r) else { continue }
                if size == nil { size = (Double(img.width), Double(img.height)) }
                out.append(SubjectSample(t: r, rects: detector.subjects(in: img)))
            }
        }
        guard let s = size else { return nil }
        return (s.w, s.h, out)
    }
}
