import XCTest
@testable import MovieCutCore

/// プロジェクトのテンプレート(クリップを外した保存・名前の整理・一覧・保存先の読み書き)。
final class ProjectTemplateTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MovieCutTemplateTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func sampleProject() -> Project {
        var p = Project()
        p.width = 1280
        p.height = 720
        p.fps = 30
        p.markers = [Marker(time: 1.5, name: "サビ")]
        var layer = Track(name: "映像")
        var a = Clip(); a.type = .image; a.start = 0; a.duration = 2
        var b = Clip(); b.type = .text; b.start = 2; b.duration = 1
        layer.clips = [a, b]
        p.tracks = [layer, Track(name: "字幕")]
        return p
    }

    // MARK: - クリップを外す

    func testMakeRemovesClipsAndKeepsSettingsLayersMarkers() {
        let p = sampleProject()
        let t = ProjectTemplate.make(from: p)
        XCTAssertTrue(t.allClips.isEmpty, "クリップは全部外す")
        XCTAssertEqual(t.tracks.map(\.name), ["映像", "字幕"], "レイヤーの名前は残す")
        XCTAssertEqual(t.tracks.map(\.id), p.tracks.map(\.id), "レイヤーの ID は残す")
        XCTAssertEqual(t.width, 1280)
        XCTAssertEqual(t.height, 720)
        XCTAssertEqual(t.fps, 30)
        XCTAssertEqual(t.markers, p.markers)
        XCTAssertEqual(t.characters, p.characters)
        XCTAssertEqual(p.allClips.count, 2, "元のプロジェクトは変えない")
    }

    // MARK: - 名前の整理

    func testSanitizedNameTrimsAndReplacesSeparators() {
        XCTAssertEqual(ProjectTemplate.sanitizedName("  Vlog 用  "), "Vlog 用")
        XCTAssertEqual(ProjectTemplate.sanitizedName("a/b:c\\d"), "a b c d")
        XCTAssertEqual(ProjectTemplate.sanitizedName("..hidden"), "hidden", "先頭のドットは隠しファイルになるので取る")
        XCTAssertEqual(ProjectTemplate.sanitizedName("x\ny"), "x y")
    }

    func testSanitizedNameRejectsEmpty() {
        XCTAssertNil(ProjectTemplate.sanitizedName(""))
        XCTAssertNil(ProjectTemplate.sanitizedName("   "))
        XCTAssertNil(ProjectTemplate.sanitizedName("..."))
        XCTAssertNil(ProjectTemplate.sanitizedName("/ : /"))
    }

    func testSanitizedNameLimitsLength() {
        let long = String(repeating: "あ", count: ProjectTemplate.maxNameLength + 10)
        XCTAssertEqual(ProjectTemplate.sanitizedName(long)?.count, ProjectTemplate.maxNameLength)
    }

    func testUniqueNameAvoidsExisting() {
        XCTAssertEqual(ProjectTemplate.uniqueName(base: "A", existing: []), "A")
        XCTAssertEqual(ProjectTemplate.uniqueName(base: "A", existing: ["B"]), "A")
        XCTAssertEqual(ProjectTemplate.uniqueName(base: "A", existing: ["A"]), "A 2")
        XCTAssertEqual(ProjectTemplate.uniqueName(base: "A", existing: ["A", "A 2"]), "A 3")
    }

    // MARK: - 一覧

    func testNamesListsOnlyTemplateFilesSorted() {
        let files = ["b.mcpjc", "a.mcpjc", "old.ymproj", "notes.txt", ".hidden.mcpjc", "10話.mcpjc", "2話.mcpjc", ".mcpjc"]
        XCTAssertEqual(ProjectTemplate.names(fromFileNames: files), ["2話", "10話", "a", "b"])
    }

    // MARK: - 保存先の読み書き

    func testSaveThenListAndLoad() throws {
        let store = TemplateStore(directory: dir)
        XCTAssertEqual(store.names(), [])
        let saved = try store.save(sampleProject(), as: "Vlog")
        XCTAssertEqual(saved, "Vlog")
        XCTAssertEqual(store.names(), ["Vlog"])
        let loaded = try store.load(name: "Vlog")
        XCTAssertTrue(loaded.allClips.isEmpty)
        XCTAssertEqual(loaded.tracks.map(\.name), ["映像", "字幕"])
        XCTAssertEqual(loaded.markers.first?.name, "サビ")
    }

    func testSaveSameNameDoesNotOverwrite() throws {
        let store = TemplateStore(directory: dir)
        try store.save(sampleProject(), as: "Vlog")
        let second = try store.save(Project(), as: "Vlog")
        XCTAssertEqual(second, "Vlog 2")
        XCTAssertEqual(store.names(), ["Vlog", "Vlog 2"])
        XCTAssertEqual(try store.load(name: "Vlog").markers.count, 1, "既存のテンプレートは上書きしない")
    }

    func testSaveRejectsEmptyName() {
        let store = TemplateStore(directory: dir)
        XCTAssertThrowsError(try store.save(Project(), as: " / ")) { error in
            XCTAssertEqual(error as? TemplateStore.StoreError, .invalidName)
        }
    }

    func testLoadMissingThrows() {
        let store = TemplateStore(directory: dir)
        XCTAssertThrowsError(try store.load(name: "なし")) { error in
            XCTAssertEqual(error as? TemplateStore.StoreError, .notFound("なし"))
        }
    }
}
