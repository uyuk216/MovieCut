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
}
