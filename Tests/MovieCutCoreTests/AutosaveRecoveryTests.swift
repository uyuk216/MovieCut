import XCTest
@testable import MovieCutCore

/// 自動保存と復元の純粋な部分(写しの名前・書く/消す判断・往復)。
final class AutosaveRecoveryTests: XCTestCase {
    func testFileNameAndRecognition() {
        XCTAssertEqual(AutosaveRecovery.fileName(sessionID: "ABC"), "ABC.mcrecover")
        XCTAssertTrue(AutosaveRecovery.isRecoveryFileName("ABC.mcrecover"))
        XCTAssertFalse(AutosaveRecovery.isRecoveryFileName(".mcrecover"))
        XCTAssertFalse(AutosaveRecovery.isRecoveryFileName("ABC.mcpjc"))
        XCTAssertFalse(AutosaveRecovery.isRecoveryFileName("ABC.mcrecover.bak"))
    }

    func testWriteOnlyWhenEditedAndChanged() {
        XCTAssertFalse(AutosaveRecovery.shouldWrite(edited: false, revision: 3, lastWritten: nil), "保存済みは書かない")
        XCTAssertTrue(AutosaveRecovery.shouldWrite(edited: true, revision: 3, lastWritten: nil))
        XCTAssertFalse(AutosaveRecovery.shouldWrite(edited: true, revision: 3, lastWritten: 3), "同じ版は書き直さない")
        XCTAssertTrue(AutosaveRecovery.shouldWrite(edited: true, revision: 4, lastWritten: 3))
    }

    func testRemoveWhenSaved() {
        XCTAssertTrue(AutosaveRecovery.shouldRemove(edited: false))
        XCTAssertFalse(AutosaveRecovery.shouldRemove(edited: true))
    }

    func testEntryRoundTrip() throws {
        let project = Data("{\"v\":1}".utf8)
        let e = AutosaveRecovery.Entry(name: "a", originalPath: "/x/a.mcpjc", savedAt: Date(timeIntervalSince1970: 1_700_000_000), project: project)
        let back = try AutosaveRecovery.decode(try AutosaveRecovery.encode(e))
        XCTAssertEqual(back, e)
        XCTAssertEqual(back.project, project)
    }

    func testTitleUsesFileNameOrUntitled() {
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let named = AutosaveRecovery.Entry(name: "a", originalPath: "/Users/u/解説/本編.mcpjc", savedAt: t, project: Data())
        XCTAssertTrue(AutosaveRecovery.title(named).hasPrefix("本編.mcpjc("))
        let untitled = AutosaveRecovery.Entry(name: "無題", originalPath: nil, savedAt: t, project: Data())
        XCTAssertTrue(AutosaveRecovery.title(untitled).hasPrefix("無題("))
    }

    // MARK: 写しの形式(v2 を書き、v1 も読む)

    private func tmpDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("rec2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func testNewFormatIsHeaderLinePlusRawProjectWithoutBase64() throws {
        let proj = try Project.new().encoded()
        let e = AutosaveRecovery.Entry(name: "題名", originalPath: "/x/a.mcpjc", savedAt: Date(timeIntervalSince1970: 1_700_000_000), project: proj)
        let data = try AutosaveRecovery.encode(e)
        XCTAssertTrue(data.starts(with: Data(#"{"format":"mcrecover2""#.utf8)))
        XCTAssertTrue(data.suffix(proj.count) == proj, "プロジェクトはそのまま入る")
        XCTAssertLessThan(data.count, proj.count + 200)
        XCTAssertLessThan(data.count, try AutosaveRecovery.encodeLegacy(e).count, "旧形式(base64)より小さい")
        XCTAssertEqual(try AutosaveRecovery.decode(data), e)
    }

    func testOldFormatStillDecodesAndLoads() throws {
        let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        var p = Project.new(); p.scriptText = "旧形式の写し"
        let e = AutosaveRecovery.Entry(name: "旧", originalPath: nil, savedAt: Date(timeIntervalSince1970: 1_600_000_000), project: try p.encoded())
        let legacy = try AutosaveRecovery.encodeLegacy(e)
        XCTAssertTrue(legacy.starts(with: Data(#"{"name""#.utf8)), "旧形式は name から始まる JSON")
        XCTAssertEqual(try AutosaveRecovery.decode(legacy), e)
        let f = dir.appendingPathComponent("old.mcrecover")
        try legacy.write(to: f)
        XCTAssertEqual(AutosaveRecovery.load(f), e)
        XCTAssertEqual(AutosaveRecovery.list(in: dir).count, 1)
        XCTAssertEqual(try Project.decode(from: XCTUnwrap(AutosaveRecovery.load(f)).project).scriptText, "旧形式の写し")
    }

    func testWriteThenLoadRoundTripsInNewFormatAndBrokenFilesAreRejected() throws {
        let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let e = AutosaveRecovery.Entry(name: "n", originalPath: nil, savedAt: Date(timeIntervalSince1970: 5), project: try Project.new().encoded())
        XCTAssertTrue(AutosaveRecovery.write(e, sessionID: "abc", in: dir))
        let f = dir.appendingPathComponent("abc.mcrecover")
        XCTAssertEqual(AutosaveRecovery.load(f), e)
        // 見出しだけ・中身が JSON でない・見出しが壊れている
        for bad in [Data(#"{"format":"mcrecover2","name":"n","savedAt":1}"#.utf8) + Data("\n".utf8) + Data("not json".utf8),
                    Data("garbage".utf8), Data(#"{"format":"mcrecover2""#.utf8)] {
            try bad.write(to: f)
            XCTAssertNil(AutosaveRecovery.load(f))
        }
    }

    // MARK: 失敗の数え方

    func testFailureTrackerWarnsOnceAfterTwoConsecutiveFailuresAndClearsOnSuccess() {
        var t = AutosaveRecovery.FailureTracker()
        XCTAssertEqual(t.record(success: false), .none, "1 回目は知らせない")
        XCTAssertEqual(t.record(success: false), .showWarning, "2 回続けたら知らせる")
        XCTAssertEqual(t.record(success: false), .none, "3 回目以降は繰り返さない")
        XCTAssertEqual(t.record(success: false), .none)
        XCTAssertEqual(t.record(success: true), .clearWarning)
        XCTAssertEqual(t.record(success: true), .none)
        XCTAssertEqual(t.consecutiveFailures, 0)
        XCTAssertEqual(t.record(success: false), .none, "成功で数え直し")
        XCTAssertEqual(t.record(success: false), .showWarning, "また続けて失敗したら、もう一度知らせる")
    }

    func testSingleFailureBetweenSuccessesNeverWarns() {
        var t = AutosaveRecovery.FailureTracker()
        for _ in 0..<5 {
            XCTAssertEqual(t.record(success: false), .none)
            XCTAssertEqual(t.record(success: true), .none)
        }
    }

    func testWriteFailureIsReportedAsFalse() throws {
        let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let e = AutosaveRecovery.Entry(name: "n", originalPath: nil, savedAt: Date(), project: Data("{}".utf8))
        // 復元フォルダが無い(消えた・書けない)と書けず、false が返る
        XCTAssertFalse(AutosaveRecovery.write(e, sessionID: "abc", in: dir.appendingPathComponent("missing", isDirectory: true)))
    }
}
