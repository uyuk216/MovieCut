import XCTest
import MovieCutCore
@testable import MovieCut

/// 出力 ▸ サムネイル候補を書き出す…: ショートカットなし・重複なし、書き出しはプロジェクトを変えず Undo にも載らない。
@MainActor
final class ThumbnailCandidatesAppTests: XCTestCase {
    struct NoFaces: FaceDetecting { func faces(in image: CGImage) -> [CGRect] { [] } }

    func testMenuItemHasNoShortcutAndNeedsAnExportableProject() {
        var s = MenuState(); s.hasDocument = true; s.canExport = true
        let item = AppMenuSpec.imageExportItems(s).first { $0.command == .exportThumbnailCandidates }
        XCTAssertEqual(item?.title, "サムネイル候補を書き出す…")
        XCTAssertNil(item?.shortcut)
        XCTAssertTrue(item?.enabled ?? false)
        s.canExport = false
        XCTAssertFalse(AppMenuSpec.imageExportItems(s).first { $0.command == .exportThumbnailCandidates }?.enabled ?? true)
        let used = AppMenuSpec.all(MenuState()).compactMap(\.shortcut)
        XCTAssertEqual(used.count, Set(used).count)
    }

    func testExportWritesFilesWithoutTouchingTheProjectOrUndo() throws {
        var p = Project.new()
        p.width = 160; p.height = 90
        var c = ClipEditing.makeShapeClip(.rect, at: 0, project: p)
        c.duration = 6; c.w = 0.6; c.h = 0.6
        p.tracks[0].clips = [c]
        let m = ProjectModel(project: p)
        m.notices = OneTimeNotices()
        let before = m.project
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("thumbcand-app-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertTrue(m.exportThumbnailCandidates(to: dir, detector: NoFaces()))
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(files.count, ProjectModel.thumbnailCandidateCount)
        XCTAssertEqual(m.project, before)
        XCTAssertFalse(m.effectiveUndoManager.canUndo)
        // 中身が無いプロジェクトでは何も書かない
        let e = ProjectModel(project: Project.new())
        let dir2 = dir.appendingPathComponent("none")
        XCTAssertFalse(e.exportThumbnailCandidates(to: dir2, detector: NoFaces()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir2.path))
    }
}
