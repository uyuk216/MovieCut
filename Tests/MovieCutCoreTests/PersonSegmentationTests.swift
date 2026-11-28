import XCTest
import CoreGraphics
import CoreImage
@testable import MovieCutCore

/// 人物セグメンテーション: Vision 本体は実写依存なので、後処理(マスク→インスタンス)と、
/// 合成の人物マスクを既存オブジェクトマスクの経路へ流したときの「残す／消す」を確かめる。
final class PersonSegmentationTests: XCTestCase {
    private let ctx = CIContext(options: [.useSoftwareRenderer: true])

    /// 64×64 の黒地に、左上原点で `person` の矩形を白く塗った人物マスク(CIImage)。
    private func personMask(_ person: CGRect, size: Int = 64) -> CIImage {
        var px = [UInt8](repeating: 0, count: size * size)
        for y in 0..<size { for x in 0..<size where person.contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) { px[y * size + x] = 255 } }
        let provider = CGDataProvider(data: Data(px) as CFData)!
        let cg = CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: size,
                         space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
                         decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        return CIImage(cgImage: cg)
    }

    func testInstanceFromMaskScalesToImageAndMeasuresRect() throws {
        let inst = try XCTUnwrap(PersonMaskInstance.make(from: personMask(CGRect(x: 16, y: 8, width: 16, height: 32)),
                                                         imageSize: CGSize(width: 320, height: 160), context: ctx).first)
        XCTAssertEqual(inst.mask.width, 320)
        XCTAssertEqual(inst.mask.height, 160)
        XCTAssertEqual(inst.rect.x, 0.25, accuracy: 0.02)
        XCTAssertEqual(inst.rect.y, 0.125, accuracy: 0.02)
        XCTAssertEqual(inst.rect.w, 0.25, accuracy: 0.02)
        XCTAssertEqual(inst.rect.h, 0.5, accuracy: 0.02)
    }

    func testNoPersonGivesNoInstance() {
        XCTAssertTrue(PersonMaskInstance.make(from: personMask(.zero), imageSize: CGSize(width: 100, height: 100), context: ctx).isEmpty)
    }

    /// 合成の人物マスクから種マスクを作り、オブジェクトマスクへ載せる。keep(人物だけ残す)と invert(人物だけ消す)。
    func testKeepAndRemovePersonThroughObjectMask() throws {
        let inst = try XCTUnwrap(PersonMaskInstance.make(from: personMask(CGRect(x: 16, y: 16, width: 32, height: 32)),
                                                         imageSize: CGSize(width: 200, height: 200), context: ctx).first)
        let seed = ObjectMaskImage.cropped(inst.mask, toNormalized: inst.rect).flatMap { ObjectMaskImage.pngBase64(of: $0) }
        func alpha(invert: Bool, x: Int, y: Int) throws -> Int {
            let om = try XCTUnwrap(ObjectMaskPropagation.build(sourceClipId: "c", seedTime: 0, seedRect: inst.rect, seedMaskBase64: seed,
                                                              track: ObjectTrack(sourceClipId: "c", startRect: inst.rect,
                                                                                 samples: [TrackSample(t: 0, rect: inst.rect)]),
                                                              invert: invert))
            let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 200, height: 200))
            let out = ObjectMaskRenderer.apply(red, objectMask: om, at: 0, canvasWidth: 200, canvasHeight: 200, originX: 0, originY: 0)
            let cg = try XCTUnwrap(ctx.createCGImage(out, from: CGRect(x: 0, y: 0, width: 200, height: 200)))
            var d = [UInt8](repeating: 0, count: 200 * 200 * 4)
            let c = CGContext(data: &d, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 800,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            c.translateBy(x: 0, y: 200); c.scaleBy(x: 1, y: -1)
            c.draw(cg, in: CGRect(x: 0, y: 0, width: 200, height: 200))
            return Int(d[(y * 200 + x) * 4 + 3])
        }
        XCTAssertEqual(try alpha(invert: false, x: 100, y: 100), 255, "人物だけ残す: 人物の中は残る")
        XCTAssertEqual(try alpha(invert: false, x: 10, y: 10), 0, "人物だけ残す: 外は透明")
        XCTAssertEqual(try alpha(invert: true, x: 100, y: 100), 0, "人物だけ消す: 人物の中は透明")
        XCTAssertEqual(try alpha(invert: true, x: 10, y: 10), 255, "人物だけ消す: 外は残る")
    }
}
