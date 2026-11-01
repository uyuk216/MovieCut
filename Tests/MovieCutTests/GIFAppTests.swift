import XCTest
import ImageIO
import MovieCutCore
@testable import MovieCut

/// 出力 ▸ GIFとして書き出す…: メニュー表(ショートカットなし・重複なし)と、モデル経由の書き出し(書き出しシート・キャンセル・Undo に載らない)。
@MainActor
final class GIFAppTests: XCTestCase {
    private func state(_ f: (inout MenuState) -> Void = { _ in }) -> MenuState {
        var s = MenuState(); s.hasDocument = true; s.canExport = true; f(&s); return s
    }

    private func makeModel(duration: Double = 3) -> ProjectModel {
        var p = Project.new()
        p.width = 320; p.height = 180; p.fps = 30
        var t = Clip(); t.type = .text; t.text = "G"; t.start = 0; t.duration = duration; t.fontSize = 60
        p.tracks[4].clips.append(t)
        let m = ProjectModel(project: p)
        m.notices = OneTimeNotices()
        return m
    }

    private var tmpDir: URL { FileManager.default.temporaryDirectory.appendingPathComponent("gifapp-\(UUID().uuidString)") }

    func testMenuItemSpec() {
        let s = state()
        let spec = AppMenuSpec.gifExport(s)
        XCTAssertEqual(spec.title, "GIFとして書き出す…")
        XCTAssertNil(spec.shortcut, "ショートカットは持たない")
        XCTAssertTrue(spec.enabled)
        XCTAssertTrue(AppMenuSpec.all(s).contains { $0.command == .exportGIF })
        let used = AppMenuSpec.all(s).compactMap(\.shortcut)
        XCTAssertEqual(used.count, Set(used).count, "ショートカットの重複なし")
        XCTAssertFalse(AppMenuSpec.gifExport(state { $0.isLocked = true }).enabled, "書き出し中は押せない")
        XCTAssertFalse(AppMenuSpec.gifExport(state { $0.canExport = false }).enabled, "中身が無いときは押せない")
    }

    func testGIFOptionPresetsMatchTheSheet() {
        XCTAssertEqual(GIFOptions.presetFPS, [5, 10, 15, 20, 30])
        XCTAssertEqual(GIFOptions.presetWidths, [320, 480, 640])
        XCTAssertTrue(GIFOptions.presetFPS.contains(GIFOptions.standard.fps))
        XCTAssertTrue(GIFOptions.presetWidths.contains(GIFOptions.standard.maxWidth ?? -1))
    }

    func testRunGIFExportThroughModelWritesFileAndIsNotAnEdit() async throws {
        let m = makeModel(duration: 2)
        let dir = tmpDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("m.gif")
        let outcome = await m.runGIFExport(to: out, options: GIFOptions(fps: 10, maxWidth: 160), range: nil)
        guard case .success(let url) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(url, out)
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(out as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(src), 20, "2 秒 × 10 fps の実ファイルのコマ数")
        XCTAssertFalse(m.isExporting)
        XCTAssertFalse(m.effectiveUndoManager.canUndo, "書き出しは編集ではない")
    }

    func testRangeIsUsedByModelExport() async throws {
        let m = makeModel(duration: 4)
        m.currentTime = 1
        XCTAssertTrue(m.setRangeInAtCurrent())
        m.currentTime = 2
        XCTAssertTrue(m.setRangeOutAtCurrent())
        let dir = tmpDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("r.gif")
        let outcome = await m.runGIFExport(to: out, options: GIFOptions(fps: 5, maxWidth: nil), range: m.project.exportRange)
        guard case .success = outcome else { return XCTFail("\(outcome)") }
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(out as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(src), 5, "範囲 1 秒 × 5 fps")
    }

    func testCancelFromModelReportsCancelledAndLeavesNoFile() async throws {
        let m = makeModel(duration: 60)
        let dir = tmpDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("c.gif")
        let task = Task { @MainActor in await m.runGIFExport(to: out, options: GIFOptions(fps: 10, maxWidth: 320), range: nil) }
        // 書き出しシートが出て、進み具合が動き出すまで待つ
        for _ in 0..<2000 where !(m.isExporting && m.exportProgress > 0) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        m.cancelExport()
        let outcome = await task.value
        guard case .cancelled = outcome else { return XCTFail("キャンセルのはず: \(outcome)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
        XCTAssertFalse(m.isExporting)
    }
}
