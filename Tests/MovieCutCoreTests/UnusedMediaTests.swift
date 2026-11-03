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

/// 編集で使われなくなった素材を素材リストに覚える(mediaPool ができる前の書類で消したクリップの続き)。
final class UnusedMediaAdoptTests: XCTestCase {
    private func clip(_ id: String, _ type: ClipType, _ src: String?) -> Clip {
        var c = Clip(); c.id = id; c.type = type; c.src = src; c.duration = 1
        return c
    }
    private func project(_ clips: [Clip]) -> Project { var p = Project.new(); p.tracks[0].clips = clips; return p }

    func testRemovedClipSourceBecomesUnused() {
        let old = project([clip("a", .video, "/m/a.mp4"), clip("b", .image, "/m/b.png")])
        var new = old; new.tracks[0].clips.removeAll { $0.id == "a" }
        XCTAssertTrue(old.mediaPool.isEmpty)
        UnusedMedia.adoptRemoved(from: old, into: &new)
        XCTAssertEqual(UnusedMedia.find(in: new).map(\.path), ["/m/a.mp4"])
    }

    func testStillUsedVoiceTextAndNoChangeAddNothing() {
        let old = project([clip("a", .video, "/m/a.mp4"), clip("a2", .video, "/m/a.mp4"), clip("v", .voice, "/cache/v.wav"), clip("t", .text, nil)])
        var new = old; new.tracks[0].clips.removeAll { $0.id == "a" || $0.id == "v" || $0.id == "t" }
        UnusedMedia.adoptRemoved(from: old, into: &new)
        XCTAssertTrue(new.mediaPool.isEmpty, "同じ素材を使う別のクリップが残り、声と文字は対象外")
        var same = old
        UnusedMedia.adoptRemoved(from: old, into: &same)
        XCTAssertEqual(same, old)
    }

    func testAlreadyPooledIsNotDuplicatedAndOldFilesStayByteIdentical() throws {
        var old = project([clip("a", .audio, "/m/a.wav")]); old.mediaPool = ["/m/a.wav"]
        var new = old; new.tracks[0].clips = []
        UnusedMedia.adoptRemoved(from: old, into: &new)
        XCTAssertEqual(new.mediaPool, ["/m/a.wav"])
        // 何も消さなければ、書き出した JSON に mediaPool は出ない(任意項目は既定値のとき書かない)
        let plain = project([clip("a", .audio, "/m/a.wav")])
        var same = plain; UnusedMedia.adoptRemoved(from: plain, into: &same)
        XCTAssertFalse(String(decoding: try same.encoded(), as: UTF8.self).contains("mediaPool"))
    }
}
