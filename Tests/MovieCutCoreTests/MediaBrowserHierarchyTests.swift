import XCTest
@testable import MovieCutCore

/// X-2 素材ブラウザの階層化: サブフォルダ走査・フォルダ列挙・フォルダ別グループ化。
/// 従来の直下走査(scan の既定)が変わっていないことも確かめる。
final class MediaBrowserHierarchyTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mediabrowser-tree-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        func file(_ rel: String) throws {
            let url = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([0]).write(to: url)
        }
        try file("a.wav")
        try file("sub1/b.mp4")
        try file("sub1/deep/c.png")
        try file("sub2/d.mp3")
        try file("sub1/.secret.wav")
        try file("notes.txt")
        // 隠しフォルダの中身は出さない
        try file(".hidden/e.wav")
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testDefaultScanStaysDirectChildrenOnly() {
        let list = MediaBrowser.scan(folder: root)
        XCTAssertEqual(list.map(\.name), ["a.wav"], "既定の scan は直下だけ(従来どおり)")
        XCTAssertEqual(list.first?.relativePath, "a.wav", "直下のファイルの相対パスはファイル名")
        XCTAssertEqual(list.first?.directoryPath, "")
    }

    func testRecursiveScanFindsNestedMedia() {
        let list = MediaBrowser.scanTree(folder: root)
        XCTAssertEqual(Set(list.map(\.name)), ["a.wav", "b.mp4", "c.png", "d.mp3"],
                       "サブフォルダの素材も拾い、対象外・隠しは除く")
        let byName = Dictionary(uniqueKeysWithValues: list.map { ($0.name, $0) })
        XCTAssertEqual(byName["b.mp4"]?.relativePath, "sub1/b.mp4")
        XCTAssertEqual(byName["c.png"]?.relativePath, "sub1/deep/c.png")
        XCTAssertEqual(byName["c.png"]?.directoryPath, "sub1/deep")
        XCTAssertEqual(byName["d.mp3"]?.directoryPath, "sub2")
        XCTAssertEqual(byName["a.wav"]?.directoryPath, "")
    }

    func testRecursiveScanRespectsMaxDepth() {
        XCTAssertEqual(Set(MediaBrowser.scan(folder: root, recursive: true, maxDepth: 0).map(\.name)),
                       ["a.wav"], "深さ 0 は直下だけ")
        XCTAssertEqual(Set(MediaBrowser.scan(folder: root, recursive: true, maxDepth: 1).map(\.name)),
                       ["a.wav", "b.mp4", "d.mp3"], "深さ 1 で 1 段下まで、deep の中は入らない")
    }

    func testSubfoldersListsImmediateChildrenSorted() {
        let subs = MediaBrowser.subfolders(of: root)
        XCTAssertEqual(subs.map(\.name), ["sub1", "sub2"], "直下のフォルダだけ・自然順・隠しフォルダは除く")
        XCTAssertEqual(subs.map(\.relativePath), ["sub1", "sub2"])
        let deep = MediaBrowser.subfolders(of: root.appendingPathComponent("sub1"), root: root)
        XCTAssertEqual(deep.map(\.name), ["deep"])
        XCTAssertEqual(deep.first?.relativePath, "sub1/deep", "起点を渡すと相対パスが階層になる")
        XCTAssertEqual(MediaBrowser.subfolders(of: root.appendingPathComponent("missing")), [])
    }

    func testAllSubfoldersRecurses() {
        let all = MediaBrowser.allSubfolders(of: root)
        XCTAssertEqual(Set(all.map(\.relativePath)), ["sub1", "sub1/deep", "sub2"])
        XCTAssertEqual(Set(MediaBrowser.allSubfolders(of: root, maxDepth: 0).map(\.relativePath)),
                       ["sub1", "sub2"], "深さ 0 は直下のフォルダまで")
    }

    func testGroupedByFolderPutsRootFirst() {
        let groups = MediaBrowser.groupedByFolder(MediaBrowser.scanTree(folder: root))
        XCTAssertEqual(groups.map(\.folder), ["", "sub1", "sub1/deep", "sub2"])
        XCTAssertEqual(groups[0].items.map(\.name), ["a.wav"])
        XCTAssertEqual(groups[1].items.map(\.name), ["b.mp4"])
        XCTAssertEqual(groups[2].items.map(\.name), ["c.png"])
        XCTAssertEqual(groups[3].items.map(\.name), ["d.mp3"])
    }

    func testFilterMatchesSubfolderName() {
        let all = MediaBrowser.scanTree(folder: root)
        // ファイル名には含まれないフォルダ名でも、相対パスで検索に当たる
        XCTAssertEqual(MediaBrowser.filter(all, kind: .all, query: "deep").map(\.name), ["c.png"])
        XCTAssertEqual(Set(MediaBrowser.filter(all, kind: .all, query: "sub1").map(\.name)), ["b.mp4", "c.png"])
        // 従来のファイル名検索はそのまま
        XCTAssertEqual(MediaBrowser.filter(all, kind: .all, query: "a.wav").map(\.name), ["a.wav"])
    }

    func testScanOfSubfolderDirectlyKeepsRelativeToThatFolder() {
        let list = MediaBrowser.scan(folder: root.appendingPathComponent("sub1"))
        XCTAssertEqual(list.map(\.name), ["b.mp4"])
        XCTAssertEqual(list.first?.relativePath, "b.mp4")
    }
}
