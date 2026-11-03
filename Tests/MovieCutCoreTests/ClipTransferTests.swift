import XCTest
@testable import MovieCutCore

/// 選んだクリップを、元の配置を残して別のプロジェクトへ複製する(候補 37)。
final class ClipTransferTests: XCTestCase {
    private func source() -> Project {
        var p = Project()
        p.width = 1280; p.height = 720; p.fps = 30; p.bg = "#222222"
        p.markers = [Marker(time: 1, name: "m")]
        p.rangeIn = 1; p.rangeOut = 5
        p.tracks[0].name = "背景"; p.tracks[2].name = "セリフ"; p.tracks[2].locked = true; p.tracks[2].muted = true
        var img = Clip(); img.id = "img"; img.type = .image; img.src = "/m/a.png"; img.start = 4; img.duration = 3
        var unrelated = Clip(); unrelated.id = "un"; unrelated.type = .image; unrelated.src = "/m/z.png"; unrelated.start = 0; unrelated.duration = 1
        var v = Clip(); v.id = "voice"; v.type = .voice; v.text = "こんにちは"; v.charId = p.characters[1].id; v.src = "/m/v.wav"; v.start = 5; v.duration = 2
        p.tracks[0].clips = [img, unrelated]
        p.tracks[2].clips = [v]
        p.mediaPool = ["/m/z.png", "/m/a.png", "/m/v.wav"]
        return p
    }

    func testExtractKeepsLayersTimesSettingsAndOnlyUsedThings() throws {
        let s = source()
        let pk = try XCTUnwrap(ClipTransfer.extract(from: s, clipIds: ["img", "voice"]))
        let p = pk.project
        XCTAssertEqual(pk.copied, 2)
        XCTAssertEqual(p.tracks.count, 3, "選んだクリップのある一番下のレイヤーまで")
        XCTAssertEqual(p.tracks.map(\.name), ["背景", s.tracks[1].name, "セリフ"])
        XCTAssertNil(p.tracks[2].locked, "ロックは写さない")
        XCTAssertEqual(p.tracks[2].muted, true)
        XCTAssertEqual(p.tracks[0].clips.map(\.id), ["img"], "選んでいないクリップは入れない")
        XCTAssertEqual(p.tracks[0].clips[0].start, 4); XCTAssertEqual(p.tracks[2].clips[0].start, 5)
        XCTAssertEqual([p.width, p.height], [1280, 720]); XCTAssertEqual(p.fps, 30); XCTAssertEqual(p.bg, "#222222")
        XCTAssertEqual(p.characters.map(\.name), [s.characters[1].name], "ボイスが使うキャラクターだけ")
        XCTAssertEqual(p.mediaPool, ["/m/a.png", "/m/v.wav"])
        XCTAssertTrue(p.markers.isEmpty); XCTAssertNil(p.rangeIn)
        // 元は変えない・書き出して読み直せる
        XCTAssertEqual(s.allClips.count, 3)
        XCTAssertEqual(try Project.decode(from: try p.encoded()), p)
    }

    func testExtractWithoutVoiceKeepsDefaultCharacters() throws {
        let pk = try XCTUnwrap(ClipTransfer.extract(from: source(), clipIds: ["img"]))
        XCTAssertEqual(pk.project.characters.map(\.name), Character.defaults().map(\.name))
        XCTAssertEqual(pk.project.tracks.count, 1)
    }

    func testExtractRefusesEmpty() {
        XCTAssertNil(ClipTransfer.extract(from: source(), clipIds: []))
        XCTAssertNil(ClipTransfer.extract(from: source(), clipIds: ["nope"]))
    }

    func testInsertKeepsTimesAndLayersWithFreshIds() throws {
        let pk = try XCTUnwrap(ClipTransfer.extract(from: source(), clipIds: ["img", "voice"]))
        var dest = Project()
        var existing = Clip(); existing.id = "e"; existing.type = .image; existing.start = 0; existing.duration = 2
        dest.tracks[1].clips = [existing]
        let r = try XCTUnwrap(ClipTransfer.insert(from: pk.project, into: dest))
        XCTAssertEqual(r.newIds.count, 2)
        XCTAssertFalse(r.newIds.contains("img")); XCTAssertFalse(r.newIds.contains("voice"))
        XCTAssertEqual(r.project.tracks[0].clips.map(\.start), [4])
        XCTAssertEqual(r.project.tracks[2].clips.map(\.start), [5])
        XCTAssertEqual(r.project.tracks[1].clips.map(\.id), ["e"], "他のクリップは動かさない")
        XCTAssertEqual(r.project.mediaPool, ["/m/a.png", "/m/v.wav"])
        XCTAssertEqual(r.addedCharacters, 0, "既定のキャラクターは同じ id なので足さない")
        XCTAssertEqual(r.skipped, 0)
    }

    func testInsertOverlapMovesToNextFreeLayerAndAddsLayers() throws {
        let pk = try XCTUnwrap(ClipTransfer.extract(from: source(), clipIds: ["img"]))
        var dest = Project()
        var busy = Clip(); busy.id = "busy"; busy.type = .image; busy.start = 3; busy.duration = 4
        dest.tracks[0].clips = [busy]
        let r = try XCTUnwrap(ClipTransfer.insert(from: pk.project, into: dest))
        XCTAssertEqual(r.project.tracks[0].clips.map(\.id), ["busy"])
        XCTAssertEqual(r.project.tracks[1].clips.map(\.start), [4], "重なるので次のレイヤー、時刻は同じ")
        // 全部ふさがっていたら足す
        var full = Project()
        full.tracks = [Track(name: "a")]
        full.tracks[0].clips = [busy]
        let r2 = try XCTUnwrap(ClipTransfer.insert(from: pk.project, into: full))
        XCTAssertEqual(r2.project.tracks.count, 2)
    }

    func testInsertMapsCharactersByNameAndAddsUnknown() throws {
        var src = source()
        src.characters[1].id = "src-marisa"
        src.tracks[2].clips[0].charId = "src-marisa"
        let pk = try XCTUnwrap(ClipTransfer.extract(from: src, clipIds: ["voice"]))
        var dest = Project()
        let destMarisa = dest.characters[1]
        let r = try XCTUnwrap(ClipTransfer.insert(from: pk.project, into: dest))
        XCTAssertEqual(r.addedCharacters, 0)
        let voiceClip = try XCTUnwrap(r.project.allClips.first { $0.type == .voice })
        XCTAssertEqual(voiceClip.charId, destMarisa.id, "同じ名前・エンジンのキャラへ対応づける")
        dest.characters.remove(at: 1)
        let r2 = try XCTUnwrap(ClipTransfer.insert(from: pk.project, into: dest))
        XCTAssertEqual(r2.addedCharacters, 1)
        XCTAssertEqual(r2.project.allClips.first { $0.type == .voice }?.charId, "src-marisa")
        XCTAssertTrue(r2.project.characters.contains { $0.id == "src-marisa" })
    }

    func testInsertSkipsLockedLayersAndNothingToInsertIsNil() throws {
        let pk = try XCTUnwrap(ClipTransfer.extract(from: source(), clipIds: ["img"]))
        var dest = Project()
        dest.tracks[0].locked = true
        XCTAssertNil(ClipTransfer.insert(from: pk.project, into: dest), "行き先がロックだけ → 入れられない")
        XCTAssertNil(ClipTransfer.insert(from: Project(), into: Project()))
    }
}
