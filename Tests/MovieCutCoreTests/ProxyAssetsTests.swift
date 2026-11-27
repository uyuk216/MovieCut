import XCTest
@testable import MovieCutCore

/// 生成プロキシのプロジェクト内資産化(仕様01 M-06/M-07)。AVFoundation は使わず、ダミーファイルで置き場・記録・引き直しを確かめる。
final class ProxyAssetsTests: XCTestCase {
    private var root: URL!
    private var app: URL!       // 従来のアプリ側(暫定置き場)
    private var projA: URL!     // プロジェクトのフォルダ
    private var src: URL!

    override func setUpWithError() throws {
        let fm = FileManager.default
        root = fm.temporaryDirectory.appendingPathComponent("proxy-assets-\(UUID().uuidString)", isDirectory: true)
        app = root.appendingPathComponent("app", isDirectory: true)
        projA = root.appendingPathComponent("A", isDirectory: true)
        for d in [app!, projA!] { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
        src = root.appendingPathComponent("orig.mp4")
        try Data(repeating: 1, count: 100).write(to: src)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func project() -> Project {
        var c = Clip(); c.id = "v"; c.type = .video; c.src = src.path; c.start = 0; c.duration = 1
        var p = Project(); p.tracks = [Track(name: "m")]; p.tracks[0].clips = [c]
        return p
    }
    /// ProxyStore.make と同じ名前でダミーのプロキシを置く。
    private func makeDummy(in dir: URL) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let u = try XCTUnwrap(ProxyStore.proxyURL(for: src, directory: dir))
        try Data(repeating: 2, count: 10).write(to: u)
        return u
    }

    func testRecordSaveReloadLocatesInProjectFolder() throws {
        let px = try makeDummy(in: ProxyAssets.directory(projectDir: projA))
        let p = try XCTUnwrap(ProxyAssets.recording(project(), source: src.path, proxy: px, projectDir: projA))
        XCTAssertEqual(p.proxyAssets[src.path]?.file, "proxies/" + px.lastPathComponent)
        XCTAssertEqual(p.proxyAssets[src.path]?.sourceSize, 100)
        // 保存 → 開き直し
        let file = projA.appendingPathComponent("p.mcpjc")
        try p.save(to: file)
        let re = try Project.load(from: file)
        XCTAssertEqual(re.proxyAssets, p.proxyAssets)
        let got = try XCTUnwrap(ProxyAssets.locate(source: src.path, in: re, projectDir: projA, legacyDirectory: app))
        XCTAssertEqual(got.location, .project)
        XCTAssertEqual(got.url.standardizedFileURL.path, px.standardizedFileURL.path)
        XCTAssertEqual(ProxyLinks.resolve(for: src.path, in: re, directory: app, projectDir: projA), got.url.path)
    }

    func testEmptyProxyAssetsKeepFileIdentical() throws {
        let data = try project().encoded()
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("proxyAssets"))
    }

    func testCopiedOrMovedProjectFolderStillFindsProxy() throws {
        let px = try makeDummy(in: ProxyAssets.directory(projectDir: projA))
        let p = try XCTUnwrap(ProxyAssets.recording(project(), source: src.path, proxy: px, projectDir: projA))
        let projB = root.appendingPathComponent("elsewhere/B", isDirectory: true)
        try FileManager.default.createDirectory(at: projB.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: projA, to: projB)
        try FileManager.default.removeItem(at: projA)   // 元の場所は消える(移動相当)
        // 原本も別の場所(別マシンを想定してパスが違う)でも、記録を信じて相対で引ける
        let got = try XCTUnwrap(ProxyAssets.locate(source: "/gone/orig.mp4", in: relabel(p, to: "/gone/orig.mp4"), projectDir: projB, legacyDirectory: app))
        XCTAssertEqual(got.location, .project)
        XCTAssertTrue(got.url.path.hasPrefix(projB.standardizedFileURL.path) || got.url.path.hasPrefix(projB.path))
    }

    private func relabel(_ p: Project, to newSrc: String) -> Project {
        var q = p
        if let a = q.proxyAssets.values.first { q.proxyAssets = [newSrc: a] }
        return q
    }

    func testStaleWhenOriginalSizeChanged() throws {
        let px = try makeDummy(in: ProxyAssets.directory(projectDir: projA))
        let p = try XCTUnwrap(ProxyAssets.recording(project(), source: src.path, proxy: px, projectDir: projA))
        try Data(repeating: 1, count: 500).write(to: src)   // 原本が差し替わった
        XCTAssertNil(ProxyAssets.locate(source: src.path, in: p, projectDir: projA, legacyDirectory: app))
    }

    func testEscapingRelativePathIsRejected() throws {
        var p = project()
        p.proxyAssets[src.path] = ProxyAsset(file: "../orig.mp4", sourceSize: nil)
        XCTAssertNil(ProxyAssets.locate(source: src.path, in: p, projectDir: projA, legacyDirectory: app))
    }

    func testUnsavedUsesAppDirThenAdoptCopiesToProject() throws {
        let legacy = try makeDummy(in: app)
        // 未保存(projectDir なし)は従来のアプリ側で引ける
        let p0 = project()
        XCTAssertEqual(ProxyAssets.locate(source: src.path, in: p0, projectDir: nil, legacyDirectory: app)?.location, .app)
        // 保存後: コピーして記録。アプリ側は残る(非破壊)
        let r = ProxyAssets.adoptLegacy(p0, sources: [src.path], projectDir: projA, legacyDirectory: app)
        XCTAssertEqual(r.adopted, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertEqual(ProxyAssets.locate(source: src.path, in: r.project, projectDir: projA, legacyDirectory: app)?.location, .project)
        // 2 回目は何もしない
        XCTAssertEqual(ProxyAssets.adoptLegacy(r.project, sources: [src.path], projectDir: projA, legacyDirectory: app).adopted, 0)
    }

    func testLegacyBackwardCompatWithoutRecord() throws {
        let legacy = try makeDummy(in: app)
        let got = try XCTUnwrap(ProxyAssets.locate(source: src.path, in: project(), projectDir: projA, legacyDirectory: app))
        XCTAssertEqual(got, GeneratedProxy(url: legacy, location: .app))
    }

    func testRemoveProjectKeepsLegacyAndOriginal() throws {
        let legacy = try makeDummy(in: app)
        let px = try makeDummy(in: ProxyAssets.directory(projectDir: projA))
        let p = try XCTUnwrap(ProxyAssets.recording(project(), source: src.path, proxy: px, projectDir: projA))
        XCTAssertEqual(ProxyAssets.listProject(p, projectDir: projA).count, 1)
        let r = ProxyAssets.removeProject(source: src.path, from: p, projectDir: projA)
        XCTAssertTrue(r.removed)
        XCTAssertTrue(r.project.proxyAssets.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: px.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.path))
    }

    func testRelinkRekeysProxyAssets() throws {
        let px = try makeDummy(in: ProxyAssets.directory(projectDir: projA))
        var p = try XCTUnwrap(ProxyAssets.recording(project(), source: src.path, proxy: px, projectDir: projA))
        p.proxyLinks[src.path] = "/ext/p.mp4"
        let q = MediaRelinker.applying([src.path: "/new/orig.mp4"], to: p)
        XCTAssertNotNil(q.proxyAssets["/new/orig.mp4"])
        XCTAssertNil(q.proxyAssets[src.path])
        XCTAssertEqual(q.proxyLinks["/new/orig.mp4"], "/ext/p.mp4")
    }

    func testPackageIncludesProxyAndRecordsRelative() throws {
        let px = try makeDummy(in: app)
        let plan = MediaPackage.plan(project(), size: { _ in 100 }, proxyFile: { _ in px })
        XCTAssertTrue(plan.copies.contains { $0.to == "proxies/" + px.lastPathComponent && $0.from == px.path })
        XCTAssertEqual(plan.project.proxyAssets["media/orig.mp4"]?.file, "proxies/" + px.lastPathComponent)
        let pkg = root.appendingPathComponent("pkg", isDirectory: true)
        let file = try MediaPackage.write(plan, to: pkg, projectName: "p")
        let re = try Project.load(from: file)
        let got = try XCTUnwrap(ProxyAssets.locate(source: "media/orig.mp4", in: re, projectDir: pkg, legacyDirectory: app))
        XCTAssertEqual(got.location, .project)
        // プロキシ無しの素材は従来どおり(記録なし)
        XCTAssertTrue(MediaPackage.plan(project(), size: { _ in 100 }).project.proxyAssets.isEmpty)
    }
}
