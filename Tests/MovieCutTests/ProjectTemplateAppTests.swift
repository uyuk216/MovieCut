import XCTest
@testable import MovieCut
@testable import MovieCutCore

/// ファイル ▸ テンプレート(メニューの項目の作り方。ショートカットは持たない)。
@MainActor
final class ProjectTemplateAppTests: XCTestCase {
    func testTemplateNewItemsListOnePerNameInOrder() {
        var s = MenuState()
        s.templateNames = ["Vlog", "解説"]
        let items = AppMenuSpec.templateNewItems(s)
        XCTAssertEqual(items.map(\.title), ["Vlog", "解説"])
        XCTAssertEqual(items.map(\.command), [.newFromTemplate("Vlog"), .newFromTemplate("解説")])
        XCTAssertTrue(items.allSatisfy { $0.shortcut == nil && $0.enabled })
    }

    func testTemplateNewItemsEmptyWhenNoTemplates() {
        XCTAssertTrue(AppMenuSpec.templateNewItems(MenuState()).isEmpty)
    }

    func testSaveTemplateHasNoShortcut() {
        let item = AppMenuSpec.templateSave(MenuState())
        XCTAssertEqual(item.command, .saveTemplate)
        XCTAssertNil(item.shortcut)
    }

    func testInboxHandsOverOnce() {
        TemplateInbox.set(ProjectTemplate.make(from: Project()))
        XCTAssertNotNil(TemplateInbox.take())
        XCTAssertNil(TemplateInbox.take(), "一度受け取ったら残さない")
    }

    func testSaveWithChosenPartsAndSelectedClips() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tplapp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let m = ProjectModel(project: .new())
        m.project.width = 1280
        var c = Clip(); c.id = "k"; c.type = .image; c.src = "/nonexistent/a.png"; c.duration = 2
        m.project.tracks[0].clips = [c]
        let before = try m.project.encoded()
        let saved = m.saveTemplate(named: "  部分  ", parts: [.markers], clipIds: ["k"], store: TemplateStore(directory: dir))
        XCTAssertEqual(saved, "部分")
        let t = try TemplateStore(directory: dir).load(name: "部分")
        XCTAssertEqual(t.width, 1920, "設定を含めない")
        XCTAssertEqual(t.allClips.map(\.id), ["k"])
        XCTAssertEqual(try m.project.encoded(), before, "元のプロジェクトは変えない")
        XCTAssertFalse(m.effectiveUndoManager.canUndo, "保存は Undo に載せない")
        XCTAssertNil(m.saveTemplate(named: "  ", parts: .standard, clipIds: [], store: TemplateStore(directory: dir)))
    }
}
