import XCTest
@testable import MovieCutCore

/// レビューコメント: 保存形式(未使用時はバイト不変)・編集・交換ファイルの往復と競合規則。
final class ReviewCommentTests: XCTestCase {
    private func json(_ p: Project) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: p.encoded()) as! [String: Any]
    }

    private func sample() -> [ReviewComment] {
        var a = ReviewComment(time: 12.5, body: "ここで音が大きいです", author: "田中")
        a.id = "c1"
        var b = ReviewComment(time: 3, body: "タイポがあります", author: "")
        b.id = "c2"; b.endTime = 5.5; b.clipId = "clip9"; b.resolved = true
        b.createdAt = "2026-11-19T10:00:00Z"
        return [a, b]
    }

    // MARK: 保存形式

    func testEmptyReviewCommentsAreNotSavedAndBytesUnchanged() throws {
        let p = Project()
        XCTAssertNil(try json(p)["reviewComments"], "コメントが無いときはキーごと書かない")
        // 未使用プロジェクトは従来どおり往復で一致する
        XCTAssertEqual(try Project.decode(from: p.encoded()), p)
    }

    func testReviewCommentsRoundTrip() throws {
        var p = Project()
        p.reviewComments = sample()
        let j = try json(p)
        XCTAssertEqual((j["reviewComments"] as? [[String: Any]])?.count, 2)
        let q = try Project.decode(from: p.encoded())
        XCTAssertEqual(q.reviewComments, p.reviewComments)
        XCTAssertEqual(q, p)
        // 既定値の項目は書かない(resolved=false・空の author は省略)
        let first = (j["reviewComments"] as! [[String: Any]])[0]
        XCTAssertNil(first["resolved"])
        let second = (j["reviewComments"] as! [[String: Any]])[1]
        XCTAssertEqual(second["resolved"] as? Bool, true)
        XCTAssertNil(second["author"], "空の作成者名は書かない")
        XCTAssertEqual(second["endTime"] as? Double, 5.5)
        XCTAssertEqual(second["clipId"] as? String, "clip9")
    }

    func testReviewCommentDecodingIsLenientAndKeepsUnknownKeys() throws {
        let data = Data(#"{"reviewComments":[{"id":"x","time":"oops","body":3,"resolved":"yes","future":{"a":1}}]}"#.utf8)
        let p = try Project.decode(from: data)
        XCTAssertEqual(p.reviewComments.count, 1)
        XCTAssertEqual(p.reviewComments[0].time, 0)
        XCTAssertEqual(p.reviewComments[0].body, "")
        XCTAssertEqual(p.reviewComments[0].resolved, false)
        let j = try json(try Project.decode(from: p.encoded()))
        let c0 = (j["reviewComments"] as! [[String: Any]])[0]
        XCTAssertNotNil(c0["future"], "コメントの知らないキーも書き戻す")
    }

    func testMalformedReviewCommentsAreKeptInExtra() throws {
        let p = try Project.decode(from: Data(#"{"reviewComments":"oops"}"#.utf8))
        XCTAssertEqual(p.reviewComments, [])
        XCTAssertNotNil(p.extra["reviewComments"], "型が違う値は捨てずに保持する")
    }

    // MARK: 編集

    func testAddRejectsEmptyBodyAndSorts() {
        var p = Project()
        XCTAssertNil(ReviewCommentEditing.add(in: p, at: 1, body: "  "))
        let a = ReviewCommentEditing.add(in: p, at: 9, body: " 後 ", author: " A ")!
        p = a.project
        let b = ReviewCommentEditing.add(in: p, at: 2, body: "先")!
        p = b.project
        XCTAssertEqual(p.reviewComments.map(\.time), [2, 9], "時刻順")
        XCTAssertEqual(p.reviewComments[1].body, "後", "前後の空白は落とす")
        XCTAssertEqual(p.reviewComments[1].author, "A")
    }

    func testUpdateResolvedRemove() {
        var p = Project()
        let a = ReviewCommentEditing.add(in: p, at: 1, body: "x")!
        p = a.project
        XCTAssertNil(ReviewCommentEditing.updateBody(in: p, id: a.id, to: "x"), "同じ本文は変更なし")
        XCTAssertNil(ReviewCommentEditing.updateBody(in: p, id: a.id, to: " "), "空にはしない")
        XCTAssertEqual(ReviewCommentEditing.updateBody(in: p, id: a.id, to: "y")?.reviewComments[0].body, "y")
        XCTAssertNil(ReviewCommentEditing.setResolved(in: p, id: a.id, to: false), "既に未解決")
        let r = ReviewCommentEditing.setResolved(in: p, id: a.id, to: true)!
        XCTAssertEqual(ReviewCommentEditing.openCount(in: r), 0)
        XCTAssertEqual(ReviewCommentEditing.remove(in: r, id: a.id)?.reviewComments, [])
        XCTAssertNil(ReviewCommentEditing.remove(in: p, id: "ghost"))
    }

    // MARK: 交換ファイル

    func testExchangeJSONRoundTrip() throws {
        let comments = sample()
        let data = try ReviewCommentExchange.encodeJSON(comments, exportedAt: "2026-11-19T12:00:00Z")
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains(ReviewCommentExchange.formatName))
        let back = try ReviewCommentExchange.decodeJSON(data)
        XCTAssertEqual(ReviewCommentEditing.sorted(back), ReviewCommentEditing.sorted(comments))
        // 素の配列でも読める
        let bare = try JSONEncoder().encode(comments)
        XCTAssertEqual(try ReviewCommentExchange.decodeJSON(bare).count, 2)
    }

    func testExchangeRejectsForeignAndNewerFiles() {
        XCTAssertThrowsError(try ReviewCommentExchange.decodeJSON(Data(#"{"format":"other","comments":[]}"#.utf8))) {
            XCTAssertEqual($0 as? ReviewCommentExchange.ExchangeError, .notReviewCommentFile)
        }
        XCTAssertThrowsError(try ReviewCommentExchange.decodeJSON(Data(#"{"format":"moviecut-review-comments","version":99,"comments":[]}"#.utf8))) {
            XCTAssertEqual($0 as? ReviewCommentExchange.ExchangeError, .unsupportedVersion(99))
        }
    }

    /// 競合規則: 同一 id は上書き、新規は追加、ファイルに無い既存は残る。同じ内容の再読み込みは冪等。
    func testMergeOverwriteAddKeepAndIdempotent() throws {
        var p = Project()
        p.reviewComments = sample()   // c1, c2
        var changed = sample()[0]
        changed.body = "差し替え後の本文"; changed.resolved = true
        var fresh = ReviewComment(time: 30, body: "新規")
        fresh.id = "c3"
        let r = ReviewCommentExchange.merge(into: p, incoming: [changed, fresh])
        XCTAssertEqual(r.added, 1)
        XCTAssertEqual(r.updated, 1)
        XCTAssertEqual(r.unchanged, 0)
        XCTAssertEqual(r.project.reviewComments.count, 3, "ファイルに無い c2 も残る")
        XCTAssertEqual(r.project.reviewComments.first { $0.id == "c1" }?.body, "差し替え後の本文")
        XCTAssertEqual(r.project.reviewComments.map(\.time), [3, 12.5, 30], "時刻順に並べ直す")
        // 同じファイルをもう一度読み込んでも何も変わらない
        let r2 = ReviewCommentExchange.merge(into: r.project, incoming: [changed, fresh])
        XCTAssertEqual(r2.added, 0); XCTAssertEqual(r2.updated, 0); XCTAssertEqual(r2.unchanged, 2)
        XCTAssertEqual(r2.project, r.project)
    }

    func testCSVExportEscapesAndHeaders() {
        var c = ReviewComment(time: 65, body: "a,b\"c\"\n次の行", author: "x")
        c.id = "z"
        let csv = ReviewCommentExchange.csv([c])
        XCTAssertTrue(csv.hasPrefix("id,timecode,time,endTime,author,resolved,clipId,body\n"))
        XCTAssertTrue(csv.contains("1:05"), "タイムコード列")
        XCTAssertTrue(csv.contains("\"a,b\"\"c\"\"\n次の行\""), "RFC 4180 式の引用")
    }
}
