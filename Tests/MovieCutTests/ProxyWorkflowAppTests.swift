import XCTest
import MovieCutCore
@testable import MovieCut

/// プロキシのワークフロー(画面側): メニューの有効条件と表示、複合の中の素材、関連付けの Undo・プレビューと書き出しの読み先、自動作成の設定、削除。
@MainActor
final class ProxyWorkflowAppTests: XCTestCase {
    private var scratch: URL!
    private var savedProxy = false
    private var savedAutoCreate = false

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("proxy-wf-app-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        savedProxy = ProxySettings.enabled()
        savedAutoCreate = ProxySettings.autoCreateEnabled()
    }

    override func tearDownWithError() throws {
        ProxySettings.set(savedProxy)
        ProxySettings.setAutoCreate(savedAutoCreate)
        try? FileManager.default.removeItem(at: scratch)
    }

    private func undoSteps(_ m: ProjectModel) -> Int {
        let u = m.effectiveUndoManager
        var n = 0
        while u.canUndo { u.undo(); n += 1 }
        for _ in 0..<n { u.redo() }
        return n
    }

    private func clip(_ id: String, _ type: ClipType, src: String? = nil) -> Clip {
        var c = Clip(); c.id = id; c.type = type; c.src = src; c.start = 0; c.duration = 1
        return c
    }

    /// 素材 1 本のトップレベルの映像を持つ書類。
    private func projectWithVideo(_ path: String) -> Project {
        var p = Project.new()
        p.tracks = [Track(name: "main")]
        p.tracks[0].clips = [clip("v", .video, src: path)]
        return p
    }

    /// 素材 1 本を複合クリップの中に持つ書類。
    private func projectWithCompoundVideo(_ path: String) -> Project {
        var c = clip("comp", .compound)
        var inner = Track(name: "inner"); inner.clips = [clip("v", .video, src: path)]
        c.tracks = [inner]
        var p = Project.new()
        p.tracks = [Track(name: "main")]
        p.tracks[0].clips = [c]
        return p
    }

    // MARK: メニュー

    func testManageProxiesNeedsAVideoSourceAndAutoCreateCheckFollowsSetting() {
        let empty = ProjectModel(project: .new())
        XCTAssertFalse(AppMenuSpec.manageProxiesItem(MenuState(model: empty)).enabled)
        XCTAssertNil(AppMenuSpec.manageProxiesItem(MenuState(model: empty)).shortcut, "ショートカットは持たない")

        let withVideo = ProjectModel(project: projectWithVideo(scratch.appendingPathComponent("a.mp4").path))
        let spec = AppMenuSpec.manageProxiesItem(MenuState(model: withVideo))
        XCTAssertTrue(spec.enabled)
        XCTAssertEqual(spec.command, .manageProxies)

        ProxySettings.setAutoCreate(false)
        XCTAssertEqual(AppMenuSpec.proxyAutoCreateItem(MenuState(model: nil)).checked, false)
        ProxySettings.setAutoCreate(true)
        XCTAssertEqual(AppMenuSpec.proxyAutoCreateItem(MenuState(model: nil)).checked, true)
        XCTAssertEqual(AppMenuSpec.proxyAutoCreateItem(MenuState(model: nil)).command, .proxyAutoCreateToggle)
    }

    // MARK: 素材の収集・複合の中

    func testVideoSourcePathsIncludesCompoundNestedMedia() {
        let path = scratch.appendingPathComponent("in-compound.mp4").path
        let m = ProjectModel(project: projectWithCompoundVideo(path))
        XCTAssertEqual(m.videoSourcePaths, [path])
    }

    // MARK: 関連付け(Undo・プレビューと書き出しの読み先)

    func testAttachLinkIsOneUndoStepAndPreviewReadsItExportReadsSource() throws {
        let src = scratch.appendingPathComponent("src.mp4")
        let external = scratch.appendingPathComponent("external.mp4")
        try Data("src".utf8).write(to: src)
        try Data("ext".utf8).write(to: external)
        ProxySettings.set(true)

        let m = ProjectModel(project: projectWithVideo(src.path))
        m.proxyDirectory = scratch.appendingPathComponent("px", isDirectory: true)
        XCTAssertTrue(m.attachProxyLink(source: src.path, proxyPath: external.path))
        XCTAssertEqual(m.rootProject.proxyLinks, [src.path: external.path])
        XCTAssertEqual(undoSteps(m), 1, "関連付けは Undo 1 回")

        m.installPreviewProxies()
        XCTAssertEqual(m.assets.sourcePath(for: src.path), external.path, "プレビューは関連付け先を読む")
        m.assets.beginExportMode()
        XCTAssertEqual(m.assets.sourcePath(for: src.path), src.path, "書き出しは原本")
        m.assets.endExportMode()

        XCTAssertTrue(m.detachProxyLink(source: src.path))
        m.installPreviewProxies()
        XCTAssertEqual(m.assets.sourcePath(for: src.path), src.path, "解除すると原本に戻る")
        XCTAssertEqual(m.proxyStatus(for: src.path), .none)
    }

    func testAttachRefusesSourceThatIsNotAVideoOfTheProject() throws {
        let src = scratch.appendingPathComponent("src.mp4")
        let m = ProjectModel(project: projectWithVideo(src.path))
        m.proxyDirectory = scratch.appendingPathComponent("px", isDirectory: true)
        XCTAssertFalse(m.attachProxyLink(source: scratch.appendingPathComponent("other.mp4").path, proxyPath: "/tmp/x.mp4"))
        XCTAssertFalse(m.attachProxyLink(source: src.path, proxyPath: src.path), "自分自身は断る")
        XCTAssertTrue(m.rootProject.proxyLinks.isEmpty)
        XCTAssertEqual(undoSteps(m), 0)
    }

    // MARK: 自動作成

    func testAutoCreateDoesNothingWhenSettingIsOff() async throws {
        let src = scratch.appendingPathComponent("big.mp4")
        try Data("not really a video".utf8).write(to: src)
        ProxySettings.setAutoCreate(false)
        let m = ProjectModel(project: projectWithVideo(src.path))
        let px = scratch.appendingPathComponent("px", isDirectory: true)
        m.proxyDirectory = px
        m.autoCreateProxiesIfNeeded(forVideoPaths: [src.path])
        XCTAssertFalse(FileManager.default.fileExists(atPath: px.path), "設定オフでは何も作らない(フォルダも作らない)")
        XCTAssertNil(m.busyMessage, "編集はロックしない")
    }

    // MARK: 削除

    func testDeleteGeneratedProxyKeepsSourceAndExternalFiles() throws {
        let src = scratch.appendingPathComponent("src.mp4")
        let external = scratch.appendingPathComponent("external.mp4")
        try Data("src".utf8).write(to: src)
        try Data("ext".utf8).write(to: external)
        let px = scratch.appendingPathComponent("px", isDirectory: true)
        try FileManager.default.createDirectory(at: px, withIntermediateDirectories: true)
        let gen = try XCTUnwrap(ProxyStore.proxyURL(for: src, directory: px))
        try Data("gen".utf8).write(to: gen)

        let m = ProjectModel(project: projectWithVideo(src.path))
        m.proxyDirectory = px
        XCTAssertTrue(m.attachProxyLink(source: src.path, proxyPath: external.path))

        XCTAssertEqual(m.deleteGeneratedProxiesForProject(), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: gen.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.path), "素材は消えない")
        XCTAssertTrue(FileManager.default.fileExists(atPath: external.path), "外部のプロキシは消えない")
        XCTAssertFalse(m.deleteGeneratedProxy(source: src.path), "もう無い")
    }

    // MARK: プロジェクト内プロキシ(M-06/M-07)

    private func legacyProxy(for src: URL, in dir: URL) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let u = try XCTUnwrap(ProxyStore.proxyURL(for: src, directory: dir))
        try Data("gen".utf8).write(to: u)
        return u
    }

    func testUnsavedUsesAppSideThenFirstSaveCopiesIntoProjectAndRecords() throws {
        let src = scratch.appendingPathComponent("src.mp4")
        try Data("src".utf8).write(to: src)
        let appDir = scratch.appendingPathComponent("app", isDirectory: true)
        let legacy = try legacyProxy(for: src, in: appDir)
        ProxySettings.set(true)

        let m = ProjectModel(project: projectWithVideo(src.path))
        m.proxyDirectory = appDir
        m.fileURL = nil                                  // 開いた直後の最初の設定(未保存)
        XCTAssertEqual(m.proxyGenerationDirectory, appDir, "未保存は暫定でアプリ側")
        XCTAssertEqual(m.generatedProxy(for: src.path)?.location, .app)

        let projDir = scratch.appendingPathComponent("Proj", isDirectory: true)
        try FileManager.default.createDirectory(at: projDir, withIntermediateDirectories: true)
        m.fileURL = projDir.appendingPathComponent("p.mcpjc")   // 最初の保存
        XCTAssertEqual(m.generatedProxy(for: src.path)?.location, .project)
        XCTAssertNotNil(m.rootProject.proxyAssets[src.path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path), "アプリ側は消さない")
        XCTAssertEqual(m.proxyGenerationDirectory, ProxyAssets.directory(projectDir: projDir))

        m.installPreviewProxies()
        XCTAssertTrue(m.assets.sourcePath(for: src.path).hasPrefix(projDir.path) || m.assets.sourcePath(for: src.path).contains("/Proj/proxies/"))
        m.assets.beginExportMode()
        XCTAssertEqual(m.assets.sourcePath(for: src.path), src.path, "書き出しは原本")
        m.assets.endExportMode()

        // 管理: プロジェクト内プロキシを消すと記録も外れ、アプリ側の従来プロキシが残る
        XCTAssertTrue(m.deleteGeneratedProxy(source: src.path))
        XCTAssertNil(m.rootProject.proxyAssets[src.path])
    }

    func testOpeningSavedProjectDoesNotCopyOrDirty() throws {
        let src = scratch.appendingPathComponent("src.mp4")
        try Data("src".utf8).write(to: src)
        let appDir = scratch.appendingPathComponent("app", isDirectory: true)
        _ = try legacyProxy(for: src, in: appDir)
        let projDir = scratch.appendingPathComponent("Proj", isDirectory: true)
        try FileManager.default.createDirectory(at: projDir, withIntermediateDirectories: true)
        let m = ProjectModel(project: projectWithVideo(src.path))
        m.proxyDirectory = appDir
        m.fileURL = projDir.appendingPathComponent("p.mcpjc")   // 開いたときの最初の設定
        XCTAssertTrue(m.rootProject.proxyAssets.isEmpty, "開いただけでは取り込まない(書類を汚さない)")
        XCTAssertEqual(m.generatedProxy(for: src.path)?.location, .app, "従来どおりアプリ側のキーで引ける")
        XCTAssertEqual(m.adoptGeneratedProxies(), 1, "管理シートの操作で取り込める")
        XCTAssertEqual(m.generatedProxy(for: src.path)?.location, .project)
    }
}
