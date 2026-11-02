import XCTest
import SwiftUI
import AppKit
import MovieCutCore
@testable import MovieCut

/// B3: 字幕の書き出し・読み込み(1 操作 = 1 Undo)、チャプターのコピー、メニューの項目表。
@MainActor
final class SubtitleAppTests: XCTestCase {
    private func state(_ f: (inout MenuState) -> Void = { _ in }) -> MenuState {
        var s = MenuState(); s.hasDocument = true; s.canExport = true; f(&s); return s
    }

    private func makeModel() -> ProjectModel {
        let m = ProjectModel(project: Project.new())
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

    private func tempFile(_ name: String, _ body: String) throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-\(name)")
        try body.write(to: u, atomically: true, encoding: .utf8)
        return u
    }

    func testImportIsOneUndoStep() throws {
        let m = makeModel()
        let before = m.project
        let url = try tempFile("a.srt", "\u{FEFF}1\r\n00:00:01,000 --> 00:00:02,000\r\nあ\r\n\r\n2\r\n00:00:01,500 --> 00:00:03,000\r\nい\r\n")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(m.importSubtitles(from: url, offset: 1))
        XCTAssertEqual(m.project.tracks.suffix(2).map(\.name), ["字幕", "字幕 2"])
        XCTAssertEqual(m.project.tracks.suffix(2).flatMap(\.clips).map(\.text), ["あ", "い"])
        XCTAssertEqual(m.project.tracks[m.project.tracks.count - 2].clips[0].start, 2)
        XCTAssertEqual(m.effectiveUndoManager.undoActionName, "字幕の読み込み")
        XCTAssertEqual(undoSteps(m), 1, "2 レイヤー・2 クリップでも Undo は 1 回")
        m.effectiveUndoManager.undo()
        XCTAssertEqual(m.project, before)
    }

    func testImportNothingDoesNotTouchUndo() throws {
        let m = makeModel()
        let url = try tempFile("e.vtt", "WEBVTT\n\nNOTE nothing\n")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertFalse(m.importSubtitles(from: url, offset: 0))
        XCTAssertFalse(m.effectiveUndoManager.canUndo)
        XCTAssertFalse(m.importSubtitles(from: URL(fileURLWithPath: "/nonexistent/x.srt"), offset: 0))
    }

    func testExportWritesFormatByExtension() throws {
        let m = makeModel()
        XCTAssertFalse(m.canExportSubtitles)
        XCTAssertTrue(m.importSubtitles(cues: [SubtitleCue(start: 0, end: 1.5, text: "あ\nい")], offset: 0))
        XCTAssertTrue(m.canExportSubtitles)
        let vtt = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).vtt")
        let srt = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).srt")
        defer { try? FileManager.default.removeItem(at: vtt); try? FileManager.default.removeItem(at: srt) }
        XCTAssertTrue(m.writeSubtitles(to: vtt))
        XCTAssertTrue(m.writeSubtitles(to: srt))
        XCTAssertEqual(try String(contentsOf: vtt, encoding: .utf8), "WEBVTT\n\n00:00:00.000 --> 00:00:01.500\nあ\nい\n\n")
        XCTAssertEqual(try String(contentsOf: srt, encoding: .utf8), "1\n00:00:00,000 --> 00:00:01,500\nあ\nい\n\n")
    }

    func testGenerateSubtitlesIsOneUndoStepAndIdempotent() {
        let m = makeModel()
        var v = Clip(); v.type = .voice; v.start = 1; v.duration = 2; v.text = "やあ"
        var tr = Track(name: "声"); tr.clips = [v]
        m.project.tracks = [tr]
        let before = m.project
        XCTAssertTrue(m.generateSubtitlesFromScript())
        XCTAssertEqual(m.effectiveUndoManager.undoActionName, "字幕の自動生成")
        XCTAssertEqual(undoSteps(m), 1)
        XCTAssertEqual(SubtitleFile.cues(from: m.project), [SubtitleCue(start: 1, end: 3, text: "やあ")])
        XCTAssertFalse(m.generateSubtitlesFromScript(), "生成済みなら何もしない")
        m.effectiveUndoManager.undo()
        XCTAssertEqual(m.project, before)
    }

    func testGenerateSubtitlesWithNothingToDoLeavesUndoAlone() {
        let m = makeModel()
        XCTAssertFalse(m.generateSubtitlesFromScript())
        XCTAssertFalse(m.effectiveUndoManager.canUndo)
    }

    func testCopyChaptersToPasteboard() {
        let m = makeModel()
        XCTAssertFalse(m.copyChapters(), "マーカーが無ければコピーしない")
        m.project.markers = [Marker(time: 0, name: "A"), Marker(time: 30, name: "B"), Marker(time: 60, name: "C")]
        NSPasteboard.general.clearContents()
        XCTAssertTrue(m.copyChapters())
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "0:00 A\n0:30 B\n1:00 C")
        XCTAssertFalse(m.effectiveUndoManager.canUndo, "コピーは編集ではない")
    }

    func testMenuSpecs() {
        let on = state { $0.canExportSubtitles = true; $0.hasMarkers = true }
        XCTAssertEqual(AppMenuSpec.subtitleImport(on).title, "字幕を読み込む…")
        XCTAssertEqual(AppMenuSpec.subtitleExport(on).title, "字幕を書き出す…")
        XCTAssertEqual(AppMenuSpec.chapterCopy(on).title, "チャプターをコピー")
        XCTAssertTrue(AppMenuSpec.subtitleImport(on).enabled && AppMenuSpec.subtitleExport(on).enabled && AppMenuSpec.chapterCopy(on).enabled)
        let off = state()
        XCTAssertTrue(AppMenuSpec.subtitleImport(off).enabled)
        XCTAssertFalse(AppMenuSpec.subtitleExport(off).enabled, "字幕にできるクリップが無い")
        XCTAssertFalse(AppMenuSpec.chapterCopy(off).enabled, "マーカーが無い")
        let locked = state { $0.isLocked = true; $0.canExportSubtitles = true; $0.hasMarkers = true }
        XCTAssertFalse(AppMenuSpec.subtitleImport(locked).enabled)
        XCTAssertFalse(AppMenuSpec.subtitleExport(locked).enabled)
        for spec in [AppMenuSpec.subtitleImport(on), AppMenuSpec.subtitleExport(on), AppMenuSpec.chapterCopy(on)] {
            XCTAssertNil(spec.shortcut, "ショートカットは持たない(重複・衝突を避ける)")
            XCTAssertTrue(AppMenuSpec.all(on).contains { $0.command == spec.command }, "all に入っている(重複テストの対象)")
        }
        let used = AppMenuSpec.all(on).compactMap(\.shortcut)
        XCTAssertEqual(used.count, Set(used).count)
    }
}

/// チャプターを色でコピー(出力メニュー)。
@MainActor
final class ChapterColorAppTests: XCTestCase {
    private func makeModel() -> ProjectModel {
        let m = ProjectModel(project: Project.new())
        m.notices = OneTimeNotices()
        var a = Marker(time: 0, name: "A"); a.color = "red"
        var b = Marker(time: 30, name: "B")
        var c = Marker(time: 60, name: "C"); c.color = "red"
        var d = Marker(time: 90, name: "D"); d.color = "red"
        m.project.markers = [a, b, c, d]
        return m
    }

    func testCopyByColorPutsOnlyThatColorOnPasteboardWithoutUndo() {
        let m = makeModel()
        NSPasteboard.general.clearContents()
        XCTAssertTrue(m.copyChapters(color: .red))
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "0:00 A\n1:00 C\n1:30 D")
        XCTAssertTrue(m.statusText.contains("赤のマーカーから"))
        XCTAssertFalse(m.effectiveUndoManager.canUndo, "コピーは編集ではない")
        NSPasteboard.general.clearContents()
        XCTAssertFalse(m.copyChapters(color: .blue), "その色が無ければコピーしない")
        XCTAssertNil(NSPasteboard.general.string(forType: .string))
        XCTAssertEqual(m.statusText, "青のマーカーがありません")
    }

    func testMenuItemsEnabledOnlyForColorsInUseWithReasonAndNoShortcut() {
        let m = makeModel()
        let s = MenuState(model: m)
        let items = AppMenuSpec.chapterColorItems(s)
        XCTAssertEqual(items.count, MarkerColor.allCases.count)
        XCTAssertEqual(Set(items.filter(\.enabled).map(\.title)), ["ティールのマーカーだけ", "赤のマーカーだけ"])
        XCTAssertTrue(items.allSatisfy { $0.shortcut == nil })
        let blue = items.first { $0.command == .copyChaptersColor(.blue) }!
        XCTAssertFalse(blue.enabled)
        XCTAssertEqual(AppMenuSpec.disabledReason(for: blue, state: s), "その色のマーカーがありません")
        let red = items.first { $0.command == .copyChaptersColor(.red) }!
        XCTAssertEqual(red.hint, "3 件")
        XCTAssertNil(AppMenuSpec.disabledReason(for: red, state: s))
        AppMenu.perform(.copyChaptersColor(.red), model: m)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "0:00 A\n1:00 C\n1:30 D")
    }
}
