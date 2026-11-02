import XCTest
@testable import MovieCutCore

final class UnusedMediaTests: XCTestCase {
    private func clip(_ id: String, _ type: ClipType, src: String? = nil) -> Clip {
        var c = Clip(); c.id = id; c.type = type; c.src = src; c.duration = 1
        return c
    }

    func testEmptyProjectHasNothing() {
        XCTAssertTrue(UnusedMedia.find(in: Project()).isEmpty)
    }

    func testUnusedAndDirectlyUsed() {
        var p = Project()
        p.mediaPool = ["/m/a.mp4", "/m/b.png"]
        p.tracks[0].clips = [clip("1", .video, src: "/m/a.mp4")]
        XCTAssertEqual(UnusedMedia.find(in: p).map(\.path), ["/m/b.png"])
        XCTAssertEqual(UnusedMedia.find(in: p)[0].fileName, "b.png")
        XCTAssertEqual(UnusedMedia.find(in: p)[0].directory, "/m")
    }

    func testUsedOnlyInsideCompoundChild() {
        var p = Project()
        p.mediaPool = ["/m/in.mp4", "/m/out.mp4"]
        var inner = Track(name: "中"); inner.clips = [clip("k", .video, src: "/m/in.mp4")]
        var comp = clip("c", .compound); comp.tracks = [inner]
        p.tracks[0].clips = [comp]
        XCTAssertEqual(UnusedMedia.find(in: p).map(\.path), ["/m/out.mp4"])
    }

    func testAudioTextAndOtherReferences() {
        var p = Project()
        p.mediaPool = ["/m/s.wav", "/m/l.cube", "/m/face.png", "/m/x.png"]
        var fx = Effect(kind: "lut"); fx.path = "/m/l.cube"
        var img = clip("i", .image, src: "/m/x2.png"); img.effects = [fx]
        p.tracks[0].clips = [clip("a", .audio, src: "/m/s.wav"), clip("t", .text), img]
        p.characters[0].imgClosed = "/m/face.png"
        XCTAssertEqual(UnusedMedia.find(in: p).map(\.path), ["/m/x.png"])
    }

    func testRemoveAllLeavesNothingAndKeepsUsed() {
        var p = Project()
        UnusedMedia.register(["/m/a.mp4", "/m/b.png", "/m/b.png", ""], in: &p)
        XCTAssertEqual(p.mediaPool, ["/m/a.mp4", "/m/b.png"], "重複と空は足さない")
        p.tracks[0].clips = [clip("1", .video, src: "/m/a.mp4")]
        UnusedMedia.removeAll(from: &p)
        XCTAssertTrue(UnusedMedia.find(in: p).isEmpty)
        XCTAssertEqual(p.mediaPool, ["/m/a.mp4"])
    }

    func testRemoveOneRefusesUsed() {
        var p = Project()
        p.mediaPool = ["/m/a.mp4", "/m/b.png"]
        p.tracks[0].clips = [clip("1", .video, src: "/m/a.mp4")]
        UnusedMedia.remove(["/m/a.mp4", "/m/b.png"], from: &p)
        XCTAssertEqual(p.mediaPool, ["/m/a.mp4"])
    }

    func testPoolRoundTripOnlyWhenNonEmpty() throws {
        let enc = JSONEncoder()
        let empty = String(data: try enc.encode(Project()), encoding: .utf8)!
        XCTAssertFalse(empty.contains("mediaPool"))
        var p = Project(); p.mediaPool = ["/m/a.mp4"]
        let back = try JSONDecoder().decode(Project.self, from: try enc.encode(p))
        XCTAssertEqual(back.mediaPool, ["/m/a.mp4"])
    }
}
