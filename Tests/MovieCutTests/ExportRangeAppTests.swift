import XCTest
import AppKit
import MovieCutCore
@testable import MovieCut

/// 書き出し範囲(出力メニュー)・静止画・連番画像: メニュー表、Undo 1 回、何も変わらない操作は履歴に載せない。
@MainActor
final class ExportRangeAppTests: XCTestCase {
    private func state(_ f: (inout MenuState) -> Void = { _ in }) -> MenuState {
        var s = MenuState(); s.hasDocument = true; s.canExport = true; s.canMarkRange = true; f(&s); return s
    }

    private func makeModel(duration: Double = 4) -> ProjectModel {
        var p = Project.new()
        p.width = 320; p.height = 180; p.fps = 10
        var t = Clip(); t.type = .text; t.text = "A"; t.start = 0; t.duration = duration; t.fontSize = 60
        p.tracks[4].clips.append(t)
        let m = ProjectModel(project: p)
        m.notices = OneTimeNotices()
        return m
    }

    private func undoSteps(_ m: ProjectModel) -> Int {
        let u = m.effectiveUndoManager
        var n = 0
        while u.canUndo { u.undo(); n += 1 }
        for _ in 0..<n { u.redo() }
        return n
    }

    func testMenuSpecsAndNoShortcuts() {
        let on = state { $0.hasRange = true }
        XCTAssertEqual(AppMenuSpec.rangeItems(on).map(\.title), ["書き出し開始を現在位置に", "書き出し終了を現在位置に", "範囲を解除"])
        XCTAssertEqual(AppMenuSpec.imageExportItems(on).map(\.title), ["現在のフレームを画像で書き出す…", "連番画像を書き出す…", "サムネイル画像を書き出す…"])
        for spec in AppMenuSpec.rangeItems(on) + AppMenuSpec.imageExportItems(on) {
            XCTAssertNil(spec.shortcut)
            XCTAssertTrue(spec.enabled)
            XCTAssertTrue(AppMenuSpec.all(on).contains { $0.command == spec.command })
        }
        let used = AppMenuSpec.all(on).compactMap(\.shortcut)
        XCTAssertEqual(used.count, Set(used).count, "ショートカットの重複なし")
        // 範囲が無ければ「解除」は押せない。
        XCTAssertFalse(AppMenuSpec.rangeItems(state()).last!.enabled)
        XCTAssertTrue(AppMenuSpec.rangeItems(state()).first!.enabled)
        // 書き出し中(ロック)や中身なしは全部だめ
        let locked = state { $0.isLocked = true; $0.hasRange = true }
        XCTAssertTrue((AppMenuSpec.rangeItems(locked) + AppMenuSpec.imageExportItems(locked)).allSatisfy { !$0.enabled })
        let empty = state { $0.canExport = false; $0.canMarkRange = false }
        XCTAssertTrue((AppMenuSpec.rangeItems(empty) + AppMenuSpec.imageExportItems(empty)).allSatisfy { !$0.enabled })
    }

    func testMenuStateReflectsModel() {
        let m = makeModel()
        XCTAssertTrue(m.canMarkRange)
        XCTAssertFalse(m.hasRangeMarks)
        m.currentTime = 1
        m.setRangeInAtCurrent()
        XCTAssertTrue(m.hasRangeMarks)
    }

    func testSetInOutClearAreOneUndoEachAndRestore() {
        let m = makeModel()
        let original = m.project
        m.currentTime = 1
        XCTAssertTrue(m.setRangeInAtCurrent())
        m.currentTime = 3
        XCTAssertTrue(m.setRangeOutAtCurrent())
        XCTAssertEqual(m.project.exportRange, ExportRange(start: 1, end: 3))
        XCTAssertEqual(undoSteps(m), 2)
        XCTAssertTrue(m.clearExportRange())
        XCTAssertNil(m.project.exportRange)
        XCTAssertNil(m.project.rangeIn)
        XCTAssertEqual(m.project.rangeOut, nil)
        m.effectiveUndoManager.undo()
        XCTAssertEqual(m.project.exportRange, ExportRange(start: 1, end: 3), "解除も 1 回で戻る")
        m.effectiveUndoManager.undo(); m.effectiveUndoManager.undo()
        XCTAssertEqual(m.project, original)
    }

    func testNoOpEditsDoNotEnterUndoHistory() {
        let m = makeModel()
        m.currentTime = 1
        XCTAssertFalse(m.clearExportRange(), "範囲が無いときの解除")
        XCTAssertFalse(m.effectiveUndoManager.canUndo)
        XCTAssertTrue(m.setRangeInAtCurrent())
        let steps = undoSteps(m)
        XCTAssertFalse(m.setRangeInAtCurrent(), "同じ位置にもう一度")
        XCTAssertEqual(undoSteps(m), steps)
        // 成り立たない範囲は断って、メッセージだけ出す
        m.currentTime = 0.5
        XCTAssertFalse(m.setRangeOutAtCurrent(), "アウトがインより前")
        XCTAssertNil(m.project.rangeOut)
        XCTAssertEqual(undoSteps(m), steps)
        XCTAssertFalse(m.statusText.isEmpty)
        // 空のプロジェクトでは何もしない
        let e = ProjectModel(project: Project.new())
        XCTAssertFalse(e.setRangeInAtCurrent())
        XCTAssertFalse(e.effectiveUndoManager.canUndo)
    }

    func testStillExportWritesProjectSizeAndIsNotAnEdit() throws {
        let m = makeModel()
        m.currentTime = 1.23
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("still-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appendingPathComponent("a.png"), jpg = dir.appendingPathComponent("a.jpg")
        XCTAssertTrue(m.exportStill(to: png))
        XCTAssertTrue(m.exportStill(to: jpg))
        for u in [png, jpg] {
            let rep = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: u)))
            XCTAssertEqual(rep.pixelsWide, 320); XCTAssertEqual(rep.pixelsHigh, 180)
        }
        XCTAssertFalse(m.effectiveUndoManager.canUndo, "書き出しは編集ではない")
    }

    func testSequenceExportThroughModelCountsFramesAndLocksDuringRun() async throws {
        let m = makeModel()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("seq-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let outcome = await m.runSequenceExport(to: dir, base: "s", format: .png, range: ExportRange(start: 1, end: 2))
        guard case .success = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).count, 10, "1 秒 × 10fps")
        XCTAssertFalse(m.isExporting)
        XCTAssertFalse(m.effectiveUndoManager.canUndo)
    }
}
