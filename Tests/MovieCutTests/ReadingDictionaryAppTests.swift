import XCTest
import MovieCutCore
@testable import MovieCut

/// 読み辞書の編集画面の配線: モデル経由の保存がプロジェクトに入り、1 回の Undo になること。
@MainActor
final class ReadingDictionaryAppTests: XCTestCase {
    func testSetReadingDictionaryWithUndo() {
        let m = ProjectModel(project: .new())
        XCTAssertTrue(m.project.readingDictionary.isEmpty)
        m.setReadingDictionary([ReadingEntry(word: "相棒", reading: "あいぼう"),
                                ReadingEntry(word: "本音", reading: "ほんね")])
        XCTAssertEqual(m.project.readingDictionary.map { $0.word }, ["相棒", "本音"])
        // 同じ内容では Undo に積まない
        m.setReadingDictionary([ReadingEntry(word: "相棒", reading: "あいぼう"),
                                ReadingEntry(word: "本音", reading: "ほんね")])
        // 空にして消す
        m.setReadingDictionary([])
        XCTAssertTrue(m.project.readingDictionary.isEmpty)
        var steps = 0
        while m.effectiveUndoManager.canUndo { m.effectiveUndoManager.undo(); steps += 1 }
        XCTAssertEqual(steps, 2, "保存と消去の 2 回だけ")
        XCTAssertTrue(m.project.readingDictionary.isEmpty)
    }

    func testSetReadingDictionaryNormalizes() {
        let m = ProjectModel(project: .new())
        m.setReadingDictionary([ReadingEntry(word: "", reading: "x"),
                                ReadingEntry(word: "相棒", reading: ""),
                                ReadingEntry(word: "相棒", reading: "あいぼう"),
                                ReadingEntry(word: "相棒", reading: "あいぼー")])
        XCTAssertEqual(m.project.readingDictionary, [ReadingEntry(word: "相棒", reading: "あいぼう")],
                       "空の件は除き、同じ表記は最初の 1 件だけ")
    }

    func testDictionarySheetFlag() {
        let m = ProjectModel(project: .new())
        XCTAssertFalse(m.showDictionarySheet)
        m.openDictionarySheet()
        XCTAssertTrue(m.showDictionarySheet)
        let spec = AppMenuSpec.dictionaryItem(MenuState())
        XCTAssertEqual(spec.command, .readingDictionary)
        XCTAssertNil(spec.shortcut, "ショートカットは付けない")
    }
}
