import XCTest
@testable import MovieCutCore

/// 形式の版(`formatVersion`)と、新しい版のファイルを開いたときの保持・バックアップ。
final class ProjectFormatTests: XCTestCase {
    private func json(_ p: Project) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: p.encoded()) as? [String: Any])
    }

    func testNewProjectWritesCurrentVersion() throws {
        XCTAssertEqual(try json(.new())["formatVersion"] as? Int, ProjectFormat.current)
        XCTAssertEqual(ProjectFormat.current, 1)
    }

    func testLegacyFileWithoutTheFieldIsVersionZeroAndLoadsAsBefore() throws {
        let data = Data(#"{"width":1280,"height":720,"fps":30}"#.utf8)
        XCTAssertEqual(ProjectFormat.version(in: data), 0)
        let p = try Project.decode(from: data)
        XCTAssertEqual(p.sourceFormat.value, 0)
        XCTAssertFalse(p.isNewerFormat)
        XCTAssertEqual(p.width, 1280)
        XCTAssertNil(p.extra["formatVersion"])
        XCTAssertEqual(try json(p)["formatVersion"] as? Int, 1, "保存すると現在の版を書く")
    }

    func testVersionReadingIsStrict() {
        func v(_ s: String) -> Int { ProjectFormat.version(in: Data(s.utf8)) }
        XCTAssertEqual(v(#"{"formatVersion":3}"#), 3)
        XCTAssertEqual(v(#"{"formatVersion":-1}"#), 0)
        XCTAssertEqual(v(#"{"formatVersion":"2"}"#), 0)
        XCTAssertEqual(v(#"{"formatVersion":true}"#), 0)
        XCTAssertEqual(v(#"{"formatVersion":1e300}"#), 0)
        XCTAssertEqual(v("[1]"), 0)
        XCTAssertEqual(v("broken"), 0)
    }

    func testNewerVersionIsDetectedStillLoadsAndKeepsItsVersionOnSave() throws {
        let data = Data(#"{"formatVersion":7,"width":640,"height":360}"#.utf8)
        XCTAssertTrue(ProjectFormat.isNewer(ProjectFormat.version(in: data)))
        let p = try Project.decode(from: data)
        XCTAssertTrue(p.isNewerFormat)
        XCTAssertEqual(p.width, 640)
        XCTAssertEqual(try json(p)["formatVersion"] as? Int, 7, "新しい版の印は下げない")
        XCTAssertFalse(try Project.decode(from: p.encoded()).extra.keys.contains("formatVersion"))
    }

    func testSourceVersionDoesNotAffectEquality() throws {
        let b = Project.new(); var a = b; a.sourceFormat = SourceFormatVersion(5)
        XCTAssertEqual(a, b)
    }

    /// 保持される階層: 最上位・キャラクター・レイヤー(Track)・クリップ・マーカー・立ち絵・エフェクト・トランジション ほか(Lenient/extra を持つ型)。
    func testUnknownKeysArePreservedAtTopCharacterTrackClipAndMarkerLevels() throws {
        let src = """
        {"formatVersion":9,"futureTop":{"a":[1,2,{"b":null}]},
         "characters":[{"id":"c1","name":"x","futureChar":"cv"}],
         "markers":[{"id":"m1","time":1,"name":"m","futureMarker":true}],
         "tracks":[{"id":"t1","name":"L","futureTrack":1.5,"clips":[
            {"id":"k1","type":"text","start":0,"duration":1,"text":"hi","futureClip":{"z":"y"},
             "effects":[{"type":"blur","futureEffect":3}]}]}]}
        """
        let p = try Project.decode(from: Data(src.utf8))
        let out = try json(try Project.decode(from: p.encoded()))
        XCTAssertNotNil(out["futureTop"])
        XCTAssertEqual((out["characters"] as? [[String: Any]])?.first?["futureChar"] as? String, "cv")
        XCTAssertEqual((out["markers"] as? [[String: Any]])?.first?["futureMarker"] as? Bool, true)
        let track = try XCTUnwrap((out["tracks"] as? [[String: Any]])?.first)
        XCTAssertEqual(track["futureTrack"] as? Double, 1.5)
        let clip = try XCTUnwrap((track["clips"] as? [[String: Any]])?.first)
        XCTAssertNotNil(clip["futureClip"])
        XCTAssertEqual((clip["effects"] as? [[String: Any]])?.first?["futureEffect"] as? Int, 3)
        // 入れ子の中身も、そのまま
        let top = try XCTUnwrap(out["futureTop"] as? [String: Any])
        XCTAssertEqual((top["a"] as? [Any])?.count, 3)
    }

    /// 保持されない階層(知らないキーを持たない型): クリップの crop・keyframes・speedRamp、bubble、mediaHints の値、multicams。
    /// ここを「保持される」と言わないための確認(将来それらに extra を足したら、このテストを更新する)。
    func testUnknownKeysInTypesWithoutExtraAreNotPreserved() throws {
        let src = #"{"formatVersion":9,"tracks":[{"id":"t","name":"L","clips":[{"id":"k","type":"image","start":0,"duration":1,"crop":{"l":0.1,"futureCrop":1},"bubble":{"futureBubble":1}}]}]}"#
        let out = String(decoding: try Project.decode(from: Data(src.utf8)).encoded(), as: UTF8.self)
        XCTAssertFalse(out.contains("futureCrop"))
        XCTAssertFalse(out.contains("futureBubble"))
    }

    func testBackupKeepsOriginalAndIsNotReplacedByTheSavedCopy() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("fmt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let loc = DataLocations(edition: .personal, applicationSupport: tmp)
        let url = tmp.appendingPathComponent("doc.mcpjc")
        let original = Data(#"{"formatVersion":9,"futureTop":1}"#.utf8)
        let saving = Data(#"{"formatVersion":9}"#.utf8)
        try ProjectFormat.backupOriginalBeforeFirstSave(original: original, saving: saving, projectURL: url, locations: loc)
        let gens = ProjectVersions.list(for: url, in: loc)
        XCTAssertEqual(gens.count, 2, "元の中身と保存した中身の 2 世代(間隔による置き換えをしない)")
        let datas = try gens.map { try Data(contentsOf: $0.url) }
        XCTAssertTrue(datas.contains(original))
        XCTAssertTrue(datas.contains(saving))
    }

    func testBackupFailureThrows() {
        let loc = DataLocations(edition: .personal, applicationSupport: URL(fileURLWithPath: "/dev/null/nope"))
        XCTAssertThrowsError(try ProjectFormat.backupOriginalBeforeFirstSave(original: Data("{}".utf8), saving: Data("{}".utf8), projectURL: URL(fileURLWithPath: "/tmp/x.mcpjc"), locations: loc))
    }
}
