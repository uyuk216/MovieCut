import XCTest
import MovieCutCore
@testable import MovieCut

/// ファイル ▸ 過去の版から復元…(メニュー表・世代の記録・写しを開く準備)。
@MainActor
final class ProjectVersionsAppTests: XCTestCase {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("versions-app-\(UUID().uuidString)")
    override func setUpWithError() throws { try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private var locations: DataLocations { DataLocations(edition: .personal, applicationSupport: tmp.appendingPathComponent("support")) }

    private func state(_ f: (inout MenuState) -> Void = { _ in }) -> MenuState {
        var s = MenuState(); s.hasDocument = true; f(&s); return s
    }

    func testMenuItemNeedsASavedFileAndHasNoShortcut() {
        let on = AppMenuSpec.restoreVersionItem(state { $0.hasSavedFile = true })
        XCTAssertEqual(on.title, "過去の版から復元…")
        XCTAssertTrue(on.enabled)
        XCTAssertNil(on.shortcut)
        let off = state()
        XCTAssertFalse(AppMenuSpec.restoreVersionItem(off).enabled)
        XCTAssertNotNil(AppMenuSpec.disabledReason(for: AppMenuSpec.restoreVersionItem(off), state: off), "押せない理由が出る")
        XCTAssertTrue(AppMenuSpec.all(on_state()).contains { $0.command == .restoreVersion })
        let used = AppMenuSpec.all(on_state()).compactMap(\.shortcut)
        XCTAssertEqual(used.count, Set(used).count, "ショートカットの重複なし")
        XCTAssertFalse(AppMenuSpec.restoreVersionItem(state { $0.hasDocument = false; $0.hasSavedFile = true }).enabled)
    }

    private func on_state() -> MenuState { state { $0.hasSavedFile = true } }

    func testMenuStateReflectsFileURL() {
        let m = ProjectModel(project: .new())
        m.notices = OneTimeNotices()
        XCTAssertFalse(MenuState(model: m).hasSavedFile, "無題は世代なし")
        m.fileURL = tmp.appendingPathComponent("a.mcpjc")
        XCTAssertTrue(MenuState(model: m).hasSavedFile)
    }

    func testRecorderWritesGenerationsOnlyForSavedFiles() throws {
        let defaults = UserDefaults(suiteName: "versions-app-\(UUID().uuidString)")!
        let url = tmp.appendingPathComponent("p.mcpjc")
        ProjectVersionRecorder.record(data: Data("x".utf8), projectURL: nil, locations: locations, defaults: defaults, minInterval: 0, synchronous: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: locations.versions.path), "無題は何も書かない")
        defaults.set(3, forKey: ProjectVersions.keepDefaultsKey)
        for i in 0..<6 {
            ProjectVersionRecorder.record(data: Data("v\(i)".utf8), projectURL: url, locations: locations, defaults: defaults, minInterval: 0, synchronous: true)
            Thread.sleep(forTimeInterval: 0.01)
        }
        let list = ProjectVersions.list(for: url, in: locations)
        XCTAssertEqual(list.count, 3, "設定の世代数で間引く")
        XCTAssertEqual(try Data(contentsOf: list[0].url), Data("v5".utf8))
    }

    func testRestorePreparesACopyAndNeverTouchesTheOriginals() throws {
        var p = Project.new(); p.width = 1280; p.height = 720
        let data = try p.encoded()
        let url = tmp.appendingPathComponent("orig.mcpjc")
        try Data("CURRENT FILE".utf8).write(to: url)
        ProjectVersionRecorder.record(data: data, projectURL: url, locations: locations, minInterval: 0, synchronous: true)
        let m = ProjectModel(project: .new())
        m.notices = OneTimeNotices()
        m.fileURL = url
        let entry = try XCTUnwrap(ProjectVersions.list(for: url, in: locations).first)
        let genBefore = try Data(contentsOf: entry.url)
        let restored = try ProjectModel.prepareRestore(entry)
        XCTAssertEqual(restored.width, 1280)
        let inbox = try XCTUnwrap(TemplateInbox.take(), "無題の新しい書類の中身として渡される")
        XCTAssertEqual(inbox.width, 1280)
        XCTAssertNil(TemplateInbox.take(), "1 回で空になる")
        XCTAssertEqual(try Data(contentsOf: url), Data("CURRENT FILE".utf8), "元のファイルは上書きしない")
        XCTAssertEqual(try Data(contentsOf: entry.url), genBefore, "世代も変えない")
        XCTAssertFalse(m.effectiveUndoManager.canUndo, "今の書類は編集されない")
        // 壊れた世代は throw で、受け渡しの箱に何も残さない
        let bad = ProjectVersions.Entry(url: tmp.appendingPathComponent("bad"), date: Date(), size: 3)
        try Data("???".utf8).write(to: bad.url)
        XCTAssertThrowsError(try ProjectModel.prepareRestore(bad))
        XCTAssertNil(TemplateInbox.take())
    }

    func testVersionEntriesOfModelFollowFileURL() throws {
        let m = ProjectModel(project: .new())
        m.notices = OneTimeNotices()
        XCTAssertEqual(m.versionEntries(locations: locations), [])
        let url = tmp.appendingPathComponent("m.mcpjc")
        m.fileURL = url
        XCTAssertEqual(m.versionEntries(locations: locations), [])
        ProjectVersionRecorder.record(data: Data("a".utf8), projectURL: url, locations: locations, minInterval: 0, synchronous: true)
        XCTAssertEqual(m.versionEntries(locations: locations).count, 1)
    }
}
