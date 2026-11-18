import XCTest
@testable import MovieCutCore
@testable import MovieCut

/// 素材の再リンク(フィンガープリントのハッシュ一致)と、保存時のフィンガープリント付与をアプリ側から確かめる。
@MainActor
final class MediaRelinkAppTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("relink-app-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dir = dir.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func write(_ bytes: [UInt8], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(bytes).write(to: url)
    }

    /// src のクリップ 1 つを持つ書類(素材は存在しない場所を指す = 欠けている)。
    private func projectWithClip(src: String) -> Project {
        var c = Clip(); c.type = .image; c.src = src; c.duration = 1
        var t = Track(name: "映像"); t.clips = [c]
        var p = Project.new()
        p.tracks = [t]
        return p
    }

    private func makeModel(_ p: Project) -> ProjectModel {
        let m = ProjectModel(project: p)
        m.notices = OneTimeNotices()
        return m
    }

    private func clipSrc(_ m: ProjectModel) -> String? { m.project.tracks[0].clips[0].src }

    func testSameContentUnderDifferentNameIsRelinkedByHash() throws {
        let bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x01]
        let old = dir.appendingPathComponent("old/clip.png").path
        var p = projectWithClip(src: old)
        p.mediaFingerprints[old] = MediaFingerprint.compute(data: Data(bytes), fileName: "clip.png")
        let moved = dir.appendingPathComponent("found/renamed.png")
        try write(bytes, to: moved)

        let m = makeModel(p)
        XCTAssertEqual(m.relinkMedia(in: dir), 1)
        XCTAssertEqual(URL(fileURLWithPath: clipSrc(m) ?? "").resolvingSymlinksInPath(), moved.resolvingSymlinksInPath())
        XCTAssertEqual(m.relinkReport?.relinked.map(\.from), [old])
        XCTAssertEqual(m.relinkReport?.relinked.first.map { URL(fileURLWithPath: $0.to).resolvingSymlinksInPath() },
                       moved.resolvingSymlinksInPath())
        XCTAssertEqual(m.relinkReport?.unresolved, [])
        XCTAssertEqual(m.effectiveUndoManager.undoActionName, "素材の場所の再指定")
    }

    func testSameNameAndSizeButDifferentContentIsNotRelinked() throws {
        let old = dir.appendingPathComponent("old/clip.png").path
        var p = projectWithClip(src: old)
        p.mediaFingerprints[old] = MediaFingerprint.compute(data: Data([1, 2, 3, 4]), fileName: "clip.png")
        // 同名・同サイズだが中身が違う
        try write([9, 9, 9, 9], to: dir.appendingPathComponent("found/clip.png"))

        let m = makeModel(p)
        XCTAssertEqual(m.relinkMedia(in: dir), 0)
        XCTAssertEqual(clipSrc(m), old, "取り違えを防ぐため、つながない")
        XCTAssertEqual(m.relinkReport?.relinked, [])
        XCTAssertEqual(m.relinkReport?.unresolved, [old], "未発見の一覧に残る")
        XCTAssertFalse(m.effectiveUndoManager.canUndo, "何も変えなかったので Undo にも残らない")
    }

    func testEmptyFolderStillReportsUnresolved() throws {
        let old = dir.appendingPathComponent("old/clip.png").path
        let empty = dir.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)

        let m = makeModel(projectWithClip(src: old))
        XCTAssertEqual(m.relinkMedia(in: empty), 0)
        XCTAssertEqual(m.relinkReport?.relinked, [])
        XCTAssertEqual(m.relinkReport?.unresolved, [old])
        XCTAssertEqual(m.statusText, "フォルダ内に一致する素材が見つかりませんでした(欠けている素材 1 件)")
    }
}
