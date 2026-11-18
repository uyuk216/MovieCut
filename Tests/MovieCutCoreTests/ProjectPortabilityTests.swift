import XCTest
@testable import MovieCutCore

final class ProjectPortabilityTests: XCTestCase {
    private var tmp: URL!
    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("portability-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        tmp = tmp.resolvingSymlinksInPath()
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private func norm(_ path: String?) -> String? { path.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } }

    private func write(_ name: String, _ text: String, in dir: URL) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let u = dir.appendingPathComponent(name)
        try Data(text.utf8).write(to: u)
        return u
    }

    private func projectWith(src: String) -> Project {
        var p = Project.new()
        var c = Clip(); c.type = .video; c.src = src; c.duration = 1
        var t = Track(name: "映像"); t.clips = [c]
        p.tracks = [t]
        return p
    }

    // MARK: - フィンガープリント

    func testFingerprintMatchesSameContentNotDifferentContent() throws {
        let a = try write("a.mp4", "hello-media", in: tmp)
        let b = try write("b.mp4", "hello-media", in: tmp)
        let c = try write("c.mp4", "other-media!", in: tmp)
        let fp = try XCTUnwrap(MediaFingerprint.compute(atPath: a.path))
        XCTAssertEqual(fp.fileName, "a.mp4")
        XCTAssertEqual(fp.size, Int64("hello-media".count))
        XCTAssertEqual(fp.sha256.count, 64)
        XCTAssertTrue(fp.matches(atPath: b.path), "中身が同じなら名前が違っても一致")
        XCTAssertFalse(fp.matches(atPath: c.path))
    }

    func testCollectorGathersReferencedSources() throws {
        let f = try write("clip.mp4", "data-1234", in: tmp)
        let p = projectWith(src: f.path)
        let fps = MediaFingerprintCollector.collect(from: p)
        XCTAssertEqual(fps.count, 1)
        XCTAssertEqual(fps[f.path]?.fileName, "clip.mp4")
        // 存在しない素材は集めない
        let p2 = projectWith(src: "/nope/missing.mp4")
        XCTAssertTrue(MediaFingerprintCollector.collect(from: p2).isEmpty)
    }

    // MARK: - 相対パス解決: フォルダごと移動しても見つかる

    func testRelativeResolutionAfterMovingProjectFolder() throws {
        let projDir = tmp.appendingPathComponent("MyProject")
        let media = try write("movie.mp4", "moved-media", in: projDir.appendingPathComponent("media"))
        _ = media
        let src = "media/movie.mp4"
        XCTAssertEqual(MediaResolver.resolve(src: src, projectDir: projDir.path),
                       projDir.appendingPathComponent("media/movie.mp4").path)
        // フォルダごと別の場所へ移動
        let movedDir = tmp.appendingPathComponent("Moved/MyProject")
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("Moved"), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: projDir, to: movedDir)
        XCTAssertEqual(MediaResolver.resolve(src: src, projectDir: movedDir.path),
                       movedDir.appendingPathComponent("media/movie.mp4").path,
                       "移動後もプロジェクト相対で見つかる")
    }

    func testAbsoluteUnderProjectDirCanBeRelativized() throws {
        let projDir = tmp.appendingPathComponent("Proj")
        let f = try write("x.mp4", "x", in: projDir.appendingPathComponent("sub"))
        XCTAssertEqual(MediaResolver.relativize(src: f.path, projectDir: projDir.path), "sub/x.mp4")
        XCTAssertNil(MediaResolver.relativize(src: "/elsewhere/x.mp4", projectDir: projDir.path))
        // 移動した絶対パス(旧場所を指す)でも、フォルダ名アンカーで新しい場所から解決できる
        let movedDir = tmp.appendingPathComponent("Elsewhere/Proj")
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("Elsewhere"), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: projDir, to: movedDir)
        XCTAssertEqual(MediaResolver.resolve(src: f.path, projectDir: movedDir.path),
                       movedDir.appendingPathComponent("sub/x.mp4").path)
    }

    func testResolverRejectsEscapingRelative() {
        XCTAssertNil(MediaResolver.resolve(src: "../outside.mp4", projectDir: tmp.path))
        XCTAssertNil(MediaResolver.resolve(src: "", projectDir: tmp.path))
    }

    // MARK: - 一括再リンク

    func testRelinkByHashEvenAfterRename() throws {
        let original = try write("original.mp4", "unique-content-42", in: tmp.appendingPathComponent("src"))
        let fp = try XCTUnwrap(MediaFingerprint.compute(atPath: original.path))
        let oldSrc = original.path
        // 名前を変えて別のフォルダへ
        let searchDir = tmp.appendingPathComponent("search")
        let renamed = try write("renamed-999.mp4", "unique-content-42", in: searchDir)
        let r = MediaRelinker.relink(missing: [oldSrc], fingerprints: [oldSrc: fp], candidateFolders: [searchDir])
        XCTAssertEqual(norm(r.mapping[oldSrc]), norm(renamed.path), "改名してもハッシュで再リンクできる")
        XCTAssertTrue(r.unresolved.isEmpty)
    }

    func testRelinkDoesNotMatchSameNameDifferentContent() throws {
        let original = try write("movie.mp4", "real-content", in: tmp.appendingPathComponent("src"))
        let fp = try XCTUnwrap(MediaFingerprint.compute(atPath: original.path))
        let searchDir = tmp.appendingPathComponent("search")
        // 同名・同サイズだが中身が違うファイルだけがある
        _ = try write("movie.mp4", "fake-content", in: searchDir) // "real-content" と同サイズ(12)
        XCTAssertEqual("real-content".count, "fake-content".count)
        let r = MediaRelinker.relink(missing: [original.path], fingerprints: [original.path: fp], candidateFolders: [searchDir])
        XCTAssertTrue(r.mapping.isEmpty, "同名・同サイズでも中身が違えば誤リンクしない(ハッシュ優先で不一致、名前+サイズでもハッシュありの場合は付けない)")
        XCTAssertEqual(r.unresolved, [original.path])
    }

    func testRelinkDoesNotMatchWhenHashUnreadable() throws {
        // フィンガープリントがあるのに候補のハッシュが読めない場合は、
        // 同名・同サイズでも安全側に倒してつながない(仕様01 R-03)
        let original = try write("movie.mp4", "real-content", in: tmp.appendingPathComponent("src"))
        let fp = try XCTUnwrap(MediaFingerprint.compute(atPath: original.path))
        let searchDir = tmp.appendingPathComponent("search")
        _ = try write("movie.mp4", "real-content", in: searchDir)
        let r = MediaRelinker.relink(missing: [original.path], fingerprints: [original.path: fp],
                                     candidateFolders: [searchDir],
                                     compute: { _ in nil })
        XCTAssertTrue(r.mapping.isEmpty, "ハッシュを確認できない候補はつながない")
        XCTAssertEqual(r.unresolved, [original.path])
    }

    func testRelinkByNameAndSizeWithoutFingerprintUsesHint() throws {
        // フィンガープリントが無いプロジェクトでは、目印(MediaHint)のサイズを使い
        // ファイル名+サイズ一致で再リンクする(後方互換の経路)
        let searchDir = tmp.appendingPathComponent("search")
        let cand = try write("song.wav", "wxyz", in: searchDir)
        let old = "/old/song.wav"
        let r = MediaRelinker.relink(missing: [old], fingerprints: [:],
                                     hints: [old: MediaHint(relative: nil, size: 4)],
                                     candidateFolders: [searchDir])
        XCTAssertEqual(norm(r.mapping[old]), norm(cand.path), "フィンガープリントが無ければファイル名+サイズで再リンク")
        // サイズが違う同名ファイルにはつながない
        let search2 = tmp.appendingPathComponent("search2")
        _ = try write("song.wav", "wxyz-longer", in: search2)
        let r2 = MediaRelinker.relink(missing: [old], fingerprints: [:],
                                      hints: [old: MediaHint(relative: nil, size: 4)],
                                      candidateFolders: [search2])
        XCTAssertTrue(r2.mapping.isEmpty)
        XCTAssertEqual(r2.unresolved, [old])
    }

    func testRelinkLeavesUnresolvedAndAppliesMapping() throws {
        let searchDir = tmp.appendingPathComponent("search")
        let found = try write("found.mp4", "found-content", in: searchDir)
        let fp = MediaFingerprint.compute(data: Data("found-content".utf8), fileName: "gone.mp4")
        let missingA = "/old/gone.mp4"
        let missingB = "/old/never.mp4"
        let r = MediaRelinker.relink(missing: [missingA, missingB], fingerprints: [missingA: fp], candidateFolders: [searchDir])
        XCTAssertEqual(norm(r.mapping[missingA]), norm(found.path))
        XCTAssertEqual(r.unresolved, [missingB])

        var p = projectWith(src: missingA)
        p = MediaRelinker.applying(r.mapping, to: p)
        XCTAssertEqual(norm(p.allClips.first?.src), norm(found.path))
    }

    func testRelinkProjectEndToEnd() throws {
        // プロジェクトを作り、素材を移動+改名し、プロジェクト単位で再リンクする
        let mediaDir = tmp.appendingPathComponent("media")
        let f = try write("take1.mp4", "take-one-content", in: mediaDir)
        var p = projectWith(src: f.path)
        p = MediaFingerprintCollector.attaching(to: p)
        XCTAssertEqual(p.mediaFingerprints.count, 1)
        // 素材を別フォルダへ改名して移動(元は消える)
        let newDir = tmp.appendingPathComponent("archive")
        let newFile = try write("take-final.mp4", "take-one-content", in: newDir)
        try FileManager.default.removeItem(at: f)
        let r = MediaRelinker.relinkProject(p, candidateFolders: [newDir])
        XCTAssertEqual(norm(r.mapping[f.path]), norm(newFile.path))
        let fixed = MediaRelinker.applying(r.mapping, to: p)
        XCTAssertEqual(norm(fixed.allClips.first?.src), norm(newFile.path))
        XCTAssertTrue(MissingMedia.find(in: fixed).isEmpty)
    }

    // MARK: - 後方互換

    func testProjectWithoutFingerprintsStillDecodes() throws {
        let json = """
        {"width": 1280, "height": 720, "fps": 30, "bg": "#000000", "codec": "h264",
         "tracks": [{"id": "t1", "name": "映像", "clips": [{"id": "c1", "type": "video", "start": 0, "duration": 1, "src": "/old/a.mp4"}]}]}
        """
        let p = try JSONDecoder().decode(Project.self, from: Data(json.utf8))
        XCTAssertEqual(p.width, 1280)
        XCTAssertTrue(p.mediaFingerprints.isEmpty, "フィンガープリント無しのプロジェクトが読める")
        XCTAssertEqual(p.allClips.first?.src, "/old/a.mp4")
        // 再エンコードしてもフィンガープリントのキーは出ない(空なら書かない)
        let data = try JSONEncoder().encode(p)
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(text.contains("mediaFingerprints"))
    }

    func testProjectWithFingerprintsRoundTrips() throws {
        var p = projectWith(src: "/media/a.mp4")
        p.mediaFingerprints = ["/media/a.mp4": MediaFingerprint(fileName: "a.mp4", size: 3, sha256: String(repeating: "a", count: 64))]
        let data = try JSONEncoder().encode(p)
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("mediaFingerprints"))
        let back = try JSONDecoder().decode(Project.self, from: data)
        XCTAssertEqual(back.mediaFingerprints, p.mediaFingerprints)
        XCTAssertEqual(back, p)
    }
}
