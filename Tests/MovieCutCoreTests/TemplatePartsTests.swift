import XCTest
@testable import MovieCutCore

/// テンプレートに含める項目を選ぶ(候補 32)。
final class TemplatePartsTests: XCTestCase {
    private func sample() -> Project {
        var p = Project()
        p.width = 1280; p.height = 720; p.fps = 30; p.bg = "#112233"; p.codec = "hevc"
        p.voicevoxUrl = "http://example.test:1"
        p.markers = [Marker(time: 1.5, name: "サビ")]
        p.characters[0].name = "改名"
        var a = Clip(); a.id = "a"; a.type = .image; a.start = 0; a.duration = 2
        var b = Clip(); b.id = "b"; b.type = .text; b.start = 2; b.duration = 1
        var l1 = Track(name: "映像"); l1.clips = [a]; l1.locked = true
        var l2 = Track(name: "字幕"); l2.clips = [b]
        p.tracks = [l1, l2, Track(name: "空")]
        return p
    }

    func testStandardPartsMatchLegacyMake() throws {
        let p = sample()
        XCTAssertEqual(ProjectTemplate.make(from: p, parts: .standard), ProjectTemplate.make(from: p))
        XCTAssertEqual(try ProjectTemplate.make(from: p, parts: .standard).encoded(), try ProjectTemplate.make(from: p).encoded(), "従来どおりバイト一致")
    }

    func testSettingsOffResetsOnlySettings() {
        let t = ProjectTemplate.make(from: sample(), parts: [.characters, .layers, .markers])
        XCTAssertEqual([t.width, t.height], [1920, 1080])
        XCTAssertEqual(t.fps, 60); XCTAssertEqual(t.bg, "#000000"); XCTAssertEqual(t.codec, "h264")
        XCTAssertEqual(t.voicevoxUrl, Project().voicevoxUrl)
        XCTAssertEqual(t.characters[0].name, "改名")
        XCTAssertEqual(t.markers.count, 1)
        XCTAssertEqual(t.tracks.map(\.name), ["映像", "字幕", "空"])
    }

    func testCharactersAndMarkersOff() {
        let t = ProjectTemplate.make(from: sample(), parts: [.settings, .layers])
        XCTAssertEqual(t.characters.map(\.name), Character.defaults().map(\.name))
        XCTAssertTrue(t.markers.isEmpty)
        XCTAssertEqual(t.width, 1280)
    }

    func testLayersOffGivesDefaultLayers() {
        let t = ProjectTemplate.make(from: sample(), parts: [.settings, .characters, .markers])
        XCTAssertEqual(t.tracks.map(\.name), Track.defaultLayers().map(\.name))
        XCTAssertTrue(t.allClips.isEmpty)
    }

    func testChosenClipsAreKeptAndForceTheirLayers() {
        let t = ProjectTemplate.make(from: sample(), parts: [.settings], clipIds: ["b"])
        XCTAssertEqual(t.allClips.map(\.id), ["b"])
        XCTAssertEqual(t.tracks.count, 3, "レイヤーの並びは残す")
        XCTAssertEqual(t.tracks.map(\.name), ["レイヤー1", "レイヤー2", "レイヤー3"], "構成を含めないので名前は初期化")
        XCTAssertNil(t.tracks[0].locked, "ロックも初期化")
        XCTAssertEqual(t.tracks[1].clips.first?.id, "b")
    }

    func testChosenClipsWithLayersKeepStructure() {
        let t = ProjectTemplate.make(from: sample(), parts: .standard, clipIds: ["a"])
        XCTAssertEqual(t.allClips.map(\.id), ["a"])
        XCTAssertEqual(t.tracks[0].locked, true)
        XCTAssertEqual(t.tracks.map(\.name), ["映像", "字幕", "空"])
    }

    func testUnknownClipIdsKeepNothing() {
        let t = ProjectTemplate.make(from: sample(), parts: [.settings], clipIds: ["zzz"])
        XCTAssertEqual(t.tracks.map(\.name), Track.defaultLayers().map(\.name))
        XCTAssertTrue(t.allClips.isEmpty)
    }

    func testSourceProjectIsNotModified() {
        let p = sample()
        let copy = p
        _ = ProjectTemplate.make(from: p, parts: [], clipIds: ["a"])
        XCTAssertEqual(p, copy)
        XCTAssertEqual(p.allClips.count, 2)
    }

    func testStoreSavesChosenPartsAndLoadsBack() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tplparts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TemplateStore(directory: dir)
        let name = try store.save(sample(), as: "部分", parts: [.markers], clipIds: ["a"])
        let back = try store.load(name: name)
        XCTAssertEqual(back.width, 1920)
        XCTAssertEqual(back.markers.count, 1)
        XCTAssertEqual(back.allClips.map(\.id), ["a"])
        // 既定(parts なし)は従来の保存と同じ
        let legacy = try store.save(sample(), as: "従来")
        XCTAssertTrue(try store.load(name: legacy).allClips.isEmpty)
        XCTAssertEqual(try store.load(name: legacy).width, 1280)
    }
}
