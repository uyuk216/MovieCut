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

// MARK: - 自動リフレーム(横長の素材を縦・正方形などのキャンバスへ、被写体に追従させて切り抜く)

/// 出力アスペクトの選択肢。`original` は素材の比率のまま(切り抜かず、ズームと追従だけ使う)。
public enum ReframeAspect: String, CaseIterable, Sendable, Codable {
    case portrait9x16, portrait4x5, square, landscape16x9, original

    public var title: String {
        switch self {
        case .portrait9x16: return "9:16(縦動画)"
        case .portrait4x5: return "4:5"
        case .square: return "1:1(正方形)"
        case .landscape16x9: return "16:9(横)"
        case .original: return "元の比率のまま"
        }
    }

    /// 出力キャンバスの画素数。`original` は素材の比率で長辺 1920(偶数に丸める)。
    public func canvas(sourceWidth w0: Double, sourceHeight h0: Double) -> (w: Int, h: Int) {
        switch self {
        case .portrait9x16: return (1080, 1920)
        case .portrait4x5: return (1080, 1350)
        case .square: return (1080, 1080)
        case .landscape16x9: return (1920, 1080)
        case .original:
            guard w0 > 0, h0 > 0 else { return (1920, 1080) }
            func even(_ v: Double) -> Int { max(2, Int((v / 2).rounded()) * 2) }
            return w0 >= h0 ? (1920, even(1920 * h0 / w0)) : (even(1920 * w0 / h0), 1920)
        }
    }
}

/// 被写体が複数あるときの追い方。
public enum ReframeSubjectMode: String, CaseIterable, Sendable, Codable {
    /// 従来どおり: 全部の矩形の面積で重み付けした中心。
    case primary
    /// 一番大きい被写体だけを追う。
    case largest
    /// 全員が入る窓(全矩形を囲む枠の中心。ズームが許せば全員が窓に入る)。
    case group

    public var title: String {
        switch self {
        case .primary: return "主な被写体(従来)"
        case .largest: return "一番大きい被写体"
        case .group: return "全員が入る窓"
        }
    }
}

/// リフレームの調整値。既定値のままなら従来(9:16・横のみ・ズームなし・主被写体)と同じ結果。
public struct ReframeOptions: Equatable, Sendable {
    public var aspect: ReframeAspect = .portrait9x16
    public var subjectMode: ReframeSubjectMode = .primary
    /// 縦(y)にも追従する。縦に余裕が無い(窓の高さが素材いっぱい)ときは何も起きない。
    public var followY = true
    /// y の平滑化は x の時定数のこの倍(縦はゆっくり)。
    public var yTauScale = 1.5
    /// 被写体の大きさに応じたズーム。既定はオフ。
    public var zoomEnabled = false
    /// ズーム倍率の下限・上限(「窓いっぱいに収まる拡大」を 1 とした倍率。下限は 1 未満にしない)。
    public var zoomMin = 1.0
    public var zoomMax = 1.6
    /// ズームの時定数(秒)。位置より長くして、揺れにくくする。
    public var zoomSmoothingSeconds = 1.5
    public init() {}
}

/// 横長の素材をキャンバスいっぱいに拡大し(cover)、キャンバスに見える部分(窓)を被写体へ動かす。
/// 動きは x・y のキーフレーム、拡大は静的な scale か(ズーム時)scale のキーフレームで表す。計算は純粋な関数。
///
/// 窓は常に素材の内側に収まるので、キャンバスの縁に空きは出ない。
public enum AutoReframe {
    /// 検出の間隔(秒あたり回数)。
    public static let sampleRate = 5.0
    /// 動きをならす時定数(秒)。大きいほど窓がゆっくり動く。
    public static let smoothingSeconds = 0.8
    /// 既定の出力先(縦の 1080×1920)。
    public static let portraitWidth = 1080.0
    public static let portraitHeight = 1920.0

    public struct Plan: Equatable, Sendable {
        /// クリップの拡大(`Clip.scale`)。ズーム時は時間で変わるので、その最小値(=ズーム 1 倍の cover)を持つ。
        public var scale: Double
        /// 横位置 `x` のキーフレーム(クリップの頭からの秒)。
        public var keys: [Keyframe]
        /// 窓の中心(素材の幅に対する割合 0〜1)。`keys` と同じ並び。
        public var centers: [Double]
        /// 窓の幅(素材の幅に対する割合)。ズーム 1 倍のとき。
        public var windowWidth: Double
        /// 縦位置 `y` のキーフレーム。縦に動かないときは空。
        public var yKeys: [Keyframe] = []
        /// 窓の中心 y(素材の高さに対する割合 0〜1)。`keys` と同じ並び。
        public var centersY: [Double] = []
        /// 窓の高さ(素材の高さに対する割合)。ズーム 1 倍のとき。
        public var windowHeight: Double = 1
        /// 拡大のキーフレーム。ズームしないときは空(静的な `scale` を使う)。
        public var scaleKeys: [Keyframe] = []
        /// サンプルごとのズーム倍率(1 以上)。`keys` と同じ並び。
        public var zooms: [Double] = []
        /// 出力キャンバス(画素)。
        public var canvasWidth: Int = 1080
        public var canvasHeight: Int = 1920
    }

    // MARK: 被写体の選び方

    private static func valid(_ rects: [CGRect]) -> [CGRect] { rects.filter { $0.width > 0 && $0.height > 0 } }

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

    /// 追う対象: 中心(cx, cy)、大きさ(面積の平方根。ズームの目安)、窓に入れたい枠。
    public struct Focus: Equatable, Sendable {
        public var cx: Double, cy: Double, size: Double
        public var box: CGRect
    }

    public static func focus(_ rects: [CGRect], mode: ReframeSubjectMode) -> Focus? {
        let rs = valid(rects)
        guard !rs.isEmpty else { return nil }
        let union = rs.dropFirst().reduce(rs[0]) { $0.union($1) }
        switch mode {
        case .primary:
            var total = 0.0, sx = 0.0, sy = 0.0
            for r in rs { let a = Double(r.width * r.height); total += a; sx += a * Double(r.midX); sy += a * Double(r.midY) }
            return Focus(cx: sx / total, cy: sy / total, size: total.squareRoot(), box: union)
        case .largest:
            let r = rs.max { $0.width * $0.height < $1.width * $1.height }!
            return Focus(cx: Double(r.midX), cy: Double(r.midY), size: Double(r.width * r.height).squareRoot(), box: r)
        case .group:
            return Focus(cx: Double(union.midX), cy: Double(union.midY), size: Double(union.width * union.height).squareRoot(), box: union)
        }
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

    /// 上位 `q`(0〜1)の値。
    static func quantile(_ v: [Double], _ q: Double) -> Double {
        guard !v.isEmpty else { return 0 }
        let s = v.sorted()
        return s[min(s.count - 1, max(0, Int((Double(s.count - 1) * q).rounded())))]
    }

    /// 素材の比がキャンバスと違う(または、ズームする)ときだけ作れる。縦長・同じ比で、ズームもしないときは nil。
    /// `canvasWidth/Height` を省くと `options.aspect` から決める。
    public static func plan(samples: [SubjectSample], sourceWidth w0: Double, sourceHeight h0: Double,
                            canvasWidth: Double? = nil, canvasHeight: Double? = nil,
                            smoothing tau: Double = smoothingSeconds,
                            options: ReframeOptions = ReframeOptions()) -> Plan? {
        let size = options.aspect.canvas(sourceWidth: w0, sourceHeight: h0)
        let W = canvasWidth ?? (options.aspect == .portrait9x16 ? portraitWidth : Double(size.w))
        let H = canvasHeight ?? (options.aspect == .portrait9x16 ? portraitHeight : Double(size.h))
        guard !samples.isEmpty, w0 > 0, h0 > 0, W > 0, H > 0 else { return nil }
        let sameRatio = abs((w0 / h0) - (W / H)) < 1e-9
        // 従来(9:16・ズームなし)は、横長の素材でだけ作る。縦長・同じ比は nil
        if options.aspect == .portrait9x16 && !options.zoomEnabled && w0 / h0 <= W / H + 1e-9 { return nil }
        if sameRatio && !options.zoomEnabled { return nil }

        // 画素/素材 px: fit(全体が収まる)と cover(キャンバスを覆う)
        let fit = min(W / w0, H / h0)
        let cover = max(W / w0, H / h0)
        let baseScale = cover / fit
        let windowWidth = W / (cover * w0)             // ズーム 1 倍の窓(素材に対する割合)。cover なので 1 以下
        let windowHeight = H / (cover * h0)

        let n = samples.count
        let dt = n > 1 ? max(1e-6, (samples[n - 1].t - samples[0].t) / Double(n - 1)) : 1 / sampleRate

        // 被写体の列(見つからないコマは直前の値を保つ)
        var rawX: [Double] = [], rawY: [Double] = [], rawSize: [Double] = []
        var boxes: [CGRect?] = []
        var lastX = 0.5, lastY = 0.5, lastSize: Double? = nil
        for s in samples {
            let f = focus(s.rects, mode: options.subjectMode)
            if let f { lastX = f.cx; lastY = f.cy; lastSize = f.size }
            rawX.append(lastX); rawY.append(lastY)
            rawSize.append(lastSize ?? 0)
            boxes.append(f?.box)
        }

        // ズーム: 被写体が大きい(近い)時を基準 1 倍にして、小さい(遠い)ほど寄る
        var zooms = [Double](repeating: 1, count: n)
        if options.zoomEnabled {
            let zMin = max(1, options.zoomMin), zMax = max(zMin, options.zoomMax)
            let known = rawSize.filter { $0 > 0 }
            if !known.isEmpty {
                let ref = quantile(known, 0.9)
                let fallback = known[0]
                let raw = rawSize.map { ref / max($0 > 0 ? $0 : fallback, 1e-6) }
                zooms = smooth(raw, dt: dt, tau: options.zoomSmoothingSeconds).map { min(max($0, zMin), zMax) }
            }
        }
        // 全員が入る窓: 枠が窓に収まる範囲までしか寄らない
        if options.subjectMode == .group {
            for i in 0..<n {
                guard let b = boxes[i] else { continue }
                let limit = min(windowWidth / (Double(b.width) * 1.05), windowHeight / (Double(b.height) * 1.05))
                zooms[i] = max(1, min(zooms[i], limit))
            }
        }

        let smoothX = smooth(rawX, dt: dt, tau: tau)
        let smoothY = smooth(rawY, dt: dt, tau: tau * options.yTauScale)
        let keepX = options.zoomEnabled || options.subjectMode != .primary    // 従来の横の追い方は変えない
        var cxs: [Double] = [], cys: [Double] = []
        var keys: [Keyframe] = [], yKeys: [Keyframe] = [], scaleKeys: [Keyframe] = []
        var movesY = false
        for i in 0..<n {
            let z = zooms[i]
            let hw = windowWidth / z / 2, hh = windowHeight / z / 2
            var cx = smoothX[i], cy = options.followY ? smoothY[i] : 0.5
            if let b = boxes[i] {
                // 被写体の枠が窓から出ないように寄せる(入りきらない大きさなら何もしない)
                let m = 0.1
                if options.followY, Double(b.height) <= 2 * hh * (1 - m) {
                    cy = min(max(cy, Double(b.maxY) - hh * (1 - m)), Double(b.minY) + hh * (1 - m))
                }
                if keepX, Double(b.width) <= 2 * hw * (1 - m) {
                    cx = min(max(cx, Double(b.maxX) - hw * (1 - m)), Double(b.minX) + hw * (1 - m))
                }
            }
            cx = min(max(cx, hw), 1 - hw)
            cy = min(max(cy, hh), 1 - hh)
            if hh < 0.5 - 1e-9 { movesY = true }
            cxs.append(cx); cys.append(cy)
            let d = fit * baseScale * z                    // 素材 1px あたりのキャンバス px
            let picW = d * w0 / W, picH = d * h0 / H       // 絵の大きさ(キャンバスに対する割合)
            let t = samples[i].t
            keys.append(Keyframe(t: t, v: 0.5 + (0.5 - cx) * picW))
            yKeys.append(Keyframe(t: t, v: 0.5 + (0.5 - cy) * picH))
            scaleKeys.append(Keyframe(t: t, v: baseScale * z))
        }
        let zoomed = options.zoomEnabled && zooms.contains { $0 > 1 + 1e-9 }
        var plan = Plan(scale: baseScale, keys: keys, centers: cxs, windowWidth: windowWidth)
        plan.windowHeight = windowHeight
        plan.centersY = cys
        plan.zooms = zooms
        plan.canvasWidth = Int(W.rounded()); plan.canvasHeight = Int(H.rounded())
        if movesY && options.followY { plan.yKeys = yKeys }
        if zoomed { plan.scaleKeys = scaleKeys }
        return plan
    }

    /// クリップに計画を書く(拡大は静的かキーフレーム、横位置は x のキーフレーム、縦位置は動くときだけ y のキーフレーム。既存のキーは外す)。
    public static func apply(_ plan: Plan, to clip: inout Clip) {
        clip.scale = (plan.scaleKeys.isEmpty && abs(plan.scale - 1) < 1e-9) ? nil : plan.scale
        clip.x = nil
        clip.y = nil
        clip.keyframes["scale"] = plan.scaleKeys.isEmpty ? nil : plan.scaleKeys
        clip.keyframes["y"] = plan.yKeys.isEmpty ? nil : plan.yKeys
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
        // 左右反転したクリップでは、被写体は表示上は鏡像の位置にいる。検出結果を反転後の座標へ直してから計画させる
        if c.flipH == true {
            out = out.map { smp in
                SubjectSample(t: smp.t, rects: smp.rects.map { CGRect(x: 1 - $0.maxX, y: $0.minY, width: $0.width, height: $0.height) })
            }
        }
        return (s.w, s.h, out)
    }
}
