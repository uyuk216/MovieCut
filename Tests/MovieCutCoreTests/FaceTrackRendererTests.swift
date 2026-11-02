import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import MovieCutCore

/// 顔の追従(track)を描画経路で確かめる。検出器は呼び出しのたびに位置が動く偽物を差し込む(検出は時刻順に呼ばれる)。
final class FaceTrackRendererTests: XCTestCase {
    /// 検出のたびに少しずつ右へ動く顔(呼び出し回数で位置が決まる)
    final class MovingFace: FaceDetecting, @unchecked Sendable {
        private var calls = 0
        private let lock = NSLock()
        func faces(in image: CGImage) -> [CGRect] {
            lock.lock(); let i = calls; calls += 1; lock.unlock()
            return [CGRect(x: 0.1 + 0.02 * Double(i), y: 0.3, width: 0.2, height: 0.4)]
        }
    }

    /// 細かい縦縞の PNG(320×180)。モザイクで必ず変わる絵。
    func stripesPNG() throws -> String {
        let c = CGContext(data: nil, width: 320, height: 180, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        var x = 0, k = 0
        while x < 320 { c.setFillColor(CGColor(gray: k % 2 == 0 ? 1 : 0, alpha: 1)); c.fill(CGRect(x: x, y: 0, width: 3, height: 180)); x += 3; k += 1 }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("face-track-stripes-\(UUID().uuidString).png")
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, c.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url.path
    }

    struct Pixels { let w: Int; let h: Int; let d: [UInt8] }

    func pixels(_ img: CGImage) -> Pixels {
        var d = [UInt8](repeating: 0, count: img.width * img.height * 4)
        let c = CGContext(data: &d, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return Pixels(w: img.width, h: img.height, d: d)
    }

    /// 元の絵と比べて変わった画素の外接矩形(無ければ nil)
    func changedBox(_ a: Pixels, _ b: Pixels) -> CGRect? {
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in 0..<a.h { for x in 0..<a.w {
            let i = (y * a.w + x) * 4
            if a.d[i] != b.d[i] || a.d[i + 1] != b.d[i + 1] || a.d[i + 2] != b.d[i + 2] {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        } }
        guard maxX >= 0 else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    func testTrackedFaceBlurFollowsTheFaceOverTime() throws {
        let saved = FaceDetectionCache.shared
        defer { FaceDetectionCache.shared = saved }
        FaceDetectionCache.shared = FaceDetectionCache(detector: MovingFace())

        var img = Clip(); img.type = .image; img.src = try stripesPNG(); img.start = 0; img.duration = 3
        img.id = "tracked-\(UUID().uuidString)"
        var face = Effect(.faceBlur)
        face.params["track"] = 1
        face.params["mode"] = 0
        face.params["size"] = 24
        img.effects = [face]
        var plain = img; plain.effects = []

        func render(_ c: Clip, _ t: Double) throws -> Pixels {
            var p = Project(); p.width = 320; p.height = 180; p.fps = 30
            var tr = Track(); tr.clips = [c]; p.tracks = [tr]
            return pixels(try XCTUnwrap(Renderer(project: p, assets: RenderAssets()).renderImage(t: t)))
        }

        let base = try render(plain, 0.2)
        let early = try XCTUnwrap(changedBox(base, try render(img, 0.2)), "追従した顔の中がぼかされる")
        let lateBox = try XCTUnwrap(changedBox(try render(plain, 2.0), try render(img, 2.0)))
        // 検出は時刻とともに右へ動く。ぼかしの中心も右へ動く
        XCTAssertGreaterThan(lateBox.midX - early.midX, 10)
        // 変わった範囲は顔の付近だけ(画面全体ではない)
        XCTAssertLessThan(early.width, 320 * 0.6)
    }
}
