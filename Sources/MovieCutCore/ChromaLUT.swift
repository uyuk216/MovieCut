import Foundation
import CoreGraphics
import CoreImage

private let sRGBSpace = CGColorSpace(name: CGColorSpace.sRGB)!

/// クロマキー: 指定色に近い画素を透明にする。CIColorCube(キーの色から作る)だけでできていて、プレビューも書き出しも同じ経路。
/// 距離は YCbCr の色差(明るさに左右されにくい)。半透明の縁は、色かぶり(キー色の成分)を削ってから前の画素に掛ける。
public enum ChromaKey {
    static let dimension = 64

    /// 立方体の値(RGBA・premultiplied)。純粋な計算なのでテストできる。
    public static func cubeValues(key: (r: Double, g: Double, b: Double), similarity: Double, smoothness: Double, spill: Double) -> [Float] {
        let n = dimension
        func chroma(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double) {
            (-0.168736 * r - 0.331264 * g + 0.5 * b, 0.5 * r - 0.418688 * g - 0.081312 * b)
        }
        let (kcb, kcr) = chroma(key.r, key.g, key.b)
        let thr = max(0, similarity) * 0.6
        let feather = max(0, smoothness) * 0.4
        let kc = [key.r, key.g, key.b]
        let dom = kc.indices.max { kc[$0] < kc[$1] } ?? 1
        var out = [Float](); out.reserveCapacity(n * n * n * 4)
        let m = Double(n - 1)
        for bi in 0..<n { for gi in 0..<n { for ri in 0..<n {
            var c = [Double(ri) / m, Double(gi) / m, Double(bi) / m]
            let (cb, cr) = chroma(c[0], c[1], c[2])
            let d = hypot(cb - kcb, cr - kcr)
            var a: Double
            if feather <= 1e-9 { a = d > thr ? 1 : 0 }
            else { let t = min(max((d - thr) / feather, 0), 1); a = t * t * (3 - 2 * t) }
            if spill > 0 {
                let others = (0..<3).filter { $0 != dom }.map { c[$0] }.max() ?? 0
                c[dom] -= spill * max(0, c[dom] - others)
            }
            out.append(Float(c[0] * a)); out.append(Float(c[1] * a)); out.append(Float(c[2] * a)); out.append(Float(a))
        } } }
        return out
    }

    private static let lock = NSLock()
    private static var cached: (key: String, data: Data)?

    private static func cubeData(hex: String, similarity: Double, smoothness: Double, spill: Double) -> Data {
        let id = "\(hex)|\(similarity)|\(smoothness)|\(spill)"
        lock.lock(); defer { lock.unlock() }
        if let c = cached, c.key == id { return c.data }
        let comps = parseHexColor(hex)?.components ?? [0, 1, 0, 1]
        let k = (r: Double(comps[0]), g: Double(comps.count > 2 ? comps[1] : comps[0]), b: Double(comps.count > 2 ? comps[2] : comps[0]))
        let vals = cubeValues(key: k, similarity: similarity, smoothness: smoothness, spill: spill)
        let data = vals.withUnsafeBufferPointer { Data(buffer: $0) }
        cached = (id, data)
        return data
    }

    /// 入力はクリップの画素(透明な背景つき)。元から透明な所は透明のまま。
    public static func apply(_ img: CIImage, key hex: String, similarity: Double, smoothness: Double, spill: Double) -> CIImage {
        let data = cubeData(hex: hex, similarity: similarity, smoothness: smoothness, spill: spill)
        let keyed = img.applyingFilter("CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": dimension, "inputCubeData": data, "inputColorSpace": sRGBSpace,
        ])
        // キーの結果のアルファに、元のアルファを掛ける(元が透明な所を不透明にしない)
        return keyed.applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: img]).cropped(to: img.extent)
    }
}

/// LUT(.cube)を CIColorCubeWithColorSpace でかける。強さは元の絵との混ぜ具合。
public enum LUTApply {
    public static func apply(_ img: CIImage, lut: CubeLUT, dimension: Int, data: Data, intensity: Double) -> CIImage {
        var src = img
        if lut.hasCustomDomain {
            // 入力の範囲(DOMAIN_MIN/MAX)を 0..1 に正規化
            func s(_ i: Int) -> Double { 1 / Double(lut.domainMax[i] - lut.domainMin[i]) }
            func bias(_ i: Int) -> Double { -Double(lut.domainMin[i]) * s(i) }
            src = src.unpremultiplyingAlpha().applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: s(0), y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: s(1), z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: s(2), w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: bias(0), y: bias(1), z: bias(2), w: 0),
            ]).premultiplyingAlpha()
        }
        let out = src.applyingFilter("CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": dimension, "inputCubeData": data, "inputColorSpace": sRGBSpace,
        ]).cropped(to: img.extent)
        let k = min(max(intensity, 0), 1)
        if k >= 0.999 { return out }
        return img.applyingFilter("CIDissolveTransition", parameters: ["inputTargetImage": out, "inputTime": k]).cropped(to: img.extent)
    }
}
