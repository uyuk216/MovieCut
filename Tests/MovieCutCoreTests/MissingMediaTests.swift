import XCTest
@testable import MovieCutCore

/// 書き出し前の素材チェックと、場所の再指定(存在の判定は引数で差し替える)。
final class MissingMediaTests: XCTestCase {
    private func clip(_ type: ClipType, _ src: String?) -> Clip {
        var c = Clip(); c.type = type; c.src = src; c.duration = 1; return c
    }

    private func project() -> Project {
        var p = Project.new()
        var a = Track(name: "映像"); a.clips = [clip(.video, "/m/a.mp4"), clip(.image, "/m/ok.png")]
        var b = Track(name: "音"); b.clips = [clip(.audio, "/old/b.wav"), clip(.text, nil)]
        p.tracks = [a, b]
        return p
    }

    private let present: Set<String> = ["/m/ok.png", "/new/a.mp4", "/new/b.wav"]
    private func exists(_ s: String) -> Bool { present.contains(s) }

    func testFindsOnlyMissingFilesWithSrc() {
        let items = MissingMedia.find(in: project(), exists: exists)
        XCTAssertEqual(items.map(\.path), ["/m/a.mp4", "/old/b.wav"])
        XCTAssertEqual(items.map(\.trackName), ["映像", "音"])
        XCTAssertEqual(items[0].fileName, "a.mp4")
    }

    func testNothingMissingIsEmpty() {
        XCTAssertTrue(MissingMedia.find(in: Project.new(), exists: exists).isEmpty)
    }

    func testBlockMessageNamesFilesAndCountsRest() {
        let many = (0..<7).map { MissingMedia.Item(clipId: "\($0)", trackName: "L", path: "/x/f\($0).png") }
        let msg = MissingMedia.blockMessage(many)
        XCTAssertTrue(msg.hasPrefix("素材が見つからないため書き出せません"))
        XCTAssertTrue(msg.contains("f0.png"))
        XCTAssertFalse(msg.contains("f5.png"))
        XCTAssertTrue(msg.hasSuffix("ほか 2 件"))
    }

    func testRelinkReplacesByFileNameAndReportsRest() {
        let r = MissingMedia.relink(project(), index: ["a.mp4": "/new/a.mp4", "b.wav": "/new/b.wav"], exists: exists)
        XCTAssertEqual(r.relinked, 2)
        XCTAssertEqual(r.stillMissing, 0)
        XCTAssertEqual(r.project.tracks[0].clips[0].src, "/new/a.mp4")
        XCTAssertEqual(r.project.tracks[1].clips[0].src, "/new/b.wav")
        XCTAssertEqual(r.project.tracks[0].clips[1].src, "/m/ok.png", "存在する素材は触らない")
    }

    func testRelinkWithoutMatchLeavesProjectUnchanged() {
        let base = project()
        let r = MissingMedia.relink(base, index: ["zzz.mp4": "/new/zzz.mp4"], exists: exists)
        XCTAssertEqual(r.relinked, 0)
        XCTAssertEqual(r.stillMissing, 2)
        XCTAssertEqual(r.project, base)
    }

    func testFindsAndRelinksInsideCompoundsAndScenes() {
        // 複合クリップの中と、配置されているシーンの中の欠損も検出・再リンクの対象。
        // (従来は一番上のクリップしか見ず、書き出し前のチェックを通過していた)
        var p = Project.new()
        var inner = Track(name: "内側"); inner.clips = [clip(.video, "/m/inner.mp4")]
        var comp = clip(.compound, nil); comp.tracks = [inner]
        var sceneClip = clip(.scene, nil); sceneClip.sceneId = "s1"
        var main = Track(name: "主"); main.clips = [comp, sceneClip]
        p.tracks = [main]
        var st = Track(name: "場面の映像"); st.clips = [clip(.video, "/m/scene.mp4")]
        p.scenes = [SceneDefinition(id: "s1", name: "場面1", tracks: [st])]

        let items = MissingMedia.find(in: p, exists: exists)
        XCTAssertEqual(Set(items.map(\.path)), ["/m/inner.mp4", "/m/scene.mp4"])

        let r = MissingMedia.relink(p, index: ["inner.mp4": "/new/a.mp4", "scene.mp4": "/new/b.wav"], exists: exists)
        XCTAssertEqual(r.relinked, 2)
        XCTAssertEqual(r.stillMissing, 0)
        XCTAssertEqual(r.project.tracks[0].clips[0].tracks?[0].clips[0].src, "/new/a.mp4")
        XCTAssertEqual(r.project.scenes[0].tracks[0].clips[0].src, "/new/b.wav")
    }
}
