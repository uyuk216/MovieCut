import Foundation
import CoreGraphics
import Vision

// MARK: - 手ぶれ補正(簡易版)
//
// 仕組み: 一定の間隔(既定 30 サンプル/秒)でコマを取り、隣り合うコマの画素のずれを測る。
// ずれを足し合わせると「カメラの軌跡」になる。その軌跡を移動平均で滑らかにし、
// 滑らかな軌跡と実際の軌跡の差を、コマの中身の平行移動(補正量)として当てる。
// 補正で空いた縁は、わずかに拡大して隠す(拡大率はクリップ全体で 1 つ)。
// 解析は素材・配置ごとに 1 回だけ行い、結果をキャッシュする(`StabilizationCache`)。

/// 隣り合うコマの「映像の中身の動き」を測る。戻り値は px(左上原点・下向き正)で、
/// prev の中身が next でどれだけ動いたか。測れなければ nil。テストでは偽物を差し込む。
public protocol MotionEstimating: Sendable {
    func displacement(from prev: CGImage, to next: CGImage) -> CGVector?
    /// 回転・拡大縮小・平行移動(相似変換)で測る。測れなければ nil(既定は未対応 = nil。呼び出し側は `displacement` に戻る)。
    func similarity(from prev: CGImage, to next: CGImage) -> SimilarityMotion?
}

public extension MotionEstimating {
    func similarity(from prev: CGImage, to next: CGImage) -> SimilarityMotion? { nil }
}

/// 隣り合うコマの「映像の中身の動き」を相似変換で表したもの。コマの中心が原点。
/// 中身の点 p は next で `scale × R(angle) × p + (dx, dy)` へ動く。座標は左上原点・下向き正なので、`angle` は見た目の時計回りが正(ラジアン)。dx・dy は px。
public struct SimilarityMotion: Sendable, Equatable {
    public var angle: Double
    public var scale: Double
    public var dx: Double
    public var dy: Double
    public init(angle: Double, scale: Double, dx: Double, dy: Double) {
        self.angle = angle; self.scale = scale; self.dx = dx; self.dy = dy
    }

    /// 点の組 p → q(中心原点・どちらも同じ向きの座標)から、最小二乗の相似変換を当てはめる。点が足りない・縮退なら nil。
    public static func fit(from p: [CGPoint], to q: [CGPoint]) -> SimilarityMotion? {
        guard p.count == q.count, p.count >= 2 else { return nil }
        let n = Double(p.count)
        let pm = CGPoint(x: p.map(\.x).reduce(0, +) / n, y: p.map(\.y).reduce(0, +) / n)
        let qm = CGPoint(x: q.map(\.x).reduce(0, +) / n, y: q.map(\.y).reduce(0, +) / n)
        var re = 0.0, im = 0.0, den = 0.0
        for i in p.indices {
            let a = CGPoint(x: p[i].x - pm.x, y: p[i].y - pm.y), b = CGPoint(x: q[i].x - qm.x, y: q[i].y - qm.y)
            re += a.x * b.x + a.y * b.y      // conj(a)·b の実部
            im += a.x * b.y - a.y * b.x      // 虚部
            den += a.x * a.x + a.y * a.y
        }
        guard den > 1e-12 else { return nil }
        let s = (re * re + im * im).squareRoot() / den
        guard s > 1e-9, s.isFinite else { return nil }
        let th = atan2(im, re)
        let c = cos(th) * s, sn = sin(th) * s
        let tx = qm.x - (c * pm.x - sn * pm.y), ty = qm.y - (sn * pm.x + c * pm.y)
        return SimilarityMotion(angle: th, scale: s, dx: tx, dy: ty)
    }

    /// 逆の変換。
    public var inverse: SimilarityMotion {
        let s = 1 / scale, th = -angle
        // t' = −(1/s) R(−θ) t
        let c = cos(th), sn = sin(th)
        return SimilarityMotion(angle: th, scale: s, dx: -s * (c * dx - sn * dy), dy: -s * (sn * dx + c * dy))
    }
}

/// Vision の VNTranslationalImageRegistrationRequest。長辺 960 px に縮小して測る(縮小の段の粗さを抑えつつ速さを保つ。結果は元の大きさに戻す)。
public struct VisionMotionEstimator: MotionEstimating {
    public static let maxSide = 960
    public init() {}

    public func displacement(from prev: CGImage, to next: CGImage) -> CGVector? {
        guard let a = VisionFaceDetector.downscaled(prev, maxSide: Self.maxSide),
              let b = VisionFaceDetector.downscaled(next, maxSide: Self.maxSide),
              a.width == b.width, a.height == b.height else { return nil }
        let k = Double(max(prev.width, prev.height)) / Double(max(a.width, a.height))
        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: b, options: [:])
        do { try VNImageRequestHandler(cgImage: a, options: [:]).perform([request]) } catch { return nil }
        guard let obs = request.results?.first as? VNImageTranslationAlignmentObservation else { return nil }
        // Vision の整列量は「対象を基準に重ねるための移動」。中身の動きはその逆向き。
        // 整列量は左下原点(y 上向き)なので、y は符号を変えて左上原点に直す。
        let t = obs.alignmentTransform
        return CGVector(dx: -t.tx * k, dy: t.ty * k)
    }
}

extension VisionMotionEstimator {
    /// VNHomographicImageRegistrationRequest で相似変換を測る。長辺 960 px に縮小して測る(結果の平行移動は元の大きさに戻す)。
    public func similarity(from prev: CGImage, to next: CGImage) -> SimilarityMotion? {
        guard let a = VisionFaceDetector.downscaled(prev, maxSide: Self.maxSide),
              let b = VisionFaceDetector.downscaled(next, maxSide: Self.maxSide),
              a.width == b.width, a.height == b.height else { return nil }
        let k = Double(max(prev.width, prev.height)) / Double(max(a.width, a.height))
        let request = VNHomographicImageRegistrationRequest(targetedCGImage: b, options: [:])
        do { try VNImageRequestHandler(cgImage: a, options: [:]).perform([request]) } catch { return nil }
        guard let obs = request.results?.first as? VNImageHomographicAlignmentObservation else { return nil }
        let H = obs.warpTransform
        let w = Double(a.width), h = Double(a.height)
        // 画素座標(左下原点・y 上向き)で、格子の点を H に通す。中心原点に直して相似変換を当てはめる。
        var p: [CGPoint] = [], q: [CGPoint] = []
        for gy in 0...4 { for gx in 0...4 {
            let x = w * Double(gx) / 4, y = h * Double(gy) / 4
            let v = H * SIMD3<Float>(Float(x), Float(y), 1)
            guard v.z.isFinite, abs(v.z) > 1e-6 else { return nil }
            p.append(CGPoint(x: x - w / 2, y: y - h / 2))
            q.append(CGPoint(x: Double(v.x / v.z) - w / 2, y: Double(v.y / v.z) - h / 2))
        }}
        guard let fit = SimilarityMotion.fit(from: p, to: q) else { return nil }
        // Vision の変換は「対象を基準に重ねる向き」= 中身の動きの逆。逆にして、y を下向きに直す(角度と dy の符号が変わる)。
        let m = fit.inverse
        guard m.angle.isFinite, m.scale.isFinite else { return nil }
        return SimilarityMotion(angle: -m.angle, scale: m.scale, dx: m.dx * k, dy: -m.dy * k)
    }
}

/// 移動平均による低域通過。軌跡を滑らかにするだけの純粋な関数(画像に触れない)。
public enum MotionSmoothing {
    /// 各点を、前後 `radius` 点の平均にする。端では窓を切って、あるぶんだけで平均する。`radius` が 0 以下なら元のまま。
    public static func smooth(_ path: [Double], radius: Int) -> [Double] {
        guard radius > 0, path.count > 1 else { return path }
        // 累積和で O(n)
        var prefix = [Double](repeating: 0, count: path.count + 1)
        for (i, v) in path.enumerated() { prefix[i + 1] = prefix[i] + v }
        return path.indices.map { i in
            let lo = max(0, i - radius), hi = min(path.count - 1, i + radius)
            return (prefix[hi + 1] - prefix[lo]) / Double(hi - lo + 1)
        }
    }
}

/// 解析の結果: コマごとの補正量(px)と、縁を隠す拡大率。`correction(atClipTime:)` で任意の時刻の補正を線形補間で取る。
public struct Stabilization: Sendable, Equatable {
    /// サンプルの間隔(秒)
    public let step: Double
    public let dx: [Double]
    public let dy: [Double]
    /// 縁を隠す拡大率(1 以上)。補正量の最大に合わせて、クリップ全体で 1 つ。
    public let zoom: Double
    /// 回転の補正量(ラジアン。見た目の時計回りが正)。回転・拡大縮小の補正を使わないときは空。
    public let rot: [Double]
    /// 拡大縮小の補正量(対数。0 = 変わらない)。回転・拡大縮小の補正を使わないときは空。
    public let logScale: [Double]

    public init(step: Double, dx: [Double], dy: [Double], zoom: Double, rot: [Double] = [], logScale: [Double] = []) {
        self.step = step; self.dx = dx; self.dy = dy; self.zoom = zoom; self.rot = rot; self.logScale = logScale
    }

    /// 任意の時刻の補正(平行移動に加えて、回転と拡大縮小)。回転・拡大縮小を使わない解析では (0, 1)。
    public func similarityCorrection(atClipTime r: Double) -> (dx: Double, dy: Double, angle: Double, scale: Double) {
        let t = correction(atClipTime: r)
        guard !rot.isEmpty, rot.count == dx.count, logScale.count == dx.count else { return (t.dx, t.dy, 0, 1) }
        let f = min(max(r / step, 0), Double(dx.count - 1))
        let i = Int(f), j = min(i + 1, dx.count - 1), w = f - Double(i)
        return (t.dx, t.dy, rot[i] * (1 - w) + rot[j] * w, exp(logScale[i] * (1 - w) + logScale[j] * w))
    }

    public func correction(atClipTime r: Double) -> (dx: Double, dy: Double) {
        guard !dx.isEmpty else { return (0, 0) }
        let f = min(max(r / step, 0), Double(dx.count - 1))
        let i = Int(f), j = min(i + 1, dx.count - 1), w = f - Double(i)
        return (dx[i] * (1 - w) + dx[j] * w, dy[i] * (1 - w) + dy[j] * w)
    }
}

public enum Stabilizer {
    /// 解析の間隔(サンプル/秒)
    public static let sampleRate = 30.0
    /// 移動平均の窓の半分(秒)。この長さより速い揺れを消し、ゆっくりした pan は残す。
    public static let smoothingSeconds = 0.5

    /// クリップ全体を解析する。`frame(clipTime)` は素材のコマ(取れなければ nil。その間は動かなかったとみなす)。
    /// `strength` は 0〜1: 補正量 = strength × (滑らかな軌跡 − 実際の軌跡)。0 なら何もしない補正量になる。
    /// コマが 1 枚も取れなければ nil。
    public static func analyze(duration: Double, strength: Double, frame: (Double) -> CGImage?,
                               estimator: MotionEstimating, sampleRate: Double = sampleRate,
                               smoothingSeconds: Double = smoothingSeconds, rotationZoom: Bool = false) -> Stabilization? {
        let step = 1 / sampleRate
        let n = max(1, Int((max(duration, 0) * sampleRate).rounded(.up)) + 1)
        var px: [Double] = [], py: [Double] = []   // px[k] = サンプル k までの累積の移動量
        var acc = CGVector(dx: 0, dy: 0)
        var pa: [Double] = [], pl: [Double] = []   // 回転・拡大縮小(対数)の累積
        var accA = 0.0, accL = 0.0
        var prev: CGImage?
        var size: (w: Int, h: Int)?
        for k in 0..<n {
            if let img = frame(Double(k) * step) {
                if size == nil { size = (img.width, img.height) }
                if let p = prev {
                    if rotationZoom, let m = estimator.similarity(from: p, to: img) {
                        acc.dx += m.dx; acc.dy += m.dy; accA += m.angle; accL += log(m.scale)
                    } else if let m = estimator.displacement(from: p, to: img) {
                        acc.dx += m.dx; acc.dy += m.dy
                    }
                }
                prev = img
            }
            px.append(acc.dx); py.append(acc.dy); pa.append(accA); pl.append(accL)
        }
        guard let s = size, s.w > 0, s.h > 0 else { return nil }
        let radius = max(1, Int((smoothingSeconds * sampleRate / 2).rounded()))
        let sx = MotionSmoothing.smooth(px, radius: radius), sy = MotionSmoothing.smooth(py, radius: radius)
        let amount = min(max(strength, 0), 1)
        let cx = (0..<px.count).map { amount * (sx[$0] - px[$0]) }
        let cy = (0..<py.count).map { amount * (sy[$0] - py[$0]) }
        if rotationZoom {
            let sa = MotionSmoothing.smooth(pa, radius: radius), sl = MotionSmoothing.smooth(pl, radius: radius)
            let ca = (0..<pa.count).map { amount * (sa[$0] - pa[$0]) }
            let cl = (0..<pl.count).map { amount * (sl[$0] - pl[$0]) }
            let z = requiredZoom(width: Double(s.w), height: Double(s.h), dx: cx, dy: cy, angle: ca, logScale: cl)
            return Stabilization(step: step, dx: cx, dy: cy, zoom: z, rot: ca, logScale: cl)
        }
        // 中身を補正量だけ動かすと縁が空く。先に動かしてから中心まわりに拡大する(warp の順)ので、
        // 左端の位置は c(1 − z) + z·o。これが 0 以下になる最小の z = 1 / (1 − 2m)、m = 最大のずれ / 幅(高さ)。
        let worstX = cx.map { abs($0) / Double(s.w) }.max() ?? 0
        let worstY = cy.map { abs($0) / Double(s.h) }.max() ?? 0
        let zoom = 1 / (1 - 2 * min(max(worstX, worstY), 0.25))
        return Stabilization(step: step, dx: cx, dy: cy, zoom: zoom)
    }

    /// 回転・拡大縮小・平行移動の補正を当てたあと、縁(黒)が見えない最小の拡大率。補正は「動かす → 回す → 拡大縮小 → zoom」の順。
    /// 出力の四隅を逆にたどって元の絵の外に出ないための条件(軸ごとの安全側の見積り)。上限は 2 倍。
    public static func requiredZoom(width w: Double, height h: Double, dx: [Double], dy: [Double], angle: [Double], logScale: [Double]) -> Double {
        var z = 1.0
        for i in dx.indices {
            let th = i < angle.count ? angle[i] : 0
            let s = exp(i < logScale.count ? logScale[i] : 0)
            let c = abs(cos(th)), sn = abs(sin(th))
            // 逆回転した四隅の |x|・|y| の最大(中心原点)
            let ax = (w / 2) * c + (h / 2) * sn, ay = (w / 2) * sn + (h / 2) * c
            let rx = w / 2 - min(abs(dx[i]), w / 2 * 0.5), ry = h / 2 - min(abs(dy[i]), h / 2 * 0.5)
            z = max(z, ax / (s * rx), ay / (s * ry))
        }
        return min(z, 2)
    }

    /// 画像を (dx, dy) だけ動かしてから、中心を拡大率 zoom で拡大して、同じ大きさの新しい画像にする(縁を隠すのは zoom)。
    public static func warp(_ img: CGImage, dx: Double, dy: Double, zoom: Double, angle: Double = 0, scale: Double = 1) -> CGImage? {
        let w = img.width, h = img.height
        guard w > 0, h > 0, let ctx = Renderer.makeContext(width: w, height: h) else { return nil }
        // 写る位置 = 中心 + zoom × (元の位置 + (dx, dy) − 中心)。先に動かして、中心まわりに拡大する。
        // CG の座標は左下原点なので、画像の下向きの動き dy は CG では −dy
        ctx.translateBy(x: CGFloat(Double(w) / 2), y: CGFloat(Double(h) / 2))
        ctx.scaleBy(x: CGFloat(zoom), y: CGFloat(zoom))
        if scale != 1 { ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale)) }
        if angle != 0 { ctx.rotate(by: CGFloat(-angle)) }   // CG は y 上向き。見た目の時計回りが正なので符号を反転
        ctx.translateBy(x: CGFloat(dx), y: CGFloat(-dy))
        ctx.draw(img, in: CGRect(x: -Double(w) / 2, y: -Double(h) / 2, width: Double(w), height: Double(h)))
        return ctx.makeImage()
    }
}

/// 解析結果のキャッシュ(キーは素材・配置・強さ)。同じクリップの再描画(プレビューの戻し・書き出し)で解析を繰り返さない。
/// 件数が上限を超えたら全部捨てる(単純・メモリを抑える)。
public final class StabilizationCache: @unchecked Sendable {
    public static let shared = StabilizationCache()
    public static let capacity = 16

    private let lock = NSLock()
    private var store: [String: Stabilization] = [:]
    private var inFlight: Set<String> = []
    private var failed: Set<String> = []

    public init() {}

    /// 鍵の値があればそれを返す。無ければ `build` で作って保存する(build は鍵の外で走る)。
    public func value(key: String, build: () -> Stabilization?) -> Stabilization? {
        lock.lock()
        if let v = store[key] { lock.unlock(); return v }
        lock.unlock()
        guard let v = build() else { return nil }
        lock.lock()
        if store.count >= Self.capacity { store.removeAll(keepingCapacity: true) }
        store[key] = v
        lock.unlock()
        return v
    }

    /// プレビュー用: 解析が終わっていればそれを返す。無ければ背景で解析を始めて nil を返す(呼び出し側は補正なしのコマを出す)。
    /// 解析が終わったら `onReady` を背景のスレッドで呼ぶ(呼び出し側が主スレッドへ送る)。同じ鍵の解析は同時に 1 つだけ。
    /// 書き出し・CLI は `value(key:build:)` を使い、結果が出るまで待つ(書き出しの結果は解析の完了を待つので常に同じ)。
    public func lazyValue(key: String, build: @escaping () -> Stabilization?, onReady: (() -> Void)?) -> Stabilization? {
        lock.lock()
        if let v = store[key] { lock.unlock(); return v }
        if failed.contains(key) || inFlight.contains(key) { lock.unlock(); return nil }
        inFlight.insert(key)
        lock.unlock()
        DispatchQueue.global(qos: .utility).async { [self] in
            let v = build()
            lock.lock()
            inFlight.remove(key)
            if let v {
                if store.count >= Self.capacity { store.removeAll(keepingCapacity: true) }
                store[key] = v
            } else {
                failed.insert(key)   // 解析できない素材は、描くたびに解析し直さない
            }
            lock.unlock()
            onReady?()
        }
        return nil
    }

    public var count: Int { lock.lock(); defer { lock.unlock() }; return store.count }
    public func clear() { lock.lock(); store.removeAll(); failed.removeAll(); lock.unlock() }
}

// MARK: - クリップ側

/// 手ぶれ補正の設定(映像クリップ)。オフは `stabilize` を nil に戻す(ファイルには書かない)。
public enum StabilizeEditing {
    /// メニューで入れたときの強さ。
    public static let defaultStrength = 0.8

    public static func supports(_ c: Clip) -> Bool { c.type == .video && c.src != nil }

    /// オンなら切る、オフなら既定の強さで入れる。値が変わったら true。
    @discardableResult
    public static func toggle(_ c: inout Clip) -> Bool {
        let before = c.stabilize
        c.stabilize = c.stabilizeStrength > 0 ? nil : defaultStrength
        return c.stabilize != before
    }

    /// 強さを決める(0〜1 に丸める。0 は「オフ」なので `stabilize` を nil にする = ファイルに書かない)。値が変わったら true。
    @discardableResult
    public static func setStrength(_ c: inout Clip, _ v: Double) -> Bool {
        let before = c.stabilize
        let s = v.isFinite ? min(max(v, 0), 1) : 0
        c.stabilize = s > 0 ? s : nil
        if s <= 0 { c.stabilizeRoll = nil }   // オフにしたら傾き・拡大縮小の指定も消す
        return c.stabilize != before
    }

    /// 傾き・拡大縮小も補正するか(オンのときだけ true を書く)。補正がオフ・映像以外なら何もしない。値が変わったら true。
    @discardableResult
    public static func setRotationZoom(_ c: inout Clip, _ on: Bool) -> Bool {
        guard supports(c), c.stabilizeStrength > 0 else { return false }
        let before = c.stabilizeRoll
        c.stabilizeRoll = on ? true : nil
        return c.stabilizeRoll != before
    }
}

public extension Clip {
    /// 手ぶれ補正の強さ(0 = オフ、0〜1)。
    /// 傾き・拡大縮小の補正が有効(補正がオンで、指定がある)。
    var stabilizeRollOn: Bool { stabilizeRoll == true && stabilizeStrength > 0 }

    var stabilizeStrength: Double { stabilize.map { $0.isFinite ? min(max($0, 0), 1) : 0 } ?? 0 }

    /// 解析結果のキャッシュ鍵。素材・配置・時間の取り方・強さが変われば別の鍵になる。
    func stabilizeCacheKey(src: String) -> String {
        "\(id)|\(src)|\(offset)|\(duration)|\(effectiveSpeed)|\(effectiveReverse)|\(hasTimeRemap)|\(stabilizeStrength)" + (stabilizeRollOn ? "|roll" : "")
    }
}
