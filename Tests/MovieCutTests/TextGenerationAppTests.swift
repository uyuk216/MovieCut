import XCTest
import MovieCutCore
@testable import MovieCut

/// AIテキスト生成(W3-08 / 監査 #74)のアプリ側: 未設定時の無効化、モック生成 →
/// 選択取り込み(Undo 1 回)、失敗とキャンセルの表示、メニュー項目。
/// 実サービスへの通信はしない(プロバイダは偽物に差し替える)。
@MainActor
final class TextGenerationAppTests: XCTestCase {
    private func makeModel(provider: FakeTextGenerationProvider) -> ProjectModel {
        let m = ProjectModel(project: .new())
        m.notices = OneTimeNotices()
        m.textGenUI = TextGenUI(makeProvider: { provider })
        return m
    }

    private func steps(_ m: ProjectModel) -> Int {
        let u = m.effectiveUndoManager
        var n = 0
        while u.canUndo { u.undo(); n += 1 }
        for _ in 0..<n { u.redo() }
        return n
    }

    func testGenerateWithMockThenImportIsOneUndo() async {
        let fake = FakeTextGenerationProvider(.suggestions([
            DialogueSuggestion(characterName: "キャラ1", text: "こんにちは"),
            DialogueSuggestion(characterName: "キャラ3", text: "やあ"),
            DialogueSuggestion(characterName: nil, text: "ナレーション"),
        ]))
        let m = makeModel(provider: fake)
        m.scriptText = "キャラ1: 既存の行"
        let got = await m.generateDialogueSuggestions(theme: "猫カフェ", keywords: ["猫"], count: 3)
        XCTAssertEqual(got?.count, 3)
        XCTAssertEqual(fake.requests.first?.theme, "猫カフェ")
        XCTAssertEqual(fake.requests.first?.keywords, ["猫"])
        XCTAssertTrue(fake.requests.first?.contextLines.contains("キャラ1: 既存の行") == true, "今の台本を参考として渡す")
        XCTAssertNil(m.busyMessage)

        let before = steps(m)
        let added = m.importDialogueSuggestions(Array(got!.prefix(2)))
        XCTAssertEqual(added, 2)
        XCTAssertEqual(m.scriptText, "キャラ1: 既存の行\nキャラ1: こんにちは\nキャラ3: やあ")
        XCTAssertEqual(m.effectiveUndoManager.undoActionName, "AIのセリフ案を取り込む")
        XCTAssertEqual(steps(m), before + 1, "取り込みは Undo 1 回")
        m.effectiveUndoManager.undo()
        XCTAssertEqual(m.scriptText, "キャラ1: 既存の行")
        m.effectiveUndoManager.redo()
        XCTAssertEqual(m.scriptText, "キャラ1: 既存の行\nキャラ1: こんにちは\nキャラ3: やあ")
    }

    func testImportSkipsLinesAlreadyInScript() async {
        let fake = FakeTextGenerationProvider(.suggestions([DialogueSuggestion(characterName: "キャラ1", text: "こんにちは")]))
        let m = makeModel(provider: fake)
        let got = await m.generateDialogueSuggestions(theme: "x", keywords: [], count: 1)
        XCTAssertEqual(m.importDialogueSuggestions(got!), 1)
        XCTAssertEqual(m.importDialogueSuggestions(got!), 0, "同じ行は二重に足さない")
        XCTAssertEqual(m.scriptText, "キャラ1: こんにちは")
    }

    func testUnconfiguredShowsErrorAndChangesNothing() async {
        let m = ProjectModel(project: .new())
        m.notices = OneTimeNotices()
        m.textGenUI = TextGenUI(makeProvider: { throw TextGenerationError.notConfigured })
        let got = await m.generateDialogueSuggestions(theme: "猫", keywords: [], count: 3)
        XCTAssertNil(got)
        XCTAssertEqual(m.errorTitle, "AIテキスト生成を使えません")
        XCTAssertTrue(m.errorMessage?.contains("設定されていません") == true)
        XCTAssertEqual(m.scriptText, "")
        XCTAssertNil(m.busyMessage)
    }

    func testDefaultSettingsAreUnconfiguredOnThisMachineIndependentWay() {
        // 既定(UserDefaults に何も無い状態を模すため、空の設定で確認する)
        let s = TextGenerationSettings()
        XCTAssertFalse(s.isConfigured)
        XCTAssertThrowsError(try s.makeProvider()) {
            guard case TextGenerationError.notConfigured = $0 else { return XCTFail("\($0)") }
        }
    }

    func testProviderFailureShowsError() async {
        let fake = FakeTextGenerationProvider(.fail(.http(500, "boom")))
        let m = makeModel(provider: fake)
        let got = await m.generateDialogueSuggestions(theme: "猫", keywords: [], count: 3)
        XCTAssertNil(got)
        XCTAssertEqual(m.errorTitle, "セリフ案を作れませんでした")
        XCTAssertTrue(m.errorMessage?.contains("HTTP 500") == true)
        XCTAssertNil(m.busyMessage)
        XCTAssertNil(m.textGenCancel)
    }

    func testCancelWhileWaiting() async {
        let fake = FakeTextGenerationProvider(.delay(seconds: 10, suggestions: []))
        let m = makeModel(provider: fake)
        let t = Task { await m.generateDialogueSuggestions(theme: "猫", keywords: [], count: 3) }
        for _ in 0..<50 where m.textGenCancel == nil { try? await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertNotNil(m.textGenCancel)
        m.cancelTextGeneration()
        let got = await t.value
        XCTAssertNil(got)
        XCTAssertEqual(m.statusText, "セリフ案の生成をキャンセルしました")
        XCTAssertNil(m.busyMessage)
    }

    func testEmptyThemeDoesNotCallProvider() async {
        let fake = FakeTextGenerationProvider(.suggestions([]))
        let m = makeModel(provider: fake)
        let got = await m.generateDialogueSuggestions(theme: "  ", keywords: [], count: 3)
        XCTAssertNil(got)
        XCTAssertTrue(fake.requests.isEmpty)
    }

    // MARK: メニュー

    func testMenuItemsAndEnablement() {
        var s = MenuState()
        s.hasDocument = true
        XCTAssertTrue(AppMenuSpec.dialogueSuggestionsItem(s).enabled)
        XCTAssertTrue(AppMenuSpec.textGenerationSettingsItem(s).enabled)
        XCTAssertFalse(AppMenuSpec.speakerDiarizationItem(s).enabled, "認識対象のクリップが無いと話者分離は無効")
        s.canTranscribe = true
        XCTAssertTrue(AppMenuSpec.speakerDiarizationItem(s).enabled)
        XCTAssertEqual(AppMenuSpec.dialogueSuggestionsItem(s).command, .dialogueSuggestions)
        XCTAssertEqual(AppMenuSpec.speakerDiarizationItem(s).command, .speakerDiarization)
        XCTAssertEqual(AppMenuSpec.textGenerationSettingsItem(s).command, .textGenerationSettings)
        var noDoc = MenuState()
        XCTAssertFalse(AppMenuSpec.dialogueSuggestionsItem(noDoc).enabled)
    }
}
