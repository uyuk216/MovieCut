import XCTest
import CoreGraphics
import CoreImage
@testable import MovieCutCore

/// 映像ノイズ除去(監査 #59 / W3-22): 有効時はノイズのばらつきが減り、無効・強さ0では描画が従来と一致する。
final class VideoDenoiseTests: XCTestCase {
    /// 一様な灰色(128)に ±40 の粒状ノイズを乗せた、センサーノイズ風の素材。
    private func textured(_ w: Int, _ h: Int, seed: UInt64 = 4242) -> CGImage {
        var d = [UInt8](repeating: 255, count: w * h * 4)
        var s = seed
        func next() -> UInt8 { s = s &* 6364136223846793005 &+ 1442695040888963407; return UInt8(truncatingIfNeeded: s >> 33) }
        for i in 0..<(w * h) { let v = UInt8(clamping: 128 + Int(next()) % 81 - 40); d[i * 4] = v; d[i * 4 + 1] = v; d[i * 4 + 2] = v }
        return d.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        }
    }

    private func rgba(_ img: CGImage) -> [UInt8] {
        var d = [UInt8](repeating: 0, count: img.width * img.height * 4)
        let c = CGContext(data: &d, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return d
    }

    private func apply(_ src: CGImage, _ values: [String: Double]) -> [UInt8] {
        let fx = [ResolvedEffect(kind: .denoise, values: values, color: "#000000")]
        let bounds = CGRect(x: 0, y: 0, width: src.width, height: src.height)
        let out = EffectPipeline.apply(CIImage(cgImage: src), effects: fx, bounds: bounds, scale: 1)
        return rgba(EffectPipeline.makeImage(out, from: bounds)!)
    }

    private func redStdDev(_ d: [UInt8]) -> Double {
        let vs = stride(from: 0, to: d.count, by: 4).map { Double(d[$0]) }
        let mean = vs.reduce(0, +) / Double(vs.count)
        return (vs.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(vs.count)).squareRoot()
    }

    func testKindHasLabelAndParams() {
        XCTAssertEqual(EffectKind.denoise.label, "ノイズ除去")
        let spec = try? XCTUnwrap(EffectKind.denoise.spec("strength"))
        XCTAssertEqual(spec?.range, 0...1)
        XCTAssertEqual(spec?.defaultValue, 0.5)
    }

    func testDenoiseReducesNoiseVariance() {
        let src = textured(64, 64)
        let before = redStdDev(rgba(src))
        let after = redStdDev(apply(src, ["strength": 1.0]))
        XCTAssertGreaterThan(before, 15, "前提: 入力は十分にノイズを含んでいる")
        XCTAssertLessThan(after, before * 0.7, "ノイズ除去でばらつきが大きく減る")
    }

    func testStrengthZeroIsIdentityInResolve() {
        var c = Clip(); c.type = .image
        c.effects = [Effect(kind: EffectKind.denoise.rawValue, params: ["strength": 0])]
        XCTAssertTrue(EffectPipeline.resolve(c, atClipTime: 0).isEmpty, "強さ0は解決時に落ちて従来の描画になる")
        c.effects = [Effect(kind: EffectKind.denoise.rawValue, params: ["strength": 0.5])]
        XCTAssertEqual(EffectPipeline.resolve(c, atClipTime: 0).count, 1)
        // 無効化されていれば効かない
        c.effects = [Effect(kind: EffectKind.denoise.rawValue, enabled: false, params: ["strength": 0.5])]
        XCTAssertTrue(EffectPipeline.resolve(c, atClipTime: 0).isEmpty)
    }

    func testHelperMappingIsMonotonicAndIdentityAtZero() {
        XCTAssertEqual(VideoDenoise.noiseLevel(forStrength: 0), 0.02, accuracy: 1e-9)
        XCTAssertLessThan(VideoDenoise.noiseLevel(forStrength: 0.2), VideoDenoise.noiseLevel(forStrength: 0.8))
        XCTAssertGreaterThan(VideoDenoise.sharpness(forStrength: 0.2), VideoDenoise.sharpness(forStrength: 0.8))
        let img = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
        XCTAssertEqual(VideoDenoise.apply(img, strength: 0).extent, img.extent)
    }

    func testEffectRoundTripKeepsDenoise() throws {
        var c = Clip(); c.type = .video
        c.effects = [Effect(EffectKind.denoise)]
        let data = try JSONEncoder().encode(c)
        let back = try JSONDecoder().decode(Clip.self, from: data)
        XCTAssertEqual(back.effects.first?.known, .denoise)
        XCTAssertEqual(back.effects.first?.value("strength"), 0.5)
        // エフェクト無しのクリップは従来どおり(effects キー自体を書かない流儀は既存テストが担保)
        let plain = try JSONEncoder().encode(Clip())
        XCTAssertFalse(String(data: plain, encoding: .utf8)?.contains("denoise") ?? true)
    }
}
