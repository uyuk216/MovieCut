import XCTest
import MovieCutCore
@testable import MovieCut

/// 素材メタデータとスマートコレクションの App 側: どの操作も Undo 1 回で戻ること、
/// 変わらない操作は履歴に載らないこと、行の要約表示。
@MainActor
final class MediaMetadataAppTests: XCTestCase {
    private func model() -> ProjectModel {
        var p = Project.new()
        p.mediaPool = ["/m/sea.mp4", "/m/mountain.mp4"]
        return ProjectModel(project: p)
    }

    func testUpdateMetadataIsOneUndoStep() {
        let m = model()
        let before = m.project
        XCTAssertTrue(m.updateMediaMetadata(for: "/m/sea.mp4", keywords: ["海", "夕焼け"], rating: 4, note: "オープニング用", label: "blue"))
        XCTAssertEqual(m.mediaMetadata(for: "/m/sea.mp4")?.keywords, ["海", "夕焼け"])
        XCTAssertEqual(m.mediaMetadata(for: "/m/sea.mp4")?.rating, 4)
        XCTAssertEqual(m.mediaMetadata(for: "/m/sea.mp4")?.note, "オープニング用")
        XCTAssertEqual(m.mediaMetadata(for: "/m/sea.mp4")?.label, "blue")
        m.effectiveUndoManager.undo()
        XCTAssertEqual(m.project, before, "取り消しは 1 回で元に戻る")
        XCTAssertFalse(m.effectiveUndoManager.canUndo, "Undo はちょうど 1 歩だけ")
    }

    func testNoChangeRegistersNothing() {
        let m = model()
        XCTAssertFalse(m.updateMediaMetadata(for: "/m/sea.mp4", keywords: [], rating: nil, note: nil, label: nil), "空のままでは変わらない")
        XCTAssertFalse(m.effectiveUndoManager.canUndo)
        XCTAssertTrue(m.updateMediaMetadata(for: "/m/sea.mp4", keywords: ["海"], rating: nil, note: nil, label: nil))
        XCTAssertFalse(m.updateMediaMetadata(for: "/m/sea.mp4", keywords: ["海"], rating: nil, note: nil, label: nil), "同じ値の保存は変わらない")
        m.effectiveUndoManager.undo()
        XCTAssertFalse(m.effectiveUndoManager.canUndo, "履歴は 1 歩だけ")
    }

    func testClearMetadataIsOneUndoStep() {
        let m = model()
        XCTAssertTrue(m.updateMediaMetadata(for: "/m/sea.mp4", keywords: ["海"], rating: 5, note: nil, label: nil))
        let withMeta = m.project
        XCTAssertTrue(m.clearMediaMetadata(for: "/m/sea.mp4"))
        XCTAssertNil(m.mediaMetadata(for: "/m/sea.mp4"))
        XCTAssertTrue(m.project.mediaMetadata.isEmpty)
        m.effectiveUndoManager.undo()
        XCTAssertEqual(m.project, withMeta)
    }

    func testSmartCollectionLifecycleEachIsOneUndoStep() {
        let m = model()
        XCTAssertTrue(m.updateMediaMetadata(for: "/m/sea.mp4", keywords: ["海"], rating: 5, note: nil, label: nil))
        let base = m.project
        let made = m.addSmartCollection(name: "海の高評価", criteria: MediaFilterCriteria(keywords: ["海"], minRating: 4))
        let collection = try! XCTUnwrap(made)
        XCTAssertEqual(m.mediaSources(in: collection), ["/m/sea.mp4"])
        XCTAssertEqual(m.mediaSources(matching: MediaFilterCriteria(keywords: ["海"])), ["/m/sea.mp4"])
        m.effectiveUndoManager.undo()
        XCTAssertEqual(m.project, base, "追加は Undo 1 回で戻る")
        m.effectiveUndoManager.redo()
        XCTAssertEqual(m.project.smartCollections.count, 1)

        var edited = collection; edited.name = "海"
        let beforeEdit = m.project
        XCTAssertTrue(m.updateSmartCollection(edited))
        XCTAssertEqual(m.project.smartCollections.first?.name, "海")
        m.effectiveUndoManager.undo()
        XCTAssertEqual(m.project, beforeEdit, "変更は Undo 1 回で戻る")

        let beforeRemove = m.project
        XCTAssertTrue(m.removeSmartCollection(id: collection.id))
        XCTAssertTrue(m.project.smartCollections.isEmpty)
        XCTAssertFalse(m.project.mediaMetadata.isEmpty, "コレクションを消しても素材のメタデータは残る")
        m.effectiveUndoManager.undo()
        XCTAssertEqual(m.project, beforeRemove, "削除は Undo 1 回で戻る")
    }

    func testRemoveMissingCollectionRegistersNothing() {
        let m = model()
        XCTAssertFalse(m.removeSmartCollection(id: "missing"))
        XCTAssertFalse(m.effectiveUndoManager.canUndo)
    }

    func testMetadataSummaryText() {
        XCTAssertEqual(AudioLibrarySheet.metadataSummary(MediaMetadata(keywords: ["海"], rating: 4, label: "blue")), "★4 ・ 青 ・ #海")
        XCTAssertEqual(AudioLibrarySheet.metadataSummary(MediaMetadata()), "")
        XCTAssertEqual(AudioLibrarySheet.metadataSummary(MediaMetadata(keywords: ["a", "b"])), "#a #b")
    }

    func testNewMetadataStringsHaveEnglish() {
        for ja in ["素材のメタデータ", "キーワード", "評価", "ラベル", "コレクション",
                   "今の条件でコレクションを追加", "コレクションを削除", "メタデータを保存", "メタデータを消去", "メモ"] {
            XCTAssertTrue(L10n.hasEnglish(ja), "\(ja) の英訳が無い")
        }
    }
}
