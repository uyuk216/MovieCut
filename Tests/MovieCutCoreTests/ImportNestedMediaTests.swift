import XCTest
@testable import MovieCutCore

/// C21(インポート/素材まわり): 入れ子素材の収集・再リンク適用、相対パスの優先順位、
/// 巨大な数値での変換クラッシュ、IsHidden の往復、世代の間隔判定の固定。
final class ImportNestedMediaTests: XCTestCase {

    private func tempFile(_ name: String, _ bytes: [UInt8] = [1, 2, 3]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("c21-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let u = dir.appendingPathComponent(name)
        try Data(bytes).write(to: u)
        return u
    }

    private func nestedProject(src: String) -> Project {
        var inner = Clip(); inner.type = .video; inner.src = src; inner.start = 0; inner.duration = 5
        var comp = Clip(); comp.type = .compound; comp.start = 0; comp.duration = 5
        var tr = Track(); tr.clips = [inner]; comp.tracks = [tr]
        var top = Track(); top.clips = [comp]
        var p = Project(); p.tracks = [top]
        return p
    }

    func testPackageCollectsNestedMedia() throws {
        let f = try tempFile("nested.mp4")
        let plan = MediaPackage.plan(nestedProject(src: f.path))
        XCTAssertEqual(plan.copies.map(\.from), [f.path], "複合の内側の素材もコピー対象になる")
        let inner = plan.project.tracks[0].clips[0].tracks![0].clips[0]
        XCTAssertEqual(inner.src, "media/nested.mp4")
        XCTAssertNotNil(plan.project.mediaHints["media/nested.mp4"], "ヒントはパッケージ後のパスがキー")
    }

    func testRelinkApplyingRewritesNestedAndMovesKeys() {
        var p = nestedProject(src: "/old/a.mp4")
        p.mediaFingerprints["/old/a.mp4"] = MediaFingerprint(fileName: "a.mp4", size: 3, sha256: "x")
        let out = MediaRelinker.applying(["/old/a.mp4": "/new/a.mp4"], to: p)
        XCTAssertEqual(out.tracks[0].clips[0].tracks![0].clips[0].src, "/new/a.mp4")
        XCTAssertNotNil(out.mediaFingerprints["/new/a.mp4"])
        XCTAssertNil(out.mediaFingerprints["/old/a.mp4"])
    }

    func testRelativeSrcPrefersProjectFolder() {
        let got = MediaResolver.resolve(src: "media/a.mp4", projectDir: "/proj", exists: { _ in true })
        XCTAssertEqual(got, "/proj/media/a.mp4", "作業フォルダの同名ファイルよりプロジェクト相対を優先")
    }

    func testReferencedSourcesIncludeSceneOnlyMedia() {
        var c = Clip(); c.type = .video; c.src = "/scene-only.mp4"; c.start = 0; c.duration = 1
        var tr = Track(); tr.clips = [c]
        var p = Project(); p.tracks = []
        p.scenes = [SceneDefinition(id: "s1", name: "S", tracks: [tr])]
        XCTAssertTrue(MediaFingerprintCollector.referencedSources(in: p).contains("/scene-only.mp4"))
    }

    func testFingerprintChunkSizeZeroReturnsNil() throws {
        let f = try tempFile("x.bin")
        XCTAssertNil(MediaFingerprint.compute(url: f, chunkSize: 0))
        XCTAssertNotNil(MediaFingerprint.compute(url: f, chunkSize: 2))
    }

    func testYmmpExportWithNonFiniteValuesStillProducesProject() {
        var c = Clip(); c.type = .text; c.text = "x"; c.start = 0; c.duration = 1; c.fontSize = .nan
        var tr = Track(); tr.clips = [c]
        var p = Project(); p.tracks = [tr]
        let out = YmmpExporter.export(project: p)
        XCTAssertNotEqual(String(data: out.data, encoding: .utf8), "{}")
        XCTAssertFalse(out.report.notes.isEmpty, "直したことをレポートに残す")
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: out.data))
    }

    func testYmmpExportExtremeConversionsDoNotTrap() {
        XCTAssertEqual(YmmpExporter.frame(1e19, fps: 30), Int.max)
        XCTAssertFalse(YmmpExporter.timeSpanString(1e12).isEmpty)
    }

    func testYmmpImportIntClampsHugeValues() {
        XCTAssertEqual(YmmpImporter.int(NSNumber(value: 1e30)), Int.max)
        XCTAssertEqual(YmmpImporter.int(NSNumber(value: -1e30)), Int.min)
        XCTAssertEqual(YmmpImporter.int(NSNumber(value: 42.9)), 42)
    }

    func testYmmpImportHonorsIsHiddenAndExplicitVisible() throws {
        func convert(jimaku: String, hidden: Bool, charJimaku: Bool) throws -> Clip {
            let json = """
            {"Characters":[{"Name":"キャラ","IsJimakuVisible":\(charJimaku)}],
             "Timelines":[{"Name":"t","VideoInfo":{"FPS":30},"Items":[
               {"$type":"YukkuriMovieMaker.Project.Items.VoiceItem, YukkuriMovieMaker",
                "Frame":0,"Length":30,"Layer":0,"IsHidden":\(hidden),"CharacterName":"キャラ",
                "Serif":"テスト","Hatsuon":"テスト","JimakuVisibility":"\(jimaku)"}]}]}
            """
            let out = try YmmpImporter.convert(data: Data(json.utf8))
            return try XCTUnwrap(out.project.allClips.first)
        }
        let hiddenClip = try convert(jimaku: "UseCharacterSetting", hidden: true, charJimaku: true)
        XCTAssertTrue(hiddenClip.isDisabled, "IsHidden は無効化として読み込む")
        let visibleClip = try convert(jimaku: "Visible", hidden: false, charJimaku: false)
        XCTAssertEqual(visibleClip.subtitle, true, "明示の Visible はキャラクター設定に勝つ")
    }

    func testVersionsIntervalAnchorsAtGenerationCreation() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("c21v-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let locations = DataLocations(edition: .personal, applicationSupport: tmp.appendingPathComponent("support"))
        let u = tmp.appendingPathComponent("proj.mcpjc")
        let t0 = Date(timeIntervalSince1970: 1_793_000_000)
        _ = try ProjectVersions.record(data: Data("v1".utf8), projectURL: u, now: t0, locations: locations, minInterval: 60)
        let r2 = try ProjectVersions.record(data: Data("v2".utf8), projectURL: u, now: t0.addingTimeInterval(30), locations: locations, minInterval: 60)
        guard case .replaced = r2 else { return XCTFail("30秒後は置き換えのはず: \(r2)") }
        let r3 = try ProjectVersions.record(data: Data("v3".utf8), projectURL: u, now: t0.addingTimeInterval(75), locations: locations, minInterval: 60)
        guard case .added = r3 else { return XCTFail("最初の保存から75秒経てば新しい世代になるはず: \(r3)") }
    }

    func testTemplateWithoutCharactersClearsDanglingCharIds() {
        var ch = MovieCutCore.Character(); ch.name = "自作キャラ"; ch.id = "custom-1"
        var voice = Clip(); voice.type = .voice; voice.charId = "custom-1"; voice.start = 0; voice.duration = 1
        var tr = Track(); tr.clips = [voice]
        var p = Project(); p.characters = [ch]; p.tracks = [tr]
        let t = ProjectTemplate.make(from: p, parts: [.layers])
        XCTAssertNil(t.allClips.first?.charId, "残らないキャラクターへの参照は外す")
    }

    func testSVGImportAllowsNewlineBeforeAttributes() {
        let svg = "<svg\n  width=\"640\"\n  height=\"360\"></svg>"
        let info = SVGParser.parseInfo(svg)
        XCTAssertNotNil(info)
        XCTAssertEqual(info?.width, 640)
    }
}
