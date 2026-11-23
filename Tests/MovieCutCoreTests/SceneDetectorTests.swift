import XCTest
import CoreGraphics
@testable import MovieCutCore

/// シーン境界の検出: 指紋と差・カット点の選定(しきい値と最短シーン)・対応判定・分割への適用。
final class SceneDetectorTests: XCTestCase {
    private func solidImage(r: UInt8, g: UInt8, b: UInt8, size: Int = 64) -> CGImage {
        var px = [UInt8](repeating: 255, count: size * size * 4)
        for i in 0 ..< (size * size) { px[i * 4] = r; px[i * 4 + 1] = g; px[i * 4 + 2] = b }
        let ctx = CGContext(data: &px, width: size, height: size, bitsPerComponent: 8,
                            bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    func testSignatureAndDifference() {
        let black = SceneDetector.signature(of: solidImage(r: 0, g: 0, b: 0))
        let white = SceneDetector.signature(of: solidImage(r: 255, g: 255, b: 255))
        let red = SceneDetector.signature(of: solidImage(r: 255, g: 0, b: 0))
        let green = SceneDetector.signature(of: solidImage(r: 0, g: 255, b: 0))
        XCTAssertEqual(black.count, SceneDetector.signatureSize * SceneDetector.signatureSize * 3)
        XCTAssertEqual(SceneDetector.difference(black, black), 0, accuracy: 1e-9)
        XCTAssertEqual(SceneDetector.difference(black, white), 1, accuracy: 0.01, "黒↔白は最大の差")
        XCTAssertEqual(SceneDetector.difference(red, green), 2.0 / 3.0, accuracy: 0.01)
        XCTAssertEqual(SceneDetector.difference([], []), 0)
    }

    func testCutPointsThresholdAndMinScene() {
        // 0.25 秒ごとに 17 サンプル(4 秒)。差の山: 1.0s=0.9、2.0s=0.8、2.25s=0.85、0.25s=0.95(端すぎ)、3.9s=0.2(弱い)
        var times: [Double] = []
        var diffs: [Double] = []
        for i in 0 ... 16 { times.append(Double(i) * 0.25) }
        for i in 0 ..< 16 {
            let t = times[i + 1]
            diffs.append(t == 1.0 ? 0.9 : t == 2.0 ? 0.8 : t == 2.25 ? 0.85 : t == 0.25 ? 0.95 : t == 3.75 ? 0.2 : 0.01)
        }
        let prof = SceneProfile(times: times, diffs: diffs, duration: 4)
        // 既定(しきい値 0.35・最短 0.5): 端の 0.25 は捨て、2.0 と 2.25 は強い 2.25 が残る
        XCTAssertEqual(prof.cutPoints(.default), [1.0, 2.25])
        // しきい値を上げると 0.9 以上だけ
        XCTAssertEqual(prof.cutPoints(SceneParams(threshold: 0.88, sampleInterval: 0.25, minScene: 0.5)), [1.0])
        // 最短シーン 1.3 秒: 頭から 1.3 秒未満の 1.0 は落ち、2.25 が残り、近い 2.0 は落ちる
        XCTAssertEqual(prof.cutPoints(SceneParams(threshold: 0.35, sampleInterval: 0.25, minScene: 1.3)), [2.25])
    }

    func testParamsClamped() {
        let p = SceneParams(threshold: 5, sampleInterval: 0, minScene: 99).clamped
        XCTAssertEqual(p.threshold, SceneParams.thresholdRange.upperBound)
        XCTAssertEqual(p.sampleInterval, SceneParams.intervalRange.lowerBound)
        XCTAssertEqual(p.minScene, SceneParams.minSceneRange.upperBound)
    }

    private func videoClip(speed: Double? = nil, reverse: Bool? = nil, freeze: Bool? = nil) -> Clip {
        var c = Clip(); c.type = .video; c.src = "/x.mp4"; c.start = 10; c.duration = 6; c.srcDuration = 6
        c.speed = speed; c.reverse = reverse; c.freeze = freeze
        return c
    }

    func testSupports() {
        XCTAssertTrue(SceneDetector.supports(videoClip()))
        XCTAssertFalse(SceneDetector.supports(videoClip(speed: 2)))
        XCTAssertFalse(SceneDetector.supports(videoClip(reverse: true)))
        XCTAssertFalse(SceneDetector.supports(videoClip(freeze: true)))
        var img = videoClip(); img.type = .image
        XCTAssertFalse(SceneDetector.supports(img))
        var nosrc = videoClip(); nosrc.src = nil
        XCTAssertFalse(SceneDetector.supports(nosrc))
    }

    func testSplitAtScenes() throws {
        var p = Project.new()
        var c = videoClip(); c.id = "v1"
        p.tracks[0].clips = [c]
        let r = try XCTUnwrap(SceneDetector.splitAtScenes(in: p, clipId: "v1", cuts: [2, 4]))
        let clips = r.project.tracks[0].clips
        XCTAssertEqual(clips.count, 3)
        XCTAssertEqual(clips.map { $0.duration }, [2, 2, 2])
        XCTAssertEqual(clips.map { $0.start }, [10, 12, 14])
        XCTAssertEqual(r.clipIds.count, 3)
        XCTAssertEqual(r.clipIds.first, "v1", "元のクリップが先頭の断片として残る")
        // 端すぎるカットだけでは割れない
        XCTAssertNil(SceneDetector.splitAtScenes(in: p, clipId: "v1", cuts: [0.01]))
        XCTAssertNil(SceneDetector.splitAtScenes(in: p, clipId: "missing", cuts: [2]))
    }
}


// MARK: - バグ確認 第2部 C17: シーン分割は対象クリップの断片だけを割る

final class SceneSplitOverlappingClipsTests: XCTestCase {
    func testSplitDoesNotTouchTheOtherOverlappingClip() {
        var a = Clip(); a.id = "a"; a.type = .video; a.src = "/x/a.mp4"; a.start = 0; a.duration = 10
        var b = Clip(); b.id = "b"; b.type = .video; b.src = "/x/b.mp4"; b.start = 0; b.duration = 10
        var tr = Track(name: "V"); tr.clips = [a, b]
        var p = Project(); p.tracks = [tr]
        let r = SceneDetector.splitAtScenes(in: p, clipId: "b", cuts: [5])
        XCTAssertNotNil(r)
        let clips = r!.project.tracks[0].clips
        XCTAssertEqual(clips.filter { $0.id == "a" }.count, 1, "無関係な A は割らない")
        XCTAssertEqual(clips.filter { $0.id == "a" }[0].duration, 10)
        XCTAssertEqual(clips.count, 3, "B だけが 2 つに割れる")
        XCTAssertFalse(r!.clipIds.contains("a"))
    }
}
