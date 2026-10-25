import XCTest
@testable import MovieCutCore

final class ProjectTests: XCTestCase {
    func fixture(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "ymproj", subdirectory: "Fixtures"))
    }

    func testRichRoundTripKeepsEverything() throws {
        let p1 = try Project.load(from: fixture("rich"))
        let types = Set(p1.allClips.map { $0.type.rawValue })
        XCTAssertTrue(types.isSuperset(of: ["image", "video", "audio", "text", "voice", "blur", "hologram"]))
        XCTAssertEqual(p1.allClips.filter { $0.shape == "ellipse" }.count, 1)
        XCTAssertEqual(p1.tracks[1].muted, true)
        XCTAssertEqual(p1.tracks[2].hidden, true)
        XCTAssertEqual(Set(p1.characters.map { $0.engine }), ["voicevox", "aquestalk"])

        let p2 = try Project.decode(from: p1.encoded())
        XCTAssertEqual(p1, p2)

        // 未知キーが全レベルで残る
        XCTAssertNotNil(p2.extra["futureProjectKey"])
        XCTAssertNotNil(p2.characters[0].extra["futureCharKey"])
        XCTAssertNotNil(p2.tracks[0].extra["futureTrackKey"])
        XCTAssertEqual(p2.tracks[0].clips[0].extra["futureClipKey"], .string("keep"))
        XCTAssertEqual(p2.tracks[2].clips[4].type.rawValue, "hologram")
        XCTAssertEqual(p2.tracks[2].clips[4].extra["weird"], .bool(true))

        // 書き出した JSON にも文字列として残っている
        let s = String(decoding: try p1.encoded(), as: UTF8.self)
        for k in ["futureProjectKey", "futureCharKey", "futureTrackKey", "futureClipKey"] { XCTAssertTrue(s.contains(k), k) }
    }

    func testEmptyObjectEqualsNewDefaults() throws {
        let p = try Project.decode(from: Data("{}".utf8))
        let n = Project.new()
        XCTAssertEqual([p.width, p.height, p.fps], [1920, 1080, 60])
        XCTAssertEqual(p.bg, "#000000"); XCTAssertEqual(p.codec, "h264")
        XCTAssertEqual(p.voicevoxUrl, "http://127.0.0.1:50021")
        XCTAssertEqual(p.aquestalkCommand, n.aquestalkCommand)
        XCTAssertEqual(p.characters.map { $0.name }, ["霊夢", "魔理沙", "ずんだもん"])
        XCTAssertEqual(p.characters.map { $0.engine }, ["aquestalk", "aquestalk", "voicevox"])
        XCTAssertEqual(p.characters.map { $0.flip }, [true, false, false])
        XCTAssertEqual(p.characters.map { $0.x }, [0.18, 0.82, 0.82])
        XCTAssertEqual(p.tracks.map { $0.name }, (1...5).map { "レイヤー\($0)" })
        XCTAssertTrue(p.tracks.allSatisfy { $0.clips.isEmpty })
        XCTAssertTrue(p.extra.isEmpty)
    }

    func testLenientTypesAndPartialObjects() throws {
        let json = #"{"fps":30.0,"width":"bad","characters":[{}],"tracks":[{"clips":[{"type":"text"}]}]}"#
        let p = try Project.decode(from: Data(json.utf8))
        XCTAssertEqual(p.fps, 30); XCTAssertEqual(p.width, 1920)
        XCTAssertEqual(p.characters.count, 1); XCTAssertEqual(p.characters[0].color, "#4f8cff")
        XCTAssertEqual(p.tracks[0].clips[0].type, .text)
        XCTAssertEqual(p.tracks[0].clips[0].fontSizeOrDefault, 80)
    }

    func testElectronMadeProjectDecodes() throws {
        let p = try Project.load(from: fixture("electron-made"))
        XCTAssertEqual(p.width, 3840); XCTAssertEqual(p.height, 2160); XCTAssertEqual(p.codec, "hevc")
        XCTAssertEqual(p.characters.count, 3)
        XCTAssertFalse(p.tracks.isEmpty)
        XCTAssertEqual(try Project.decode(from: p.encoded()), p)
    }

    func testScaledForResolution() throws {
        var p = Project.new()
        var text = Clip(); text.type = .text; text.fontSize = 96; text.blur = 10
        var voice = Clip(); voice.type = .voice; voice.fontSize = 64
        var region = Clip(); region.type = .blur; region.strength = 24
        p.tracks[0].clips = [text, voice, region]

        let k4 = p.scaledForResolution(newWidth: 3840, newHeight: 2160)
        XCTAssertEqual(k4.width, 3840)
        let c4 = k4.tracks[0].clips
        XCTAssertEqual(c4[0].fontSize, 192); XCTAssertEqual(c4[0].blur, 20)
        XCTAssertEqual(c4[1].fontSize, 128); XCTAssertEqual(c4[2].strength, 48)

        let portrait = p.scaledForResolution(newWidth: 1080, newHeight: 1920)
        let k = (1080.0 * 1920 / (1920 * 1080)).squareRoot()
        XCTAssertEqual(k, 1.0, accuracy: 1e-9)
        XCTAssertEqual(portrait.tracks[0].clips[0].fontSize, 96)

        let tiny = p.scaledForResolution(newWidth: 192, newHeight: 108)
        XCTAssertEqual(tiny.tracks[0].clips[0].fontSize, 10) // 96*0.1=9.6 → 10
        XCTAssertGreaterThanOrEqual(tiny.tracks[0].clips[1].fontSize ?? 0, 8)
    }

    func testSaveLoadFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ye-\(UUID().uuidString).ymproj")
        defer { try? FileManager.default.removeItem(at: url) }
        let p = Project.new()
        try p.save(to: url)
        XCTAssertEqual(try Project.load(from: url), p)
    }
}
