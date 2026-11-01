import XCTest
import AppKit
import MovieCutCore
@testable import MovieCut

/// 出力 ▸ タイトル案をAIで作る…(画面の流れ: 確認 → 問い合わせ → 案の表示 → コピー)。
@MainActor
final class AITitleAppTests: XCTestCase {
    private final class Counter: @unchecked Sendable { var confirms = 0; var reviews = 0 }

    private func makeModel(reply: FakeAIProvider.Behavior, confirm: Bool = true, reviewButton: Int? = 0, counter: Counter = Counter()) -> (ProjectModel, FakeAIProvider) {
        var p = Project.new()
        var c = Clip(); c.id = "v1"; c.type = .voice; c.start = 0; c.duration = 3; c.text = "今日は雨の街を歩きます"; c.subtitle = true
        p.tracks[0].clips = [c]
        let m = ProjectModel(project: p)
        m.notices = OneTimeNotices()
        let fake = FakeAIProvider(reply)
        m.aiUI = AIUI(makeProvider: { fake }, destination: { "テスト用" },
                      confirmSend: { _, _ in counter.confirms += 1; return confirm },
                      review: { _, _, text, _, _ in counter.reviews += 1; return reviewButton.map { .init(button: $0, text: text) } })
        return (m, fake)
    }

    private func undoSteps(_ m: ProjectModel) -> Int { let u = m.effectiveUndoManager; var n = 0; while u.canUndo { u.undo(); n += 1 }; for _ in 0..<n { u.redo() }; return n }

    func testMenuItemIsPlainAndEnabledWithSubtitles() {
        var s = MenuState(); s.hasDocument = true
        XCTAssertFalse(AppMenuSpec.aiTitles(s).enabled)
        s.canExportSubtitles = true
        let spec = AppMenuSpec.aiTitles(s)
        XCTAssertTrue(spec.enabled)
        XCTAssertNil(spec.shortcut)
        XCTAssertEqual(spec.title, "タイトル案をAIで作る…")
        XCTAssertTrue(AppMenuSpec.all(s).contains { $0.command == .aiTitles })
    }

    func testSuggestCopiesTitlesWithoutTouchingProject() async {
        let counter = Counter()
        let (m, fake) = makeModel(reply: .reply("1. 雨の街を歩く\n2. 傘とラーメン"), counter: counter)
        let before = m.project
        let ok = await m.suggestAITitles()
        XCTAssertTrue(ok)
        XCTAssertEqual(counter.confirms, 1)
        XCTAssertEqual(fake.prompts.count, 1)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "雨の街を歩く\n傘とラーメン")
        XCTAssertEqual(m.project, before)
        XCTAssertEqual(undoSteps(m), 0)              // 編集ではないので Undo は増えない
    }

    func testDeclinedConfirmSendsNothing() async {
        let (m, fake) = makeModel(reply: .reply("案"), confirm: false)
        let ok = await m.suggestAITitles()
        XCTAssertFalse(ok)
        XCTAssertTrue(fake.prompts.isEmpty)
    }

    func testCancelledReviewDoesNotCopy() async {
        let (m, _) = makeModel(reply: .reply("別の案"), reviewButton: 1)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("元の文字", forType: .string)
        let ok = await m.suggestAITitles()
        XCTAssertFalse(ok)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "元の文字")
    }

    func testNoSubtitlesOrMarkersDoesNotAskAI() async {
        var p = Project.new()
        p.tracks[0].clips = []
        let m = ProjectModel(project: p)
        let counter = Counter()
        var fakeUI = AIUI(makeProvider: { FakeAIProvider(.reply("x")) }, destination: { "" },
                          confirmSend: { _, _ in counter.confirms += 1; return true },
                          review: { _, _, _, _, _ in counter.reviews += 1; return nil })
        fakeUI.makeProvider = { FakeAIProvider(.reply("x")) }
        m.aiUI = fakeUI
        let ok = await m.suggestAITitles()
        XCTAssertFalse(ok)
        XCTAssertEqual(counter.confirms, 0)
        XCTAssertEqual(m.statusText, "字幕かマーカーがありません")
    }
}
