import XCTest
import MovieCutCore
@testable import MovieCut

/// レビューコメント(アプリ側): メニュー仕様・追加/編集/解決済みの Undo 歩数・読み込みの Undo。
@MainActor
final class ReviewCommentAppTests: XCTestCase {
    private func makeModel() -> ProjectModel {
        let m = ProjectModel(project: Project.new())
        m.voiceProviderFactory = { _ in ToneVoiceProvider() }
        m.notices = OneTimeNotices()
        return m
    }

    private func state(_ configure: (inout MenuState) -> Void) -> MenuState {
        var s = MenuState()
        s.hasDocument = true
        configure(&s)
        return s
    }

    func testMenuItemsEnablement() {
        let empty = AppMenuSpec.reviewCommentItems(state { _ in })
        XCTAssertEqual(empty.map(\.title), ["レビューコメントを追加…", "レビューコメント一覧…", "レビューコメントを書き出す…", "レビューコメントを読み込む…"])
        XCTAssertFalse(empty[2].enabled, "コメントが無ければ書き出しは無効")
        XCTAssertTrue(empty[0].enabled && empty[3].enabled)
        let withOne = AppMenuSpec.reviewCommentItems(state {
            $0.reviewComments = [MenuState.ReviewCommentItem(id: "a", time: 1, body: "x", resolved: false)]
        })
        XCTAssertTrue(withOne[2].enabled)
        let list = AppMenuSpec.reviewCommentList(state {
            $0.reviewComments = [MenuState.ReviewCommentItem(id: "a", time: 65, body: "直して", resolved: true)]
        })
        XCTAssertEqual(list.first?.command, .jumpToReviewComment("a"))
        XCTAssertEqual(list.first?.checked, true, "解決済みはチェック表示")
        XCTAssertTrue(list.first?.title.contains("1:05") ?? false)
    }

    func testAddEditResolveDeleteEachUndoInOneStep() {
        let m = makeModel()
        m.currentTime = 4
        let um = m.effectiveUndoManager
        let id = m.addReviewCommentAtPlayhead(body: "ここ直して", author: "田中")
        XCTAssertNotNil(id)
        XCTAssertEqual(m.project.reviewComments.count, 1)
        XCTAssertEqual(m.project.reviewComments[0].time, 4)
        XCTAssertEqual(um.undoActionName, "レビューコメントの追加")
        XCTAssertTrue(m.updateReviewCommentBody(id: id!, to: "やっぱりここ"))
        XCTAssertEqual(um.undoActionName, "レビューコメントの編集")
        XCTAssertTrue(m.toggleReviewCommentResolved(id: id!))
        XCTAssertTrue(m.project.reviewComments[0].resolved)
        um.undo(); XCTAssertFalse(m.project.reviewComments[0].resolved, "解決済みの切り替えは Undo 1 回")
        um.undo(); XCTAssertEqual(m.project.reviewComments[0].body, "ここ直して", "編集は Undo 1 回")
        um.undo(); XCTAssertEqual(m.project.reviewComments.count, 0, "追加は Undo 1 回")
        XCTAssertFalse(um.canUndo)
        um.redo(); XCTAssertEqual(m.project.reviewComments.count, 1)
        XCTAssertTrue(m.deleteReviewComment(id: id!))
        XCTAssertEqual(m.project.reviewComments.count, 0)
        um.undo(); XCTAssertEqual(m.project.reviewComments.count, 1, "削除も Undo 1 回で戻る")
    }

    func testEmptyBodyAddsNothingAndNoUndo() {
        let m = makeModel()
        XCTAssertNil(m.addReviewCommentAtPlayhead(body: "  ", author: ""))
        XCTAssertFalse(m.effectiveUndoManager.canUndo)
    }

    func testImportMergesInOneUndoStepAndReimportIsNoStep() throws {
        let m = makeModel()
        let um = m.effectiveUndoManager
        var c = ReviewComment(time: 2, body: "外部からの指摘", author: "佐藤")
        c.id = "ext1"
        let data = try ReviewCommentExchange.encodeJSON([c])
        let r = m.importReviewComments(data: data)
        XCTAssertEqual(r?.added, 1)
        XCTAssertEqual(m.project.reviewComments.count, 1)
        XCTAssertEqual(um.undoActionName, "レビューコメントの読み込み")
        // 同じファイルの再読み込みは変更なし → Undo に載らない
        _ = m.importReviewComments(data: data)
        um.undo()
        XCTAssertEqual(m.project.reviewComments.count, 0, "読み込みは Undo 1 回で戻る")
        XCTAssertFalse(um.canUndo, "再読み込みで余分な Undo 歩数が増えていない")
        // 壊れたファイルはエラー表示で、プロジェクトは不変
        XCTAssertNil(m.importReviewComments(data: Data("not json".utf8)))
        XCTAssertNotNil(m.errorMessage)
    }

    func testExportJSONRoundTripsThroughModel() throws {
        let m = makeModel()
        m.currentTime = 1
        _ = m.addReviewCommentAtPlayhead(body: "書き出し確認", author: "")
        let data = try XCTUnwrap(m.reviewCommentsJSONData())
        let back = try ReviewCommentExchange.decodeJSON(data)
        XCTAssertEqual(back, m.project.reviewComments)
    }

    // MARK: 継続作業で追加(CSV 読み込み・移動・無効理由)

    /// CSV の交換ファイルも、読み込みは Undo 1 回で戻せる(JSON と同じ入口で形式を判定する)。
    func testImportCSVDataMergesInOneUndoStep() {
        let m = makeModel()
        let um = m.effectiveUndoManager
        var c = ReviewComment(time: 7, body: "CSV からの指摘", author: "佐藤")
        c.id = "csv1"
        let data = Data(ReviewCommentExchange.csv([c]).utf8)
        let r = m.importReviewComments(data: data)
        XCTAssertEqual(r?.added, 1)
        XCTAssertEqual(m.project.reviewComments.first?.body, "CSV からの指摘")
        XCTAssertEqual(m.project.reviewComments.first?.time, 7)
        XCTAssertEqual(um.undoActionName, "レビューコメントの読み込み")
        um.undo()
        XCTAssertEqual(m.project.reviewComments.count, 0, "CSV の読み込みも Undo 1 回で戻る")
        XCTAssertFalse(um.canUndo)
    }

    /// 新しい形式の交換ファイルは、バージョンを理由に断り、プロジェクトを変えない。
    func testImportNewerVersionIsRejectedWithReason() {
        let m = makeModel()
        let data = Data(#"{"format":"moviecut-review-comments","version":99,"comments":[]}"#.utf8)
        XCTAssertNil(m.importReviewComments(data: data))
        XCTAssertTrue(m.errorMessage?.contains("バージョン 99") ?? false, "理由: \(m.errorMessage ?? "なし")")
        XCTAssertTrue(m.project.reviewComments.isEmpty)
        XCTAssertFalse(m.effectiveUndoManager.canUndo)
    }

    func testJumpToReviewCommentMovesPlayhead() {
        let m = makeModel()
        m.currentTime = 3
        let id = m.addReviewCommentAtPlayhead(body: "ここ", author: "")
        m.currentTime = 0
        XCTAssertTrue(m.jumpToReviewComment(id: id!))
        XCTAssertEqual(m.currentTime, 3)
        XCTAssertFalse(m.jumpToReviewComment(id: "ghost"))
    }

    func testExportDisabledReasonMentionsNoComments() {
        let empty = state { _ in }
        let spec = AppMenuSpec.reviewCommentItems(empty)[2]
        XCTAssertEqual(AppMenuSpec.disabledReason(for: spec, state: empty), "レビューコメントがありません")
        let withOne = state { $0.reviewComments = [MenuState.ReviewCommentItem(id: "a", time: 1, body: "x", resolved: false)] }
        let spec2 = AppMenuSpec.reviewCommentItems(withOne)[2]
        XCTAssertTrue(spec2.enabled)
        XCTAssertNil(AppMenuSpec.disabledReason(for: spec2, state: withOne))
    }
}
