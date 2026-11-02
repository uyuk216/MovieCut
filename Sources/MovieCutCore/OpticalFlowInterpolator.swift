import Foundation
import CoreGraphics
import CoreVideo
import Vision

// MARK: - オプティカルフロー補間(速度が 1 未満のスローモーションの、動きに沿った中間のコマ)
//
// フレームブレンド(2 コマの重ね合わせ)は、動くものが二重に見える。ここでは Vision の `VNGenerateOpticalFlowRequest` で
// 前のコマ A から次のコマ B への画素の動き(フロー)を求め、中間の時刻 w(0 = A、1 = B)のコマを「動きに沿って」作る。
//   中間のコマの画素 p ← (1 − w) × A(p − w·F) + w × B(p + (1 − w)·F)     (F は p での A→B の動き)
// - フローは縮小した画像(長辺 `flowMaxSide`)で求め、描くときに元の大きさへ拡げる(細かい動きより速さ優先)。
// - F は中間のコマ側の位置 p で持ちたいので、A 側の位置 p − w·F(p) でもう一度フローを読み直す(1 回の修正)。
// - 場面が切り替わった(2 コマの輝度がまるで違う)ときは、動きを推定せず近いほうのコマをそのまま出す。
// - 作れなかったとき(Vision の失敗・大きさの食い違い)は呼び出し側が従来のフレームブレンドへ戻す(`frame` は nil を返す)。
// 描画は CPU(行ごとに並列)。プレビューと書き出しは同じ経路(Renderer.videoFrame)で呼ぶので、結果は同じ。

/// 前のコマから次のコマへの画素の動き(縮小したグリッドの画素単位)。2 要素(dx, dy)の並び。
public struct FlowField: Equatable {
    public let width: Int
    public let height: Int
    /// 長さ width × height × 2(行の順、dx と dy が交互)。
    public var data: [Float]

    public init(width: Int, height: Int, data: [Float]) {
        self.width = width; self.height = height; self.data = data
    }

    /// 一定の動き(テスト・既知の動きの検証用)。
    public static func constant(width: Int, height: Int, dx: Float, dy: Float) -> FlowField {
        var d = [Float](repeating: 0, count: width * height * 2)
        for i in 0..<(width * height) { d[2 * i] = dx; d[2 * i + 1] = dy }
        return FlowField(width: width, height: height, data: d)
    }

    /// グリッドの座標 (x, y)(画素の中心が整数 + 0.5 ではなく、整数 = 画素の中心)の双一次補間。範囲外は端の値。
    @inline(__always)
    func sample(_ x: Float, _ y: Float) -> (Float, Float) {
        let fx = min(max(x, 0), Float(width - 1)), fy = min(max(y, 0), Float(height - 1))
        let x0 = Int(fx), y0 = Int(fy)
        let x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
        let tx = fx - Float(x0), ty = fy - Float(y0)
        let i00 = (y0 * width + x0) * 2, i10 = (y0 * width + x1) * 2, i01 = (y1 * width + x0) * 2, i11 = (y1 * width + x1) * 2
        let ux = (data[i00] * (1 - tx) + data[i10] * tx) * (1 - ty) + (data[i01] * (1 - tx) + data[i11] * tx) * ty
        let uy = (data[i00 + 1] * (1 - tx) + data[i10 + 1] * tx) * (1 - ty) + (data[i01 + 1] * (1 - tx) + data[i11 + 1] * tx) * ty
        return (ux, uy)
    }
}

/// 求めたフローの置き場(スレッドセーフ。古いものから捨てる)。素材のコマの組(パス・コマ番号・格子)をキーにする。
public final class FlowCache {
    private let lock = NSLock()
    private var store: [String: FlowField] = [:]
    private var order: [String] = []
    private let capacity: Int
    /// 求めた回数(検証用。キャッシュが効いていれば増えない)。
    public private(set) var computeCount = 0

    public init(capacity: Int = 8) { self.capacity = max(1, capacity) }

    func flow(forKey key: String, compute: () -> FlowField?) -> FlowField? {
        lock.lock()
        if let f = store[key] { lock.unlock(); return f }
        lock.unlock()
        guard let f = compute() else { return nil }
        lock.lock()
        computeCount += 1
        if store[key] == nil { order.append(key) }
        store[key] = f
        while order.count > capacity { store[order.removeFirst()] = nil }
        lock.unlock()
        return f
    }

    public var count: Int { lock.lock(); defer { lock.unlock() }; return store.count }
}

public enum OpticalFlowInterpolator {
    /// フローを求める縮小画像の長辺(画素)。
    public static let flowMaxSide = 320
    /// 場面の切り替えとみなす、縮小した 2 コマの輝度の平均差(0〜1)。
    public static let sceneCutThreshold = 0.28

    // MARK: 画素の取り出し

    /// BGRA8(premultipliedFirst・little endian)に直した画素。
    struct Bitmap {
        var width: Int, height: Int
        var bytes: [UInt8]   // width × height × 4
    }

    static let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue

    /// `space` は画素を読み出す色空間。中間のコマを作るときは、元の画像と同じ色空間で読み書きする(別の空間へ変換して、また戻すと色がずれるため)。
    static func bitmap(of img: CGImage, width: Int, height: Int, space: CGColorSpace? = nil) -> Bitmap? {
        guard width > 0, height > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let ok: Bool = bytes.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: info) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? Bitmap(width: width, height: height, bytes: bytes) : nil
    }

    /// 縮小画像の大きさ(長辺が `flowMaxSide` 以下。2 の倍数に切り捨てない。最小 8)。
    static func flowSize(width: Int, height: Int) -> (Int, Int) {
        let m = max(width, height)
        guard m > flowMaxSide else { return (max(8, width), max(8, height)) }
        let k = Double(flowMaxSide) / Double(m)
        return (max(8, Int((Double(width) * k).rounded())), max(8, Int((Double(height) * k).rounded())))
    }

    // MARK: フローを求める(Vision)

    /// 2 コマの輝度の平均差(0〜1。縮小画像どうし)。
    static func meanLumaDifference(_ a: Bitmap, _ b: Bitmap) -> Double {
        guard a.width == b.width, a.height == b.height, !a.bytes.isEmpty else { return 0 }
        var sum = 0
        let n = a.width * a.height
        for i in 0..<n {
            let o = i * 4
            let la = 29 * Int(a.bytes[o]) + 150 * Int(a.bytes[o + 1]) + 77 * Int(a.bytes[o + 2])   // B,G,R(合計 256)
            let lb = 29 * Int(b.bytes[o]) + 150 * Int(b.bytes[o + 1]) + 77 * Int(b.bytes[o + 2])
            sum += abs(la - lb)
        }
        return Double(sum) / Double(n) / 256 / 255
    }

    /// Vision のフローを足し合わせて直す回数(1 回目は動きを小さめに見積もるので、残りの動きをもう一度求めて足す)。
    public static let refinePasses = 3

    /// A から B への動き(縮小グリッドの画素単位)。Vision が使えない・失敗したときは nil。
    /// Vision の 1 回の結果は、実際の動きより小さく出る(元の大きさや模様によって 4〜8 割)ので、
    /// 求めた動きで B を A の側へ戻して(ワープ)、残りの動きをもう一度求めて足す、を `passes` 回くり返す。
    public static func flow(from a: CGImage, to b: CGImage, passes: Int = refinePasses) -> FlowField? {
        let (fw, fh) = flowSize(width: a.width, height: a.height)
        guard let smallA = smallImage(a, fw, fh), let smallB = smallImage(b, fw, fh) else { return nil }
        guard var total = visionFlow(from: smallA, to: smallB) else { return nil }
        guard passes > 1, let bBits = bitmap(of: smallB, width: smallB.width, height: smallB.height), total.width == smallB.width, total.height == smallB.height else { return total }
        for _ in 1..<passes {
            guard let warped = warp(bBits, by: total), let rest = visionFlow(from: smallA, to: warped), rest.width == total.width, rest.height == total.height else { break }
            for i in 0..<total.data.count { total.data[i] += rest.data[i] }
        }
        return total
    }

    /// B を、動き `flow`(A→B)で A の側へ戻した画像: 出力(p) = B(p + flow(p))。
    static func warp(_ b: Bitmap, by flow: FlowField) -> CGImage? {
        let W = b.width, H = b.height
        guard flow.width == W, flow.height == H else { return nil }
        var out = [UInt8](repeating: 0, count: W * H * 4)
        b.bytes.withUnsafeBufferPointer { bp in
            out.withUnsafeMutableBufferPointer { op in
                let bpb = bp.baseAddress!, opb = op.baseAddress!
                for y in 0..<H {
                    for x in 0..<W {
                        let f = flow.sample(Float(x), Float(y))
                        let p = bilinear(bpb, W, H, Float(x) + f.0, Float(y) + f.1)
                        let o = (y * W + x) * 4
                        opb[o] = UInt8(min(255, max(0, p.0 + 0.5))); opb[o + 1] = UInt8(min(255, max(0, p.1 + 0.5)))
                        opb[o + 2] = UInt8(min(255, max(0, p.2 + 0.5))); opb[o + 3] = UInt8(min(255, max(0, p.3 + 0.5)))
                    }
                }
            }
        }
        return out.withUnsafeMutableBytes { raw -> CGImage? in
            CGContext(data: raw.baseAddress, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info)?.makeImage()
        }
    }

    static func smallImage(_ img: CGImage, _ w: Int, _ h: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// Vision のフロー。`VNGenerateOpticalFlowRequest` は、リクエストに渡した画像(targeted)を基準に、ハンドラの画像への動きを返す。
    /// 向きは `flowSign` で合わせる(テストで、右へ動く四角が正の dx になることを確かめている)。
    static func visionFlow(from a: CGImage, to b: CGImage) -> FlowField? {
        let req = VNGenerateOpticalFlowRequest(targetedCGImage: b, options: [:])
        req.computationAccuracy = .medium
        req.outputPixelFormat = kCVPixelFormatType_TwoComponent32Float
        let handler = VNImageRequestHandler(cgImage: a, options: [:])
        do { try handler.perform([req]) } catch { return nil }
        guard let obs = req.results?.first else { return nil }
        let pb = obs.pixelBuffer
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        guard w > 0, h > 0, CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_TwoComponent32Float,
              let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(pb)
        var data = [Float](repeating: 0, count: w * h * 2)
        for y in 0..<h {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: Float.self)
            for x in 0..<(w * 2) { data[y * w * 2 + x] = row[x] * flowSign }
        }
        // 縮小グリッドと同じ大きさでなければ(Vision が別の大きさで返した場合)、そのまま持つ(sample がグリッド座標で読む)
        return FlowField(width: w, height: h, data: data.map { $0.isFinite ? $0 : 0 })
    }

    /// Vision のフローの向きを A→B(右へ動けば正の dx)にするための符号。
    static let flowSign: Float = 1

    // MARK: 中間のコマを作る

    /// A と B の間 `weight`(0 = A、1 = B)のコマ。フローは A→B(`flow(from:to:)` の結果。縮小グリッドでよい)。
    /// 大きさが違う・作れないときは nil。
    ///
    /// 速さのため、画素ごとの動きは「縮小グリッドの各マスで 1 回だけ」求める(中間のコマ側の位置での動きの読み直しもグリッドの上で行う)。
    /// 画素ごとにはそのグリッドの動きを双一次補間して、A と B を読む位置をずらすだけにする。
    public static func interpolate(_ a: CGImage, _ b: CGImage, weight w: Double, flow: FlowField) -> CGImage? {
        guard a.width == b.width, a.height == b.height, a.width > 0, a.height > 0, flow.width > 0, flow.height > 0,
              flow.data.count >= flow.width * flow.height * 2 else { return nil }
        if w <= 0 { return a }
        if w >= 1 { return b }
        let W = a.width, H = a.height, gW = flow.width, gH = flow.height
        // 元の画像の色空間のまま読み書きする。その空間で RGB の画素を持てないときだけ DeviceRGB
        var cs = a.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        var bitsA = bitmap(of: a, width: W, height: H, space: cs), bitsB = bitmap(of: b, width: W, height: H, space: cs)
        if bitsA == nil || bitsB == nil {
            cs = CGColorSpaceCreateDeviceRGB()
            bitsA = bitmap(of: a, width: W, height: H, space: cs); bitsB = bitmap(of: b, width: W, height: H, space: cs)
        }
        guard let A = bitsA, let B = bitsB else { return nil }
        let wf = Float(w)
        // グリッド ↔ 画素の倍率(フローの値は縮小グリッドの画素単位なので、元の大きさの画素へ直して使う)
        let sx = Float(W) / Float(gW), sy = Float(H) / Float(gH)
        // マスごとの動き(元の大きさの画素単位): 中間のコマ側の位置 p での動き = A 側の位置 p − w·F(p) で読んだ動き
        var disp = [Float](repeating: 0, count: gW * gH * 2)
        for gy in 0..<gH {
            for gx in 0..<gW {
                let f0 = flow.sample(Float(gx), Float(gy))
                let f = flow.sample(Float(gx) - wf * f0.0, Float(gy) - wf * f0.1)
                disp[(gy * gW + gx) * 2] = f.0 * sx
                disp[(gy * gW + gx) * 2 + 1] = f.1 * sy
            }
        }
        var out = [UInt8](repeating: 0, count: W * H * 4)
        let invSx = 1 / sx, invSy = 1 / sy
        let maxGX = Float(gW - 1), maxGY = Float(gH - 1)
        A.bytes.withUnsafeBufferPointer { ap in
            B.bytes.withUnsafeBufferPointer { bp in
                disp.withUnsafeBufferPointer { dp in
                    out.withUnsafeMutableBufferPointer { op in
                        let apb = ap.baseAddress!, bpb = bp.baseAddress!, dpb = dp.baseAddress!, opb = op.baseAddress!
                        let band = 8
                        DispatchQueue.concurrentPerform(iterations: (H + band - 1) / band) { bi in
                            for y in (bi * band)..<min(H, bi * band + band) {
                                let gy = min(max((Float(y) + 0.5) * invSy - 0.5, 0), maxGY)
                                let y0 = Int(gy), y1 = min(y0 + 1, gH - 1), ty = gy - Float(y0)
                                for x in 0..<W {
                                    let gx = min(max((Float(x) + 0.5) * invSx - 0.5, 0), maxGX)
                                    let x0 = Int(gx), x1 = min(x0 + 1, gW - 1), tx = gx - Float(x0)
                                    let i00 = (y0 * gW + x0) * 2, i10 = (y0 * gW + x1) * 2, i01 = (y1 * gW + x0) * 2, i11 = (y1 * gW + x1) * 2
                                    let dx = (dpb[i00] * (1 - tx) + dpb[i10] * tx) * (1 - ty) + (dpb[i01] * (1 - tx) + dpb[i11] * tx) * ty
                                    let dy = (dpb[i00 + 1] * (1 - tx) + dpb[i10 + 1] * tx) * (1 - ty) + (dpb[i01 + 1] * (1 - tx) + dpb[i11 + 1] * tx) * ty
                                    blend(apb, bpb, W, H, Float(x) - wf * dx, Float(y) - wf * dy, Float(x) + (1 - wf) * dx, Float(y) + (1 - wf) * dy, wf, opb + (y * W + x) * 4)
                                }
                            }
                        }
                    }
                }
            }
        }
        return out.withUnsafeMutableBytes { raw -> CGImage? in
            guard let ctx = CGContext(data: raw.baseAddress, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4, space: cs, bitmapInfo: info) else { return nil }
            return ctx.makeImage()
        }
    }

    /// A の (ax, ay) と B の (bx, by)(どちらも画素の中心が整数)を双一次補間して、(1 − w) : w で混ぜた 4 バイトを書く。
    @inline(__always)
    private static func blend(_ A: UnsafePointer<UInt8>, _ B: UnsafePointer<UInt8>, _ W: Int, _ H: Int,
                              _ ax: Float, _ ay: Float, _ bx: Float, _ by: Float, _ w: Float, _ dst: UnsafeMutablePointer<UInt8>) {
        let pa = bilinear(A, W, H, ax, ay), pb = bilinear(B, W, H, bx, by)
        @inline(__always) func put(_ a: Float, _ b: Float) -> UInt8 { UInt8(min(255, max(0, a * (1 - w) + b * w + 0.5))) }
        dst[0] = put(pa.0, pb.0); dst[1] = put(pa.1, pb.1); dst[2] = put(pa.2, pb.2); dst[3] = put(pa.3, pb.3)
    }

    @inline(__always)
    static func bilinear(_ p: UnsafePointer<UInt8>, _ W: Int, _ H: Int, _ x: Float, _ y: Float) -> (Float, Float, Float, Float) {
        let fx = min(max(x, 0), Float(W - 1)), fy = min(max(y, 0), Float(H - 1))
        let x0 = Int(fx), y0 = Int(fy)
        let x1 = min(x0 + 1, W - 1), y1 = min(y0 + 1, H - 1)
        let tx = fx - Float(x0), ty = fy - Float(y0)
        let i00 = (y0 * W + x0) * 4, i10 = (y0 * W + x1) * 4, i01 = (y1 * W + x0) * 4, i11 = (y1 * W + x1) * 4
        func ch(_ k: Int) -> Float {
            let top = Float(p[i00 + k]) * (1 - tx) + Float(p[i10 + k]) * tx
            let bot = Float(p[i01 + k]) * (1 - tx) + Float(p[i11 + k]) * tx
            return top * (1 - ty) + bot * ty
        }
        return (ch(0), ch(1), ch(2), ch(3))
    }

    // MARK: 描画から呼ぶ入口

    /// 描画の入口: A と B の間の `weight` のコマ。フローは `cache`(キー = 素材のコマの組)から。
    /// 場面が切り替わっていれば近いほうのコマ。フローが求められなければ nil(呼び出し側がフレームブレンドへ戻す)。
    static func frame(_ a: CGImage, _ b: CGImage, weight w: Double, key: String, cache: FlowCache) -> CGImage? {
        if w <= 0 { return a }
        if w >= 1 { return b }
        guard a.width == b.width, a.height == b.height else { return nil }
        guard let f = cache.flow(forKey: key, compute: { () -> FlowField? in
            let (fw, fh) = flowSize(width: a.width, height: a.height)
            guard let sa = bitmap(of: a, width: fw, height: fh), let sb = bitmap(of: b, width: fw, height: fh) else { return nil }
            if meanLumaDifference(sa, sb) > sceneCutThreshold {
                return FlowField(width: 0, height: 0, data: [])          // 場面の切り替えの印(空のフロー)
            }
            return flow(from: a, to: b)
        }) else { return nil }
        if f.width == 0 { return w < 0.5 ? a : b }
        return interpolate(a, b, weight: w, flow: f)
    }
}

// MARK: - クリップの補間の方式

/// コマの補間の方式(インスペクタの選択)。保存は `frameBlend` / `frameFlow`(なし = どちらも書かない)。
public enum FrameInterpolation: String, CaseIterable, Sendable {
    case none, blend, flow

    public var label: String {
        switch self {
        case .none: return "なし"
        case .blend: return "ブレンド（重ね合わせ）"
        case .flow: return "オプティカルフロー（動きに沿う）"
        }
    }
}

public extension Clip {
    /// 補間の方式(オプティカルフローが優先)。
    var frameInterpolation: FrameInterpolation { frameFlow == true ? .flow : (frameBlend == true ? .blend : .none) }

    /// 方式を書く(使わない側のキーは消す。既定の `none` は何も書かない)。
    mutating func setFrameInterpolation(_ m: FrameInterpolation) {
        frameBlend = m == .blend ? true : nil
        frameFlow = m == .flow ? true : nil
    }
}
