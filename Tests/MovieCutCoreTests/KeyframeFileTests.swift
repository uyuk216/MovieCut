import XCTest
@testable import MovieCutCore

/// ファイルへの書き出し・読み込みと、古いファイルへの影響のなさ。
final class KeyframeFileTests: XCTestCase {
    func fixtureURL(_ name: String, ext: String = "ymproj") throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
    }

    /// 触っていない古いファイルは、読んで書いても、この変更の前と 1 バイトも違わない(golden は変更前のコードが書いたもの)。
    func testUntouchedOldFixturesSerializeByteForByte() throws {
        for n in ["rich", "electron-made"] {
            let out = try Project.load(from: fixtureURL(n)).encoded()
            let golden = try Data(contentsOf: fixtureURL("golden-\(n)", ext: "json"))
            XCTAssertEqual(out, golden, n)
            let s = String(decoding: out, as: UTF8.self)
            for k in ["keyframes", "rotation", "flipH", "flipV", "crop"] { XCTAssertFalse(s.contains("\"\(k)\""), "\(n) に \(k) が増えた") }
        }
    }

    func testDefaultTransformWritesNothing() throws {
        var c = Clip(); c.type = .image; c.src = "/a.png"
        var p = Project(); p.tracks = [Track(name: "t")]; p.tracks[0].clips = [c]
        let s = String(decoding: try p.encoded(), as: UTF8.self)
        for k in ["keyframes", "rotation", "flipH", "flipV", "crop"] { XCTAssertFalse(s.contains("\"\(k)\""), k) }
        // 空のキー列は書かない
        p.tracks[0].clips[0].keyframes = ["x": []]
        XCTAssertFalse(String(decoding: try p.encoded(), as: UTF8.self).contains("keyframes"))
    }

    func testRichKeyframeFixtureRoundTrips() throws {
        let p1 = try Project.load(from: fixtureURL("keyframes"))
        let img = p1.allClips.first { $0.id == "kimg" }!
        XCTAssertEqual(img.rotation, 15); XCTAssertEqual(img.flipH, true); XCTAssertEqual(img.flipV, false)
        XCTAssertEqual(img.crop, Crop(l: 0.1, t: 0, r: 0.2, b: 0.05))
        XCTAssertEqual(img.keyframes["x"]!.map(\.ease), [.linear, .easeInOut, .hold])
        XCTAssertEqual(img.keyframes["y"]!.map(\.ease), [.easeIn, .easeOut])
        XCTAssertEqual(img.keyframes["scale"]![0].ease, .bezier(0.25, 0.1, 0.25, 1))
        XCTAssertEqual(Set(img.keyframes.keys), ["x", "y", "scale", "rotation", "opacity", "blur", "futureProperty"])
        XCTAssertEqual(img.extra["futureClipKey"], .string("keep"))
        let txt = p1.allClips.first { $0.id == "ktxt" }!
        XCTAssertEqual(txt.rotation, -10); XCTAssertEqual(txt.keyframes["x"]!.count, 2)
        let blur = p1.allClips.first { $0.id == "kblur" }!
        XCTAssertEqual(Set(blur.keyframes.keys), ["x", "y", "w", "h", "strength"])

        let data1 = try p1.encoded()
        let p2 = try Project.decode(from: data1)
        XCTAssertEqual(p1, p2)
        XCTAssertEqual(try p2.encoded(), data1)       // 書き戻しが安定
        let s = String(decoding: data1, as: UTF8.self)
        XCTAssertTrue(s.contains("bezier:0.25,0.1,0.25,1"))
        XCTAssertTrue(s.contains("futureProperty"))     // 知らない項目名のキーも残る
        XCTAssertFalse(s.contains("\"ease\" : \"linear\""))   // linear は書かない
    }

    func testUnreadableKeyframesAreKeptVerbatim() throws {
        let p = try Project.load(from: fixtureURL("keyframes"))
        let bad = p.allClips.first { $0.id == "kbad" }!
        XCTAssertTrue(bad.keyframes.isEmpty)
        XCTAssertEqual(bad.extra["keyframes"], .string("this is not a keyframe table"))
        XCTAssertTrue(String(decoding: try p.encoded(), as: UTF8.self).contains("this is not a keyframe table"))
    }

    func testLenientKeyframeFields() throws {
        let json = #"{"tracks":[{"clips":[{"type":"image","rotation":"x","crop":{"l":9,"t":-1,"r":"?"},"keyframes":{"x":[{"v":0.4},{"t":2,"ease":"zzz"},{"t":"a","v":1}],"y":[]}}]}]}"#
        let c = try Project.decode(from: Data(json.utf8)).tracks[0].clips[0]
        XCTAssertNil(c.rotation)
        XCTAssertEqual(c.crop, Crop(l: 0.95, t: 0, r: 0, b: 0))          // 範囲に収める
        XCTAssertEqual(c.keyframes["x"], [Keyframe(t: 0, v: 0.4), Keyframe(t: 2, v: 0), Keyframe(t: 0, v: 1)])
        XCTAssertNil(c.keyframes["y"])                                    // 空の列は持たない
    }

    func testCropNormalization() {
        XCTAssertEqual(Crop(l: 0.6, t: 0, r: 0.6, b: 0).normalized.l + Crop(l: 0.6, t: 0, r: 0.6, b: 0).normalized.r, 0.99, accuracy: 1e-12)
        XCTAssertEqual(Crop(l: .nan, t: 2, r: 0, b: 0).normalized, Crop(l: 0, t: 0.95, r: 0, b: 0))
        XCTAssertTrue(Crop().isEmpty)
        XCTAssertEqual(Crop(l: 0.1, t: 0.2, r: 0.3, b: 0.4).keptWidth, 0.6, accuracy: 1e-12)
    }

    func testResolutionScalingAlsoScalesBlurKeys() {
        var c = Clip(); c.type = .image; c.blur = 10
        c.keyframes["blur"] = [Keyframe(t: 0, v: 10), Keyframe(t: 1, v: 20)]
        var b = Clip(); b.type = .blur; b.strength = 8
        b.keyframes["strength"] = [Keyframe(t: 0, v: 4)]
        b.keyframes["x"] = [Keyframe(t: 0, v: 0.3)]
        var p = Project(); p.width = 1920; p.height = 1080; p.tracks = [Track(name: "t")]; p.tracks[0].clips = [c, b]
        let q = p.scaledForResolution(newWidth: 3840, newHeight: 2160)
        XCTAssertEqual(q.tracks[0].clips[0].keyframes["blur"]!.map(\.v), [20, 40])
        XCTAssertEqual(q.tracks[0].clips[1].keyframes["strength"]!.map(\.v), [8])
        XCTAssertEqual(q.tracks[0].clips[1].keyframes["x"]!.map(\.v), [0.3])      // 位置は割合なので変えない
    }
}
