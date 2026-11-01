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
}
