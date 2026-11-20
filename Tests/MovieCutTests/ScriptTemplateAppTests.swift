import XCTest
import MovieCutCore
@testable import MovieCut

/// バッチE の画面配線: 台本編集の保存(1 回の Undo)・CSV 読み込み・アイテムテンプレートの保存/適用/作成・メニュー。
@MainActor
final class ScriptTemplateAppTests: XCTestCase {
    private func sampleModel() -> ProjectModel {
        var p = Project()
        var c1 = Character(); c1.name = "キャラ1"
        var c2 = Character(); c2.name = "キャラ2"
        p.characters = [c1, c2]
        func voice(_ char: Character, _ text: String, _ start: Double) -> Clip {
            var c = Clip(); c.type = .voice; c.text = text; c.charId = char.id
            c.start = start; c.duration = 2
            return c
        }
        var track = Track(name: "ボイス")
        track.clips = [voice(c1, "こんにちは", 0), voice(c2, "[笑顔]やあ", 3)]
        p.tracks = [track]
        return ProjectModel(project: p)
    }

    // MARK: 台本編集(#41)

    func testCommitScriptTableIsOneUndo() {
        let m = sampleModel()
        var lines = m.scriptTableLines()
        XCTAssertEqual(lines.count, 2)
        lines[0].spoken = "こんばんは"
        lines[1].expression = ""
        lines[1].characterId = m.project.characters[0].id
        XCTAssertEqual(m.commitScriptTable(lines), 2)
        XCTAssertEqual(m.project.allClips.first { $0.id == lines[0].clipId }?.text, "こんばんは")
        XCTAssertEqual(m.project.allClips.first { $0.id == lines[1].clipId }?.text, "やあ")
        XCTAssertEqual(m.project.allClips.first { $0.id == lines[1].clipId }?.charId, m.project.characters[0].id)
        var steps = 0
        while m.effectiveUndoManager.canUndo { m.effectiveUndoManager.undo(); steps += 1 }
        XCTAssertEqual(steps, 1, "一覧の保存はまとめて 1 回の Undo")
        XCTAssertEqual(m.project.allClips.first { $0.id == lines[0].clipId }?.text, "こんにちは")
    }

    func testCommitScriptTableWithoutChangesAddsNoUndo() {
        let m = sampleModel()
        XCTAssertEqual(m.commitScriptTable(m.scriptTableLines()), 0)
        XCTAssertFalse(m.effectiveUndoManager.canUndo)
    }

    func testScriptTableSheetFlagAndMenuSpec() {
        let m = sampleModel()
        XCTAssertFalse(m.showScriptTableSheet)
        m.openScriptTable()
        XCTAssertTrue(m.showScriptTableSheet)
        var s = MenuState()
        s.hasVoiceClips = true; s.hasDocument = true
        let spec = AppMenuSpec.scriptTableItem(s)
        XCTAssertEqual(spec.command, .scriptTable)
        XCTAssertNil(spec.shortcut)
        XCTAssertTrue(spec.enabled)
    }

    // MARK: 台本 CSV(#42)

    func testImportScriptCSVAppendsLinesToScriptText() {
        let m = sampleModel()
        XCTAssertEqual(m.scriptText, "")
        let n = m.importScriptCSV(text: "キャラ,セリフ,読み,字幕,表情\nキャラ1,相棒,あいぼう,,\nキャラ2,やあ,,,笑顔")
        XCTAssertEqual(n, 2)
        XCTAssertEqual(m.scriptText, "キャラ1: あいぼう | 相棒\nキャラ2: [笑顔]やあ")
        // 2 回目は末尾へ足す
        XCTAssertEqual(m.importScriptCSV(text: "キャラ1,追加の行"), 1)
        XCTAssertTrue(m.scriptText.hasSuffix("\nキャラ1: 追加の行"))
        // 読めない CSV は何も足さない
        XCTAssertEqual(m.importScriptCSV(text: ""), 0)
    }

    func testScriptCSVMenuSpecs() {
        var s = MenuState()
        s.hasVoiceClips = true; s.hasDocument = true
        let items = AppMenuSpec.scriptCSVItems(s)
        XCTAssertEqual(items.map(\.command), [.importScriptCSV, .exportScriptCSV])
        XCTAssertTrue(items.allSatisfy { $0.shortcut == nil })
    }

    func testReadCSVTextEncodings() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MovieCutScriptCSVAppTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("t.csv")
        try "キャラ1,こんにちは".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(try ProjectModel.readCSVText(from: url), "キャラ1,こんにちは")
        try "キャラ1,こんにちは".write(to: url, atomically: true, encoding: .shiftJIS)
        XCTAssertEqual(try ProjectModel.readCSVText(from: url), "キャラ1,こんにちは", "Shift_JIS の CSV も読む")
    }

    // MARK: アイテムテンプレート(#8)

    func testSaveItemTemplateToStore() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MovieCutItemTemplateAppTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ItemTemplateStore(directory: dir)
        let m = sampleModel()
        var clip = Clip(); clip.type = .text; clip.text = "題"; clip.fontSize = 88
        XCTAssertEqual(m.saveItemTemplate(named: "題字", from: clip, store: store), "題字")
        XCTAssertEqual(store.load().map(\.name), ["題字"])
        XCTAssertNil(m.saveItemTemplate(named: " ", from: clip, store: store))
    }

    func testApplyBuiltinItemTemplateAndCreateFromTemplate() {
        let m = sampleModel()
        // 文字クリップを選んで組み込み「見出し(文字)」を適用
        var text = Clip(); text.type = .text; text.text = "題"; text.fontSize = 40; text.start = 0; text.duration = 2
        let textId = text.id
        XCTAssertTrue(m.edit("追加") { $0.tracks[0].clips.append(text) })
        m.selectedClipId = textId
        XCTAssertTrue(m.applyItemTemplate(named: "見出し(文字)"))
        let applied = m.project.allClips.first { $0.id == textId }
        XCTAssertEqual(applied?.fontSize, 120)
        XCTAssertEqual(applied?.text, "題", "セリフは上書きしない")
        // 種類が違うテンプレートは当たらない
        XCTAssertFalse(m.applyItemTemplate(named: "ぼかし・標準"))
        // テンプレートから新規作成(ぼかし)
        let before = m.project.allClips.count
        let newId = m.createClipFromItemTemplate(named: "ぼかし・標準")
        XCTAssertNotNil(newId)
        XCTAssertEqual(m.project.allClips.count, before + 1)
        XCTAssertEqual(m.project.allClips.first { $0.id == newId }?.type, .blur)
        XCTAssertEqual(m.selectedClipId, newId)
    }

    func testItemTemplateMenuSpecs() {
        var s = MenuState()
        s.hasDocument = true; s.hasSelection = true
        s.itemTemplateNames = ["A", "B"]
        XCTAssertEqual(AppMenuSpec.itemTemplateApplyItems(s).map(\.command),
                       [.applyItemTemplate("A"), .applyItemTemplate("B")])
        XCTAssertEqual(AppMenuSpec.itemTemplateCreateItems(s).map(\.command),
                       [.createFromItemTemplate("A"), .createFromItemTemplate("B")])
        XCTAssertEqual(AppMenuSpec.saveItemTemplateItem(s).command, .saveItemTemplate)
        XCTAssertTrue(AppMenuSpec.saveItemTemplateItem(s).enabled)
    }
}
