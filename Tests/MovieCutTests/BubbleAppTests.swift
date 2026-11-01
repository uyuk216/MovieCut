import XCTest
import MovieCutCore
@testable import MovieCut

/// B-2 吹き出し: モデルの操作(1 操作 = 1 Undo・変わらなければ履歴に載らない)と、保存したスタイルへの統合。
@MainActor
final class BubbleAppTests: XCTestCase {
    private func makeModel() -> ProjectModel {
        var p = Project.new()
        p.fps = 60
        var t = Clip(); t.id = "t"; t.type = .text; t.start = 0; t.duration = 4; t.text = "テキスト"; t.fontSize = 80
        var i = Clip(); i.id = "i"; i.type = .image; i.start = 5; i.duration = 2; i.src = "/tmp/none.png"
        p.tracks[0].clips = [t, i]
        let m = ProjectModel(project: p)
        m.notices = OneTimeNotices()
        return m
    }

    private func undoAll(_ m: ProjectModel) -> Int {
        var n = 0
        while m.effectiveUndoManager.canUndo { m.effectiveUndoManager.undo(); n += 1 }
        return n
    }

    func testAddEditAndRemoveEachAreOneUndoStep() {
        let m = makeModel()
        m.setBubble(Bubble(), name: "吹き出しを付ける", clipId: "t")
        XCTAssertEqual(m.clip("t")?.bubble, Bubble())
        m.editBubble({ $0.shape = "cloud" }, name: "吹き出しの形の変更", clipId: "t")
        XCTAssertEqual(m.clip("t")?.bubble?.shape, "cloud")
        m.coalescedBubble({ $0.fill = "#ff0000" }, name: "吹き出しの塗りの変更", clipId: "t")
        m.coalescedBubble({ $0.fill = "#00ff00" }, name: "吹き出しの塗りの変更", clipId: "t")
        XCTAssertEqual(m.clip("t")?.bubble?.fill, "#00ff00")
        m.setBubble(nil, name: "吹き出しを外す", clipId: "t")
        XCTAssertNil(m.clip("t")?.bubble)
        // 付ける・形・塗り(連続は 1 回)・外す = 4 回
        XCTAssertEqual(undoAll(m), 4)
        XCTAssertNil(m.clip("t")?.bubble)
    }

    func testNoOpsRegisterNothingAndOnlyTextClipsGetBubbles() {
        let m = makeModel()
        m.setBubble(nil, name: "吹き出しを外す", clipId: "t")                 // 無いものを外す
        m.editBubble({ $0.shape = "rect" }, name: "形", clipId: "t")          // 吹き出しが無いときは編集しない
        m.coalescedBubble({ $0.fill = "#000000" }, name: "塗り", clipId: "t")
        m.setBubble(Bubble(), name: "付ける", clipId: "i")                    // 画像には付かない
        XCTAssertFalse(m.effectiveUndoManager.canUndo)
        m.setBubble(Bubble(), name: "付ける", clipId: "t")
        m.setBubble(Bubble(), name: "同じ", clipId: "t")                      // 変わらない
        m.editBubble({ $0.shape = Bubble().shape }, name: "同じ", clipId: "t")
        XCTAssertEqual(undoAll(m), 1)
        XCTAssertNil(m.clip("i")?.bubble)
    }

    func testPresetBubbleAndSavedLookCarryTheBubble() {
        let m = makeModel()
        m.selectedClipId = "t"
        XCTAssertTrue(m.applyTextStyle(id: "builtin.bubble"))
        XCTAssertEqual(m.effectiveUndoManager.undoActionName, "スタイルを適用: 吹き出し風")
        XCTAssertEqual(m.clip("t")?.bubble?.fill, "#ffffff")
        // 装飾と同じく、別のスタイルを当てると吹き出しは丸ごと入れ替わる(標準は吹き出しなし)
        XCTAssertTrue(m.applyTextStyle(id: "builtin.standard"))
        XCTAssertNil(m.clip("t")?.bubble)
        XCTAssertEqual(undoAll(m), 2)
        // いまの見た目を保存すると吹き出しも入る
        m.setBubble(Bubble(shape: "cloud"), name: "付ける", clipId: "t")
        let look = TextLook(of: m.clip("t")!)
        XCTAssertEqual(look.bubble?.shape, "cloud")
        var other = Clip(); other.type = .text
        XCTAssertTrue(look.apply(to: &other))
        XCTAssertEqual(other.bubble?.shape, "cloud")
    }

    func testBubbleSurvivesProjectSaveAndOldFilesStayUnchanged() throws {
        let m = makeModel()
        m.setBubble(Bubble(shape: "rect", tailChar: nil), name: "付ける", clipId: "t")
        let data = try JSONEncoder().encode(m.project)
        let back = try JSONDecoder().decode(Project.self, from: data)
        XCTAssertEqual(back.allClips.first { $0.id == "t" }?.bubble?.shape, "rect")
        // 画像クリップには吹き出しの項目を書かない
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(json.components(separatedBy: "\"bubble\"").count - 1, 1)
    }
}
