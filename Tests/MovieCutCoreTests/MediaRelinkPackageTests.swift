import XCTest
@testable import MovieCutCore

/// 素材の探し直し(フォルダ再帰・サイズ一致・目印の相対パス)とパッケージ保存。実ファイルは一時フォルダに作る。
final class MediaRelinkPackageTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("mc-relink-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // 列挙は /private/var の実パスで返るので、realpath で比べる(/var は symlink)
        let real = base.path.withCString { p -> String in
            guard let r = realpath(p, nil) else { return base.path }
            defer { free(r) }
            return String(cString: r)
        }
        root = URL(fileURLWithPath: real, isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ rel: String, bytes: Int) throws -> String {
        let u = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: u)
        return u.path
    }

    private func project(_ srcs: [String]) -> Project {
        var p = Project.new()
        var t = Track(name: "映像")
        t.clips = srcs.map { s in var c = Clip(); c.type = .video; c.src = s; c.duration = 1; return c }
        p.tracks = [t]
        return p
    }

    private func srcs(_ p: Project) -> [String?] { p.tracks[0].clips.map(\.src) }

    // MARK: 再帰の索引

    func testIndexIsRecursiveAndRecordsSizesAndSkipsHidden() throws {
        let a = try write("x/y/a.mp4", bytes: 10)
        _ = try write(".hidden/h.mp4", bytes: 3)
        let idx = MissingMedia.index(root: root)
        XCTAssertEqual(idx["a.mp4"], [MissingMedia.Candidate(path: a, size: 10)])
        XCTAssertNil(idx["h.mp4"], "隠しフォルダの中は見ない")
    }

    // MARK: サイズ一致

    func testSameNameDifferentSizeIsNotUsedWhenHintHasSize() throws {
        let wrong = try write("other/clip.mp4", bytes: 5)
        let right = try write("deep/a/clip.mp4", bytes: 9)
        var p = project(["/old/clip.mp4"])
        p.mediaHints = ["/old/clip.mp4": MediaHint(size: 9)]
        let idx = MissingMedia.index(root: root)
        let r = MissingMedia.relink(p, candidates: idx, exists: { $0 == wrong || $0 == right })
        XCTAssertEqual(srcs(r.project), [right])
        XCTAssertEqual(r.relinked, 1)
    }

    func testHintWithSizeFailsWhenOnlyWrongSizeExists() throws {
        let wrong = try write("other/clip.mp4", bytes: 5)
        var p = project(["/old/clip.mp4"])
        p.mediaHints = ["/old/clip.mp4": MediaHint(size: 9)]
        let r = MissingMedia.relink(p, candidates: MissingMedia.index(root: root), exists: { $0 == wrong })
        XCTAssertEqual(r.relinked, 0)
        XCTAssertEqual(r.stillMissing, 1)
        XCTAssertEqual(srcs(r.project), ["/old/clip.mp4"], "一致しないときは何も変えない")
    }

    func testWithoutHintSizeNameIsEnough() throws {
        let f = try write("any/clip.mp4", bytes: 1)
        let r = MissingMedia.relink(project(["/old/clip.mp4"]), candidates: MissingMedia.index(root: root), exists: { $0 == f })
        XCTAssertEqual(srcs(r.project), [f])
    }

    // MARK: 目印の相対パス

    func testRelativeHintResolvesAgainstProjectFolderFirst() throws {
        let f = try write("pack/media/v.mp4", bytes: 4)
        var p = project(["/gone/v.mp4"])
        p.mediaHints = ["/gone/v.mp4": MediaHint(relative: "media/v.mp4", size: 4)]
        // 同名の候補が別の場所にあっても、目印が先に当たる
        let other = try write("elsewhere/v.mp4", bytes: 4)
        let r = MissingMedia.relink(p, candidates: MissingMedia.index(root: root), projectDir: root.appendingPathComponent("pack").path,
                                    exists: { $0 == f || $0 == other })
        XCTAssertEqual(srcs(r.project), [f])
    }

    func testRelinkWithoutAnyMatchLeavesProjectUnchanged() throws {
        let base = project(["/gone/v.mp4"])
        let r = MissingMedia.relink(base, candidates: [:], exists: { _ in false })
        XCTAssertEqual(r.relinked, 0)
        XCTAssertEqual(r.project, base)
    }

    // MARK: パッケージ保存

    func testPlanCopiesEachSourceOnceAndRewritesToRelativePaths() throws {
        let a = try write("src/a.mp4", bytes: 6)
        let b = try write("src/sub/a.mp4", bytes: 8)   // 同じファイル名の別ファイル
        let p = project([a, a, b, "/nope/missing.png"])
        let plan = MediaPackage.plan(p, exists: { FileManager.default.fileExists(atPath: $0) }, size: { s in
            (try? FileManager.default.attributesOfItem(atPath: s)[.size] as? NSNumber)?.int64Value
        })
        XCTAssertEqual(plan.copies, [
            MediaPackage.Plan.Copy(from: a, to: "media/a.mp4"),
            MediaPackage.Plan.Copy(from: b, to: "media/a-2.mp4"),
        ])
        XCTAssertEqual(srcs(plan.project), ["media/a.mp4", "media/a.mp4", "media/a-2.mp4", "/nope/missing.png"])
        XCTAssertEqual(plan.skipped, ["/nope/missing.png"])
        XCTAssertEqual(plan.project.mediaHints[a], MediaHint(relative: "media/a.mp4", size: 6))
        XCTAssertEqual(plan.project.mediaHints[b], MediaHint(relative: "media/a-2.mp4", size: 8))
    }

    func testWritePackageCopiesMediaAndProjectReadsBack() throws {
        let a = try write("src/clip.mp4", bytes: 12)
        let plan = MediaPackage.plan(project([a]), size: { _ in 12 })
        let out = root.appendingPathComponent("pkg")
        let file = try MediaPackage.write(plan, to: out, projectName: "作品")
        XCTAssertEqual(file.lastPathComponent, "作品.mcpjc")
        let copied = out.appendingPathComponent("media/clip.mp4")
        XCTAssertEqual(try Data(contentsOf: copied).count, 12)

        let back = try Project.load(from: file)
        XCTAssertEqual(srcs(back), ["media/clip.mp4"])
        XCTAssertEqual(back.mediaHints[a], MediaHint(relative: "media/clip.mp4", size: 12))
    }

    func testPackagedProjectRelinksFromItsOwnFolderAfterMove() throws {
        let a = try write("src/clip.mp4", bytes: 12)
        let plan = MediaPackage.plan(project([a]), size: { _ in 12 })
        let out = root.appendingPathComponent("pkg")
        let file = try MediaPackage.write(plan, to: out, projectName: "作品")
        // 元の素材を消し、パッケージを別の場所へ移したつもりで、相対の目印から解決する
        try FileManager.default.removeItem(atPath: a)
        let back = try Project.load(from: file)
        XCTAssertEqual(srcs(back), ["media/clip.mp4"], "パッケージ内の参照は相対パス")
        let r = MissingMedia.relink(back, candidates: [:], projectDir: out.path, exists: { FileManager.default.fileExists(atPath: $0) })
        XCTAssertEqual(r.relinked, 1)
        XCTAssertEqual(r.stillMissing, 0)
        XCTAssertEqual(srcs(r.project), [out.appendingPathComponent("media/clip.mp4").path], "プロジェクトのフォルダ基準の絶対パスになる")
    }

    func testProjectWithoutHintsEncodesWithoutMediaHintsKey() throws {
        let data = try project(["/a.mp4"]).encoded()
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("mediaHints"))
    }

    func testMediaHintsRoundTripAndUnknownKeysSurvive() throws {
        var p = project(["/a.mp4"])
        p.mediaHints = ["/a.mp4": MediaHint(relative: "media/a.mp4", size: 3)]
        let back = try Project.decode(from: p.encoded())
        XCTAssertEqual(back.mediaHints, p.mediaHints)
    }
}
