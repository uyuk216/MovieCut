import XCTest
import MovieCutCore
@testable import MovieCut

/// テンプレートの差し替え項目(スロット)の画面配線: 値付き作成・値付き適用・スロット付き保存。
@MainActor
final class TemplateSlotsAppTests: XCTestCase {
    private func textTemplate() -> ItemTemplate {
        var c = Clip(); c.type = .text; c.text = "題"; c.color = "#FFFFFF"; c.fontSize = 90; c.duration = 3
        let slots = ItemTemplate.suggestedSlots(for: c)
        return ItemTemplate.capture(name: "題字", from: c, slots: slots)!
    }

    private func model() -> ProjectModel {
        var p = Project()
        p.tracks = [Track(name: "映像")]
        return ProjectModel(project: p)
    }

    func testCreateWithValuesReplacesTextAndColor() throws {
        let m = model()
        m.currentTime = 4
        let id = m.createClipFromItemTemplate(textTemplate(), values: ["text": "新しい題", "color": "#FF0000"])
        let clip = try XCTUnwrap(m.project.allClips.first { $0.id == id })
        XCTAssertEqual(clip.text, "新しい題")
        XCTAssertEqual(clip.color, "#FF0000")
        XCTAssertEqual(clip.fontSize, 90)
        XCTAssertEqual(clip.start, 4, accuracy: 0.001)
        XCTAssertEqual(m.selectedClipId, id)
    }

    func testCreateWithoutValuesKeepsSavedValues() throws {
        let m = model()
        let id = m.createClipFromItemTemplate(textTemplate(), values: [:])
        let clip = try XCTUnwrap(m.project.allClips.first { $0.id == id })
        XCTAssertEqual(clip.text, "題")
        XCTAssertEqual(clip.color, "#FFFFFF")
    }

    func testCreateWithInvalidColorKeepsDefaultAndNotesInStatus() throws {
        let m = model()
        let id = m.createClipFromItemTemplate(textTemplate(), values: ["color": "red"])
        let clip = try XCTUnwrap(m.project.allClips.first { $0.id == id })
        XCTAssertEqual(clip.color, "#FFFFFF")
        XCTAssertTrue(m.statusText.contains("不正"))
    }

    func testBuiltinCreateWithEmptyValuesStillWorks() {
        let m = model()
        let id = m.createClipFromItemTemplate(named: "ぼかし・標準", values: [:])
        XCTAssertNotNil(id)
        XCTAssertEqual(m.project.allClips.first { $0.id == id }?.type, .blur)
    }

    func testApplyWithValuesIsOneUndoAndReplacesContent() throws {
        let m = model()
        var text = Clip(); text.type = .text; text.text = "旧"; text.color = "#000000"; text.fontSize = 30; text.duration = 2
        XCTAssertTrue(m.edit("追加") { $0.tracks[0].clips.append(text) })
        m.selectedClipId = text.id
        XCTAssertTrue(m.applyItemTemplate(textTemplate(), values: ["text": "新", "color": "#00FF00"]))
        let c = try XCTUnwrap(m.project.allClips.first { $0.id == text.id })
        XCTAssertEqual(c.text, "新")
        XCTAssertEqual(c.color, "#00FF00")
        XCTAssertEqual(c.fontSize, 90)
        m.effectiveUndoManager.undo()
        XCTAssertEqual(m.project.allClips.first { $0.id == text.id }?.text, "旧")
    }

    func testApplyWithoutValuesKeepsExistingText() throws {
        let m = model()
        var text = Clip(); text.type = .text; text.text = "旧"; text.fontSize = 30; text.duration = 2
        XCTAssertTrue(m.edit("追加") { $0.tracks[0].clips.append(text) })
        m.selectedClipId = text.id
        XCTAssertTrue(m.applyItemTemplate(textTemplate(), values: [:]))
        XCTAssertEqual(m.project.allClips.first { $0.id == text.id }?.text, "旧")
    }

    func testSaveWithSlotsPersistsAndSaveWithoutSlotsOmitsKey() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MovieCutTemplateSlotsAppTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ItemTemplateStore(directory: dir)
        let m = model()
        var clip = Clip(); clip.type = .text; clip.text = "題"; clip.color = "#FFFFFF"
        XCTAssertEqual(m.saveItemTemplate(named: "付き", from: clip, slots: ItemTemplate.suggestedSlots(for: clip), store: store), "付き")
        XCTAssertEqual(m.saveItemTemplate(named: "無し", from: clip, store: store), "無し")
        let loaded = store.load()
        XCTAssertEqual(loaded.first { $0.name == "付き" }?.slots.map(\.id), ["text", "color"])
        XCTAssertEqual(loaded.first { $0.name == "無し" }?.slots, [])
    }
}
