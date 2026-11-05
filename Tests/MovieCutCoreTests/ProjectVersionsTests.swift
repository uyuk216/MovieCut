import XCTest
@testable import MovieCutCore

/// 世代バックアップ: 名前・並び・間引きの純粋な決まりと、保存のたびの記録(元のファイルには触れない)。
final class ProjectVersionsTests: XCTestCase {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("versions-tests-\(UUID().uuidString)")
    override func setUpWithError() throws { try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private var locations: DataLocations { DataLocations(edition: .personal, applicationSupport: tmp.appendingPathComponent("support")) }
    private func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

    // MARK: 名前

    func testGenerationNameRoundTrips() throws {
        let d = Date(timeIntervalSince1970: 1_793_000_000.123)
        let name = ProjectVersions.generationName(date: d, ext: "mcpjc")
        XCTAssertTrue(name.hasSuffix(".mcpjc"))
        XCTAssertEqual(name.count, "20261105-140355-123.mcpjc".count)
        let p = try XCTUnwrap(ProjectVersions.parseGenerationName(name))
        XCTAssertEqual(p.date.timeIntervalSince1970, d.timeIntervalSince1970, accuracy: 0.0011)
        XCTAssertEqual(p.sequence, 1)
        let second = ProjectVersions.generationName(date: d, ext: "mcpjc", sequence: 3)
        XCTAssertEqual(ProjectVersions.parseGenerationName(second)?.sequence, 3)
        XCTAssertTrue(second.contains("-3."))
    }

    func testNameIsFixedFormatInUTC() {
        let d = date("2026-11-05T14:03:55Z")
        XCTAssertEqual(ProjectVersions.generationName(date: d, ext: "mcpjc"), "20261105-140355-000.mcpjc")
        XCTAssertEqual(ProjectVersions.generationName(date: d, ext: "ymproj"), "20261105-140355-000.ymproj")
        XCTAssertEqual(ProjectVersions.generationName(date: d, ext: "../x"), "20261105-140355-000.x", "拡張子は英数字だけ")
        XCTAssertEqual(ProjectVersions.generationName(date: d, ext: ""), "20261105-140355-000")
    }

    func testParseRejectsNonGenerationNames() {
        for n in ["", "notes.txt", ".DS_Store", "20261105-140355.mcpjc", "20261305-140355-000.mcpjc", "20261105-250355-000.mcpjc",
                  "2026110x-140355-000.mcpjc", "20261105-140355-000-1.mcpjc", "20261105-140355-000-x.mcpjc", "20261105-140355-000-2-3.mcpjc"] {
            XCTAssertNil(ProjectVersions.parseGenerationName(n), n)
            XCTAssertFalse(ProjectVersions.isGenerationName(n))
        }
        XCTAssertTrue(ProjectVersions.isGenerationName("20261105-140355-000-2.mcpjc"))
    }

    func testSortNewestFirstIgnoresForeignFilesAndUsesSequence() {
        let names = ["20261105-140355-000.mcpjc", "readme.txt", "20261106-000000-000.mcpjc", "20261105-140355-000-2.mcpjc", "20261101-000000-000.mcpjc"]
        XCTAssertEqual(ProjectVersions.sortedNewestFirst(names),
                       ["20261106-000000-000.mcpjc", "20261105-140355-000-2.mcpjc", "20261105-140355-000.mcpjc", "20261101-000000-000.mcpjc"])
    }

    // MARK: 間引き

    func testPruneKeepsNewestNAndNeverTouchesForeignFiles() {
        var names = (1...15).map { ProjectVersions.generationName(date: Date(timeIntervalSince1970: 1_700_000_000 + Double($0) * 100), ext: "mcpjc") }
        names += ["memo.txt", ".DS_Store"]
        names.shuffle()
        let doomed = ProjectVersions.namesToPrune(names, keep: 10)
        XCTAssertEqual(doomed.count, 5)
        let sorted = ProjectVersions.sortedNewestFirst(names)
        XCTAssertEqual(Set(doomed), Set(sorted.suffix(5)), "古い 5 つ")
        XCTAssertEqual(doomed, Array(sorted.suffix(5).reversed()), "古い順")
        XCTAssertFalse(doomed.contains("memo.txt")); XCTAssertFalse(doomed.contains(".DS_Store"))
        XCTAssertEqual(ProjectVersions.namesToPrune(Array(names.prefix(5)), keep: 10), [])
        XCTAssertEqual(ProjectVersions.namesToPrune(sorted, keep: 15), [])
    }

    func testKeepIsClamped() {
        XCTAssertEqual(ProjectVersions.clampKeep(0), 1)
        XCTAssertEqual(ProjectVersions.clampKeep(-5), 1)
        XCTAssertEqual(ProjectVersions.clampKeep(1000), 100)
        let names = (1...3).map { ProjectVersions.generationName(date: Date(timeIntervalSince1970: 1_700_000_000 + Double($0)), ext: "mcpjc") }
        XCTAssertEqual(ProjectVersions.namesToPrune(names, keep: 0).count, 2, "0 以下は 1 世代は残す")
        let suite = "versions-defaults-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        XCTAssertEqual(ProjectVersions.keep(from: d), 10, "既定は 10 世代")
        d.set(25, forKey: ProjectVersions.keepDefaultsKey)
        XCTAssertEqual(ProjectVersions.keep(from: d), 25)
        d.set(100000, forKey: ProjectVersions.keepDefaultsKey)
        XCTAssertEqual(ProjectVersions.keep(from: d), 100)
    }

    // MARK: 置き場

    func testFolderNameSeparatesSameNamesAndIsStable() {
        let a = URL(fileURLWithPath: "/Users/x/動画/a/企画.mcpjc"), b = URL(fileURLWithPath: "/Users/x/動画/b/企画.mcpjc")
        XCTAssertNotEqual(ProjectVersions.folderName(for: a), ProjectVersions.folderName(for: b))
        XCTAssertEqual(ProjectVersions.folderName(for: a), ProjectVersions.folderName(for: a))
        XCTAssertTrue(ProjectVersions.folderName(for: a).hasPrefix("企画-"))
        let odd = ProjectVersions.folderName(for: URL(fileURLWithPath: "/x/..hidden:name.mcpjc"))
        XCTAssertFalse(odd.contains("/")); XCTAssertFalse(odd.hasPrefix("."))
        XCTAssertTrue(ProjectVersions.folder(for: a, in: locations).path.hasPrefix(locations.versions.path + "/"))
        XCTAssertTrue(locations.allPaths.contains(locations.versions))
        let long = ProjectVersions.folderName(for: URL(fileURLWithPath: "/x/" + String(repeating: "あ", count: 200) + ".mcpjc"))
        XCTAssertLessThan(long.count, 60)
    }

    func testPublicEditionUsesItsOwnVersionsFolder() {
        let a = DataLocations(edition: .personal, applicationSupport: tmp), b = DataLocations(edition: .public, applicationSupport: tmp)
        let u = URL(fileURLWithPath: "/x/p.mcpjc")
        XCTAssertNotEqual(ProjectVersions.folder(for: u, in: a), ProjectVersions.folder(for: u, in: b))
    }

    // MARK: 記録

    private func project(_ n: Int) -> URL { tmp.appendingPathComponent("p\(n).mcpjc") }

    func testRecordAddsGenerationsAndPrunesToN() throws {
        let u = project(1)
        let t0 = date("2026-11-05T10:00:00Z")
        for i in 0..<15 {
            let o = try ProjectVersions.record(data: Data("v\(i)".utf8), projectURL: u, now: t0.addingTimeInterval(Double(i) * 1000),
                                               locations: locations, keep: 10, minInterval: 0)
            guard case .added = o else { return XCTFail("\(o)") }
        }
        let list = ProjectVersions.list(for: u, in: locations)
        XCTAssertEqual(list.count, 10)
        XCTAssertEqual(try Data(contentsOf: list[0].url), Data("v14".utf8), "新しい順")
        XCTAssertEqual(try Data(contentsOf: list[9].url), Data("v5".utf8), "古い 5 つは消えた")
        XCTAssertEqual(list[0].size, 3)
        XCTAssertTrue(list[0].url.lastPathComponent.hasSuffix(".mcpjc"))
        XCTAssertTrue(zip(list, list.dropFirst()).allSatisfy { $0.date > $1.date })
    }

    func testRecordNeverReadsOrWritesTheUserFile() throws {
        let u = project(2)
        try Data("USER FILE".utf8).write(to: u)
        let before = try FileManager.default.attributesOfItem(atPath: u.path)[.modificationDate] as? Date
        _ = try ProjectVersions.record(data: Data("saved".utf8), projectURL: u, locations: locations, keep: 3, minInterval: 0)
        XCTAssertEqual(try Data(contentsOf: u), Data("USER FILE".utf8))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: u.path)[.modificationDate] as? Date, before)
        // 存在しないプロジェクトでも(保存先の名前だけで)記録できる
        let ghost = tmp.appendingPathComponent("ghost.mcpjc")
        XCTAssertNoThrow(try ProjectVersions.record(data: Data("x".utf8), projectURL: ghost, locations: locations))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ghost.path))
    }

    func testIdenticalContentIsNotRecordedAgain() throws {
        let u = project(3)
        let t0 = date("2026-11-05T10:00:00Z")
        _ = try ProjectVersions.record(data: Data("same".utf8), projectURL: u, now: t0, locations: locations, minInterval: 0)
        let o = try ProjectVersions.record(data: Data("same".utf8), projectURL: u, now: t0.addingTimeInterval(5000), locations: locations, minInterval: 0)
        XCTAssertEqual(o, .unchanged)
        XCTAssertEqual(ProjectVersions.list(for: u, in: locations).count, 1)
    }

    func testQuickConsecutiveSavesReplaceTheNewestGeneration() throws {
        let u = project(4)
        let t0 = date("2026-11-05T10:00:00Z")
        _ = try ProjectVersions.record(data: Data("a".utf8), projectURL: u, now: t0, locations: locations, minInterval: 60)
        let o = try ProjectVersions.record(data: Data("b".utf8), projectURL: u, now: t0.addingTimeInterval(20), locations: locations, minInterval: 60)
        guard case .replaced = o else { return XCTFail("\(o)") }
        var list = ProjectVersions.list(for: u, in: locations)
        XCTAssertEqual(list.count, 1, "世代を使わない")
        XCTAssertEqual(try Data(contentsOf: list[0].url), Data("b".utf8), "いちばん新しい世代は最新の中身")
        let o2 = try ProjectVersions.record(data: Data("c".utf8), projectURL: u, now: t0.addingTimeInterval(200), locations: locations, minInterval: 60)
        guard case .added = o2 else { return XCTFail("\(o2)") }
        list = ProjectVersions.list(for: u, in: locations)
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(try Data(contentsOf: list[1].url), Data("b".utf8))
    }

    func testSameInstantGetsASequenceNumberAndKeepsBoth() throws {
        let u = project(5)
        let t = date("2026-11-05T10:00:00Z")
        _ = try ProjectVersions.record(data: Data("1".utf8), projectURL: u, now: t, locations: locations, minInterval: 0)
        _ = try ProjectVersions.record(data: Data("2".utf8), projectURL: u, now: t, locations: locations, minInterval: 0)
        let list = ProjectVersions.list(for: u, in: locations)
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(try Data(contentsOf: list[0].url), Data("2".utf8), "連番の大きい方が新しい")
    }

    func testDifferentProjectsAreIndependent() throws {
        let a = project(6), b = project(7)
        for i in 0..<5 { _ = try ProjectVersions.record(data: Data("a\(i)".utf8), projectURL: a, now: date("2026-11-05T10:00:00Z").addingTimeInterval(Double(i)), locations: locations, keep: 3, minInterval: 0) }
        _ = try ProjectVersions.record(data: Data("b".utf8), projectURL: b, locations: locations, keep: 3, minInterval: 0)
        XCTAssertEqual(ProjectVersions.list(for: a, in: locations).count, 3)
        XCTAssertEqual(ProjectVersions.list(for: b, in: locations).count, 1)
    }

    func testForeignFilesInFolderAreKeptAndNotListed() throws {
        let u = project(8)
        _ = try ProjectVersions.record(data: Data("x".utf8), projectURL: u, locations: locations, keep: 1, minInterval: 0)
        let dir = ProjectVersions.folder(for: u, in: locations)
        try Data("memo".utf8).write(to: dir.appendingPathComponent("memo.txt"))
        for i in 1...3 { _ = try ProjectVersions.record(data: Data("y\(i)".utf8), projectURL: u, now: Date().addingTimeInterval(Double(i) * 1000), locations: locations, keep: 1, minInterval: 0) }
        XCTAssertEqual(ProjectVersions.list(in: dir).count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("memo.txt").path), "世代でないファイルは消さない")
    }

    func testListOfMissingFolderIsEmptyAndTitleShowsDateAndSize() {
        XCTAssertEqual(ProjectVersions.list(in: tmp.appendingPathComponent("nope")), [])
        let e = ProjectVersions.Entry(url: tmp, date: date("2026-11-05T14:03:55Z"), size: 2048)
        let jst = ProjectVersions.title(e, timeZone: TimeZone(identifier: "Asia/Tokyo")!)
        XCTAssertTrue(jst.hasPrefix("2026/11/05 23:03:55"), jst)
        XCTAssertTrue(jst.contains("KB"), jst)
    }

    // MARK: 復元(写しを開く)

    func testLoadDecodesProjectWithoutChangingTheGeneration() throws {
        var p = Project.new(); p.width = 1280; p.height = 720
        let data = try p.encoded()
        let u = project(9)
        _ = try ProjectVersions.record(data: data, projectURL: u, locations: locations, minInterval: 0)
        let e = try XCTUnwrap(ProjectVersions.list(for: u, in: locations).first)
        let before = try Data(contentsOf: e.url)
        let back = try ProjectVersions.load(e)
        XCTAssertEqual(back.width, 1280)
        XCTAssertEqual(try Data(contentsOf: e.url), before)
        XCTAssertEqual(try back.encoded(), data, "往復でバイト一致")
        // 壊れた世代は throw(クラッシュしない)
        let bad = ProjectVersions.Entry(url: tmp.appendingPathComponent("junk"), date: Date(), size: 4)
        try Data("junk".utf8).write(to: bad.url)
        XCTAssertThrowsError(try ProjectVersions.load(bad))
    }

    func testYmprojExtensionIsKept() throws {
        let u = tmp.appendingPathComponent("old.ymproj")
        _ = try ProjectVersions.record(data: Data("x".utf8), projectURL: u, locations: locations, minInterval: 0)
        XCTAssertTrue(try XCTUnwrap(ProjectVersions.list(for: u, in: locations).first).url.lastPathComponent.hasSuffix(".ymproj"))
    }
}
