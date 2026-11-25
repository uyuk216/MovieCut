import XCTest
@testable import MovieCutCore

final class SystemReportTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("SystemReportTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? fm.removeItem(at: root) }
    }

    private func env() -> SystemReportEnvironment {
        SystemReportEnvironment(appName: "Movie Cut", appVersion: "0.2.2", appBuild: "42",
                                bundleIdentifier: "jp.local.moviecut", edition: "personal",
                                osVersion: "macOS 15.2 (24C101)", machineModel: "MacBookPro18,3",
                                cpuBrand: "Apple M1 Pro", physicalMemoryBytes: 16 * 1024 * 1024 * 1024,
                                architecture: "arm64",
                                generatedAt: Date(timeIntervalSince1970: 1_764_000_000))
    }

    private func writeCrashDir(_ files: [(name: String, body: String, modified: Date)]) throws -> URL {
        let dir = root.appendingPathComponent("DiagnosticReports", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for f in files {
            let url = dir.appendingPathComponent(f.name)
            try Data(f.body.utf8).write(to: url)
            try fm.setAttributes([.modificationDate: f.modified], ofItemAtPath: url.path)
        }
        return dir
    }

    func testIsAppCrashReport() {
        XCTAssertTrue(SystemReportBuilder.isAppCrashReport(fileName: "Movie Cut-2026-11-25-012345.ips"))
        XCTAssertTrue(SystemReportBuilder.isAppCrashReport(fileName: "MovieCut-2026-11-25-012345.ips"))
        XCTAssertTrue(SystemReportBuilder.isAppCrashReport(fileName: "Movie Cut.crash"))
        XCTAssertFalse(SystemReportBuilder.isAppCrashReport(fileName: "OtherApp-2026-11-25-012345.ips"))
        XCTAssertFalse(SystemReportBuilder.isAppCrashReport(fileName: "Movie Cut-notes.txt"))
        XCTAssertFalse(SystemReportBuilder.isAppCrashReport(fileName: "Safari-2026-11-25-012345.ips"))
    }

    func testCollectCrashReportsNewestFirstWithLimitAndFiltering() throws {
        let base = Date(timeIntervalSince1970: 1_764_000_000)
        let dir = try writeCrashDir([
            ("Movie Cut-old.ips", "old", base),
            ("Movie Cut-new.ips", "new", base.addingTimeInterval(3600)),
            ("Movie Cut-mid.ips", "mid", base.addingTimeInterval(1800)),
            ("OtherApp-new.ips", "other", base.addingTimeInterval(7200)),
            ("Movie Cut-memo.txt", "memo", base.addingTimeInterval(7200)),
        ])
        let got = SystemReportBuilder.collectCrashReports(directory: dir, limit: 2, maxBytes: 1024)
        XCTAssertEqual(got.map(\.fileName), ["Movie Cut-new.ips", "Movie Cut-mid.ips"])
        XCTAssertEqual(got.map { String(data: $0.data, encoding: .utf8) }, ["new", "mid"])
        XCTAssertTrue(got.allSatisfy { !$0.truncated })
    }

    func testCollectCrashReportsTruncatesOversized() throws {
        let dir = try writeCrashDir([
            ("Movie Cut-big.ips", String(repeating: "x", count: 5000), Date()),
        ])
        let got = SystemReportBuilder.collectCrashReports(directory: dir, limit: 5, maxBytes: 1000)
        XCTAssertEqual(got.count, 1)
        XCTAssertEqual(got.first?.data.count, 1000)
        XCTAssertEqual(got.first?.truncated, true)
    }

    func testCollectCrashReportsMissingDirectoryIsEmpty() {
        let got = SystemReportBuilder.collectCrashReports(directory: root.appendingPathComponent("nope"))
        XCTAssertTrue(got.isEmpty)
    }

    func testWriteStagingContentsAndSummary() throws {
        let dir = try writeCrashDir([("Movie Cut-a.ips", "crash-body", Date())])
        let project = root.appendingPathComponent("sample.ymproj")
        try Data("{\"project\":true}".utf8).write(to: project)
        let options = SystemReportOptions(
            diagnosticReportsDirectory: dir, maxCrashReports: 5, maxCrashReportBytes: 1024,
            projectFileURL: project,
            settings: [SystemReportSetting(key: "プレビュー画質", value: "自動"),
                       SystemReportSetting(key: "プレビュー用プロキシ", value: "オフ")])
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        let placed = try SystemReportBuilder.writeStaging(environment: env(), options: options, to: staging)
        XCTAssertEqual(placed, ["system-report.txt", "project/sample.ymproj", "crash-reports/Movie Cut-a.ips"])

        let summary = try String(contentsOf: staging.appendingPathComponent("system-report.txt"), encoding: .utf8)
        XCTAssertTrue(summary.contains("バージョン: 0.2.2 (ビルド 42)"))
        XCTAssertTrue(summary.contains("OS: macOS 15.2 (24C101)"))
        XCTAssertTrue(summary.contains("機種: MacBookPro18,3"))
        XCTAssertTrue(summary.contains("プレビュー画質: 自動"))
        XCTAssertTrue(summary.contains("crash-reports/Movie Cut-a.ips"))
        XCTAssertTrue(summary.contains("project/sample.ymproj"))
        // 要約には置き場のパス(ホーム以下)を書かない
        XCTAssertFalse(summary.contains(root.path))

        let copiedCrash = try String(contentsOf: staging.appendingPathComponent("crash-reports/Movie Cut-a.ips"), encoding: .utf8)
        XCTAssertEqual(copiedCrash, "crash-body")
        let copiedProject = try String(contentsOf: staging.appendingPathComponent("project/sample.ymproj"), encoding: .utf8)
        XCTAssertEqual(copiedProject, "{\"project\":true}")
    }

    func testWriteStagingWithoutProjectOrCrashes() throws {
        let options = SystemReportOptions(diagnosticReportsDirectory: root.appendingPathComponent("empty"),
                                          projectFileURL: nil, settings: [])
        let staging = root.appendingPathComponent("staging2", isDirectory: true)
        let placed = try SystemReportBuilder.writeStaging(environment: env(), options: options, to: staging)
        XCTAssertEqual(placed, ["system-report.txt"])
        let summary = try String(contentsOf: staging.appendingPathComponent("system-report.txt"), encoding: .utf8)
        XCTAssertTrue(summary.contains("クラッシュレポート — 直近のものはありませんでした"))
        XCTAssertFalse(fm.fileExists(atPath: staging.appendingPathComponent("project").path))
        XCTAssertFalse(fm.fileExists(atPath: staging.appendingPathComponent("crash-reports").path))
    }

    func testGenerateProducesZipWithExpectedEntries() throws {
        let dir = try writeCrashDir([("Movie Cut-a.ips", "crash-body", Date())])
        let options = SystemReportOptions(diagnosticReportsDirectory: dir, settings: [])
        let zip = root.appendingPathComponent("report.zip")
        try SystemReportBuilder.generate(environment: env(), options: options, destination: zip)
        XCTAssertTrue(fm.fileExists(atPath: zip.path))

        let out = root.appendingPathComponent("unzipped", isDirectory: true)
        try fm.createDirectory(at: out, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, out.path]
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        XCTAssertTrue(fm.fileExists(atPath: out.appendingPathComponent("system-report.txt").path))
        XCTAssertTrue(fm.fileExists(atPath: out.appendingPathComponent("crash-reports/Movie Cut-a.ips").path))
    }
}
