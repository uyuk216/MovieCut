import XCTest
import AppKit
import MovieCutCore
@testable import MovieCut

/// AI 連携: 送る前の確認、キャンセル、台本・チャプター・セリフ直しの適用と Undo。画面(NSAlert)は偽物に差し替える。
@MainActor
final class AIAppTests: XCTestCase {
    final class Spy: @unchecked Sendable { var confirms: [(String, String)] = []; var reviews = 0 }

    private func makeModel(reply: FakeAIProvider.Behavior, confirm: Bool = true, reviewButton: Int? = 0, reviewText: String? = nil, spy: Spy = Spy()) -> (ProjectModel, FakeAIProvider, Spy) {
        var p = Project.new()
        p.tracks[0].clips = [voice("v1", "霊夢", "こんにちは、今日はいい天気ですね", start: 0, dur: 3), voice("v2", "魔理沙", "そうだな", start: 20, dur: 2)]
        let m = ProjectModel(project: p)
        m.notices = OneTimeNotices()
        let fake = FakeAIProvider(reply)
        m.aiUI = AIUI(makeProvider: { fake }, destination: { "テスト用" },
                      confirmSend: { d, pr in spy.confirms.append((d, pr)); return confirm },
                      review: { _, _, text, _, _ in spy.reviews += 1; return reviewButton.map { .init(button: $0, text: reviewText ?? text) } })
        m.voiceProviderFactory = { _ in ToneVoiceProvider() }
        return (m, fake, spy)
    }

    private func voice(_ id: String, _ who: String, _ text: String, start: Double, dur: Double) -> Clip {
        var c = Clip(); c.id = id; c.type = .voice; c.start = start; c.duration = dur; c.text = text; c.subtitle = true
        c.charId = Project.new().characters.first { $0.name == who }?.id
        return c
    }
    private func steps(_ m: ProjectModel) -> Int { let u = m.effectiveUndoManager; var n = 0; while u.canUndo { u.undo(); n += 1 }; for _ in 0..<n { u.redo() }; return n }

    func testDeclinedConfirmSendsNothing() async {
        let (m, fake, spy) = makeModel(reply: .reply("霊夢: はい"), confirm: false)
        let ok = await m.generateAIScript(theme: "猫", characterNames: ["霊夢"], lineCount: 5)
        XCTAssertFalse(ok)
        XCTAssertEqual(fake.prompts, [], "確認で断ったら AI には何も送らない")
        XCTAssertEqual(spy.confirms.count, 1)
        XCTAssertTrue(spy.confirms[0].1.contains("猫"), "送る文そのものを見せる")
        XCTAssertNil(m.busyMessage)
    }
    func testNotConfiguredShowsJapaneseError() async {
        let m = ProjectModel(project: .new())
        m.aiUI.makeProvider = { throw AIError.notConfigured }
        var asked = false
        m.aiUI.confirmSend = { _, _ in asked = true; return true }
        let ok = await m.generateAIScript(theme: "猫", characterNames: ["霊夢"], lineCount: 5)
        XCTAssertFalse(ok); XCTAssertFalse(asked)
        XCTAssertEqual(m.errorTitle, "AI を使えません")
        XCTAssertTrue(m.errorMessage?.contains("設定") == true)
    }
    func testScriptGoesToScriptFieldOnly() async {
        let (m, _, spy) = makeModel(reply: .reply("前置き\n```\n霊夢: こんにちは\n魔理沙: やあ\n```"))
        m.scriptText = "既存: 行"
        let before = m.project
        let ok = await m.generateAIScript(theme: "猫", characterNames: ["霊夢", "魔理沙"], lineCount: 5)
        XCTAssertTrue(ok)
        XCTAssertEqual(m.scriptText, "既存: 行\n霊夢: こんにちは\n魔理沙: やあ")
        XCTAssertEqual(m.project, before, "音声もクリップも自動では作らない")
        XCTAssertEqual(spy.reviews, 1)
    }
    func testScriptGarbageReportsAndChangesNothing() async {
        let (m, _, spy) = makeModel(reply: .reply("すみません、できません"))
        let ok = await m.generateAIScript(theme: "猫", characterNames: ["霊夢"], lineCount: 5)
        XCTAssertFalse(ok); XCTAssertEqual(m.scriptText, ""); XCTAssertEqual(spy.reviews, 0)
        XCTAssertEqual(m.errorTitle, "AI の返事を使えません")
    }
    func testReviewCancelKeepsScriptEmpty() async {
        let (m, _, _) = makeModel(reply: .reply("霊夢: はい"), reviewButton: nil)
        let ok = await m.generateAIScript(theme: "猫", characterNames: ["霊夢"], lineCount: 5)
        XCTAssertFalse(ok); XCTAssertEqual(m.scriptText, "")
    }
    func testProviderErrorShownAndNotBusy() async {
        let (m, _, _) = makeModel(reply: .fail(.timedOut(5)))
        let ok = await m.generateAIScript(theme: "猫", characterNames: ["霊夢"], lineCount: 5)
        XCTAssertFalse(ok); XCTAssertNil(m.busyMessage); XCTAssertNil(m.aiCancel)
        XCTAssertEqual(m.errorTitle, "AI を使えませんでした")
        XCTAssertTrue(m.errorMessage?.contains("5 秒") == true)
    }
    func testCancelWhileWaiting() async throws {
        let (m, _, _) = makeModel(reply: .delay(seconds: 10, reply: "霊夢: はい"))
        let t = Task { await m.generateAIScript(theme: "猫", characterNames: ["霊夢"], lineCount: 5) }
        for _ in 0..<50 where m.aiCancel == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertNotNil(m.aiCancel, "問い合わせ中はキャンセルできる")
        XCTAssertNotNil(m.busyMessage)
        m.cancelAI()
        let ok = await t.value
        XCTAssertFalse(ok); XCTAssertNil(m.busyMessage); XCTAssertEqual(m.statusText, "AI への問い合わせをキャンセルしました")
    }

    func testChaptersAddMarkersOneUndoAndNoDuplicates() async {
        let (m, fake, _) = makeModel(reply: .reply("0:00 はじめに\n0:10 本題\n0:20 おわり"), reviewButton: 0)
        m.project.markers = [Marker(time: 10.2, name: "既存")]
        let ok = await m.suggestAIChapters()
        XCTAssertTrue(ok)
        XCTAssertTrue(fake.prompts[0].contains("こんにちは、今日は"), "字幕が送る文に入る")
        XCTAssertEqual(m.project.markers.map(\.name), ["はじめに", "既存", "おわり"])
        XCTAssertEqual(steps(m), 1)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "0:00 はじめに\n0:10 本題\n0:20 おわり")
    }
    func testChaptersCopyOnlyLeavesProject() async {
        let (m, _, _) = makeModel(reply: .reply("0:00 a\n0:10 b\n0:20 c"), reviewButton: 1)
        let before = m.project
        let ok = await m.suggestAIChapters()
        XCTAssertTrue(ok)
        XCTAssertEqual(m.project, before); XCTAssertEqual(steps(m), 0)
    }
    func testChaptersNeedSubtitles() async {
        let (m, fake, _) = makeModel(reply: .reply("x"))
        m.project.tracks[0].clips = []
        let ok = await m.suggestAIChapters()
        XCTAssertFalse(ok); XCTAssertEqual(fake.prompts, [])
    }

    func testRewriteAppliesAsOneUndoStep() async {
        let (m, _, spy) = makeModel(reply: .reply("「こんにちは」"), reviewText: "やあ、いい天気")
        let ok = await m.rewriteVoiceWithAI(clipId: "v1", mode: .shorten)
        XCTAssertTrue(ok)
        XCTAssertEqual(m.clip("v1")?.text, "やあ、いい天気")
        XCTAssertEqual(steps(m), 1, "音声の作り直しを含めて Undo 1 回")
        XCTAssertTrue(spy.confirms[0].1.contains("こんにちは、今日はいい天気ですね"))
        m.effectiveUndoManager.undo()
        XCTAssertEqual(m.clip("v1")?.text, "こんにちは、今日はいい天気ですね")
    }
    func testRewriteCancelChangesNothing() async {
        let (m, _, _) = makeModel(reply: .reply("別の文"), reviewButton: nil)
        let ok = await m.rewriteVoiceWithAI(clipId: "v1", mode: .paraphrase)
        XCTAssertFalse(ok)
        XCTAssertEqual(m.clip("v1")?.text, "こんにちは、今日はいい天気ですね"); XCTAssertEqual(steps(m), 0)
    }
    func testRewriteSameTextRegistersNoUndo() async {
        let (m, _, _) = makeModel(reply: .reply("そうだな"))
        _ = await m.rewriteVoiceWithAI(clipId: "v2", mode: .paraphrase)
        XCTAssertEqual(steps(m), 0)
    }

    func testMenuItemsEnabledAndNoShortcuts() {
        var s = MenuState(); s.hasDocument = true
        XCTAssertFalse(AppMenuSpec.aiRewrite(s).enabled); XCTAssertFalse(AppMenuSpec.aiChapters(s).enabled)
        XCTAssertTrue(AppMenuSpec.aiScript(s).enabled)
        s.isVoiceSelected = true; s.canExportSubtitles = true
        XCTAssertTrue(AppMenuSpec.aiRewrite(s).enabled); XCTAssertTrue(AppMenuSpec.aiChapters(s).enabled)
        let ids = AppMenuSpec.all(s).map(\.command)
        for c in [MenuCommand.aiScript, .aiChapters, .aiRewrite, .aiSettings] { XCTAssertTrue(ids.contains(c)) }
        XCTAssertTrue(AppMenuSpec.all(s).filter { [.aiScript, .aiChapters, .aiRewrite, .aiSettings].contains($0.command) }.allSatisfy { $0.shortcut == nil })
        XCTAssertEqual(AppMenuSpec.aiScript(s).title, "AIで台本を作る…")
        XCTAssertEqual(AppMenuSpec.aiChapters(s).title, "チャプター案をAIで作る…")
        XCTAssertEqual(AppMenuSpec.aiRewrite(s).title, "AIでセリフを直す…")
    }
}
