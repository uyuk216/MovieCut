import XCTest
import AppKit
import MovieCutCore
@testable import MovieCut

/// M6b: 起動時のウィンドウ数・Dock の reopen・ウィンドウ位置の補正と記憶・固まりの記録。
final class StabilityTests: XCTestCase {
    private func blank() -> LaunchDocInfo { .init(isUntitled: true, isPristine: true) }
    private func file() -> LaunchDocInfo { .init(isUntitled: false, isPristine: true) }
    private func editedUntitled() -> LaunchDocInfo { .init(isUntitled: true, isPristine: false) }

    func testPlainLaunchKeepsOneBlank() {
        XCTAssertEqual(LaunchWindowPolicy.indicesToClose([blank()]), [])
        XCTAssertEqual(LaunchWindowPolicy.indicesToClose([blank(), blank(), blank()]), [1, 2])
    }

    func testLaunchWithDocumentClosesBlanks() {
        XCTAssertEqual(LaunchWindowPolicy.indicesToClose([blank(), file()]), [0])
        XCTAssertEqual(LaunchWindowPolicy.indicesToClose([blank(), file(), blank()]), [0, 2])
        XCTAssertEqual(LaunchWindowPolicy.indicesToClose([blank(), editedUntitled()]), [0], "復元された編集済みの名称未設定は残す")
        XCTAssertEqual(LaunchWindowPolicy.indicesToClose([]), [])
    }

    func testReopen() {
        XCTAssertTrue(ReopenPolicy.shouldOpenNewDocument(hasVisibleWindows: false, documentCount: 0))
        XCTAssertFalse(ReopenPolicy.shouldOpenNewDocument(hasVisibleWindows: false, documentCount: 1), "最小化中の書類があるなら新規は作らない")
        XCTAssertFalse(ReopenPolicy.shouldOpenNewDocument(hasVisibleWindows: true, documentCount: 1))
    }

    private let screen = NSRect(x: 0, y: 0, width: 1920, height: 1080)
    private let minSize = NSSize(width: 1100, height: 728)

    func testSanitizeKeepsGoodFrame() {
        let f = NSRect(x: 200, y: 100, width: 1300, height: 800)
        XCTAssertEqual(WindowFramePolicy.sanitize(f, minSize: minSize, visibleFrames: [screen]), f)
    }

    func testSanitizeOffscreenGoesToCenter() {
        let f = NSRect(x: -30000, y: -30000, width: 1200, height: 800)
        let r = WindowFramePolicy.sanitize(f, minSize: minSize, visibleFrames: [screen])
        XCTAssertEqual(r.midX, screen.midX, accuracy: 1)
        XCTAssertEqual(r.midY, screen.midY, accuracy: 1)
        XCTAssertEqual(r.size, f.size)
    }

    func testSanitizeMonitorRemovedAndMinSize() {
        // 2 枚目の画面(x=1920〜)が無くなった
        let f = NSRect(x: 2500, y: 100, width: 600, height: 300)
        let r = WindowFramePolicy.sanitize(f, minSize: minSize, visibleFrames: [screen])
        XCTAssertGreaterThanOrEqual(r.width, minSize.width)
        XCTAssertGreaterThanOrEqual(r.height, minSize.height)
        XCTAssertTrue(screen.contains(r))
    }

    func testSanitizeTooBigFitsScreen() {
        let r = WindowFramePolicy.sanitize(NSRect(x: -100, y: -100, width: 5000, height: 4000), minSize: minSize, visibleFrames: [screen])
        XCTAssertTrue(screen.contains(r))
    }

    func testSanitizeNoScreensIsIdentity() {
        let f = NSRect(x: 5, y: 5, width: 1200, height: 800)
        XCTAssertEqual(WindowFramePolicy.sanitize(f, minSize: minSize, visibleFrames: []), f)
    }

    func testFrameMemoryPerDocumentAndFallback() {
        let d = UserDefaults(suiteName: "moviecut.test.\(UUID().uuidString)")!
        let url = URL(fileURLWithPath: "/tmp/a.mcpjc")
        XCTAssertNil(WindowFramePolicy.load(forDocument: url, defaults: d))
        WindowFramePolicy.save(NSRect(x: 10, y: 20, width: 1200, height: 800), forDocument: url, defaults: d)
        XCTAssertEqual(WindowFramePolicy.load(forDocument: url, defaults: d), NSRect(x: 10, y: 20, width: 1200, height: 800))
        // 別の書類・新規は「最後に使った」
        WindowFramePolicy.save(NSRect(x: 30, y: 40, width: 1400, height: 900), forDocument: nil, defaults: d)
        XCTAssertEqual(WindowFramePolicy.load(forDocument: nil, defaults: d)?.size, NSSize(width: 1400, height: 900))
        XCTAssertEqual(WindowFramePolicy.load(forDocument: url, defaults: d)?.size, NSSize(width: 1200, height: 800), "書類ごとの記録が優先")
    }

    func testStallTracker() {
        var t = StallTracker()
        t.pinged(at: 0); XCTAssertNil(t.answered(at: 0.05))
        t.pinged(at: 1); XCTAssertFalse(t.shouldSample(now: 1.2))
        XCTAssertTrue(t.shouldSample(now: 1.31))
        XCTAssertFalse(t.shouldSample(now: 1.4), "1 回のストールで sample は 1 回")
        let s = t.answered(at: 1.5)
        XCTAssertEqual(s?.duration ?? 0, 0.5, accuracy: 1e-9)
        XCTAssertEqual(t.stalls.count, 1)
        XCTAssertTrue(t.summary.contains("stalls=1"))
        t.pinged(at: 2); XCTAssertNil(t.answered(at: 2.05))
        XCTAssertEqual(t.stalls.count, 1)
    }
}

/// 自動保存の写し(復元フォルダへの書き出し・消去)。利用者のファイルには触れない。
@MainActor
final class AutosaveRecoveryAppTests: XCTestCase {
    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("rec-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func testWritesRecoveryOnlyWhenEditedAndRemovesWhenSaved() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let m = ProjectModel(project: Project.new())
        m.notices = OneTimeNotices()
        let file = dir.appendingPathComponent(AutosaveRecovery.fileName(sessionID: m.recoverySessionID))

        m.autosaveTick(directory: dir, edited: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "編集していなければ写さない")

        var c = Clip(); c.type = .text; c.text = "未保存"; c.duration = 1
        var t = Track(name: "文字"); t.clips = [c]
        m.project.tracks = [t]
        m.autosaveTick(directory: dir, edited: true)
        let e = try AutosaveRecovery.decode(Data(contentsOf: file))
        XCTAssertEqual(e.name, "無題")
        XCTAssertNil(e.originalPath)
        XCTAssertEqual(try Project.decode(from: e.project), m.project)

        m.autosaveTick(directory: dir, edited: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "保存済みになったら写しを消す")
    }

    func testRestoredProjectIsKeptAsRecoveryUntilClosed() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let m = ProjectModel(project: Project.new())
        m.restoredFromRecovery = true
        m.autosaveTick(directory: dir, edited: m.restoredFromRecovery)
        let file = dir.appendingPathComponent(AutosaveRecovery.fileName(sessionID: m.recoverySessionID))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testRecoveryListSkipsBrokenFilesAndSortsByTime() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let late = AutosaveRecovery.Entry(name: "b", originalPath: nil, savedAt: Date(timeIntervalSince1970: 200), project: try Project.new().encoded())
        let early = AutosaveRecovery.Entry(name: "a", originalPath: nil, savedAt: Date(timeIntervalSince1970: 100), project: try Project.new().encoded())
        try AutosaveRecovery.encode(late).write(to: dir.appendingPathComponent("x.mcrecover"))
        try AutosaveRecovery.encode(early).write(to: dir.appendingPathComponent("y.mcrecover"))
        try Data("壊れている".utf8).write(to: dir.appendingPathComponent("z.mcrecover"))
        try Data("other".utf8).write(to: dir.appendingPathComponent("keep.txt"))
        let list = RecoveryFolder.list(in: dir)
        XCTAssertEqual(list.map(\.entry.name), ["a", "b"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("z.mcrecover").path), "壊れた写しは捨てる")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("keep.txt").path))
    }

    func testInboxHandsOutProjectsInOrder() {
        let a = Project.new(); var b = Project.new(); b.markers = [Marker(time: 1, name: "b")]
        RecoveryInbox.set([a, b])
        XCTAssertEqual(RecoveryInbox.take(), a)
        XCTAssertEqual(RecoveryInbox.take(), b)
        XCTAssertNil(RecoveryInbox.take())
    }
}

/// 欠けた素材: 書き出しの停止と、場所の再指定(1 回で Undo)。
@MainActor
final class MissingMediaAppTests: XCTestCase {
    func testExportIsBlockedAndRelinkIsOneUndoStep() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let real = dir.appendingPathComponent("clip.png")
        try Data([0x89, 0x50]).write(to: real)
        let m = ProjectModel(project: Project.new())
        m.notices = OneTimeNotices()
        var c = Clip(); c.type = .image; c.src = dir.appendingPathComponent("gone/clip.png").path; c.duration = 1
        var t = Track(name: "映像"); t.clips = [c]
        m.project.tracks = [t]

        XCTAssertTrue(m.reportMissingMediaForExport())
        XCTAssertEqual(m.errorTitle, "書き出せません(素材が見つかりません)")
        XCTAssertTrue(m.errorMessage?.contains("clip.png") == true)
        XCTAssertEqual(m.relinkMedia(in: dir), 1)
        XCTAssertEqual(URL(fileURLWithPath: m.project.tracks[0].clips[0].src ?? "").resolvingSymlinksInPath(), real.resolvingSymlinksInPath())
        XCTAssertEqual(m.effectiveUndoManager.undoActionName, "素材の場所の再指定")
        m.effectiveUndoManager.undo()
        XCTAssertEqual(m.project.tracks[0].clips[0].src, c.src)
        XCTAssertFalse(m.effectiveUndoManager.canUndo, "再指定は 1 回分の Undo だけ")
    }
}

/// ルーラーで書き出し範囲の印を動かす(1 回の Undo)と、範囲ループ再生の切り替え。
@MainActor
final class RangeDragLoopAppTests: XCTestCase {
    func testDraggingRangeOutEdgeOnRulerIsOneUndoStep() {
        let m = ProjectModel(project: Project.new())
        m.notices = OneTimeNotices()
        m.edit("準備") { $0.rangeIn = 1; $0.rangeOut = 4 }
        var c = Clip(); c.type = .text; c.text = "x"; c.start = 0; c.duration = 10
        var t = Track(name: "文字"); t.clips = [c]
        m.edit("クリップ") { $0.tracks = [t] }
        let um = m.effectiveUndoManager
        let canvas = TimelineCanvas(frame: NSRect(x: 0, y: 0, width: 1000, height: 300))
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = canvas
        canvas.model = m
        canvas.syncFromModel()
        defer { m.shutdown(); window.contentView = nil }
        let ry: CGFloat = 8
        let xo = canvas.geometry.x(forTime: 4)
        XCTAssertEqual(canvas.rangeEdgeHit(at: NSPoint(x: xo + 2, y: ry)), false, "アウト点を掴める")
        XCTAssertNil(canvas.rangeEdgeHit(at: NSPoint(x: canvas.geometry.x(forTime: 2.5), y: ry)), "離れていれば掴めない")
        canvas.mouseDown(at: NSPoint(x: xo + 2, y: ry))
        for i in 1...6 { canvas.mouseDragged(to: NSPoint(x: xo + 2 + CGFloat(i) * 20, y: ry)) }
        canvas.mouseUp()
        XCTAssertEqual(m.project.rangeOut ?? -1, canvas.geometry.time(forX: xo + 2 + 120), accuracy: 1e-6)
        XCTAssertEqual(m.project.rangeIn, 1, "イン点は動かない")
        XCTAssertEqual(um.undoActionName, "書き出し範囲の移動")
        um.undo()
        XCTAssertEqual(m.project.rangeOut, 4)
    }

    func testRangeLoopToggleAndActiveRange() {
        let m = ProjectModel(project: Project.new())
        m.notices = OneTimeNotices()
        XCTAssertNil(m.activeLoopRange)
        var c = Clip(); c.type = .text; c.text = "x"; c.start = 0; c.duration = 5
        var t = Track(name: "文字"); t.clips = [c]
        m.edit("範囲") { $0.tracks = [t]; $0.rangeIn = 1; $0.rangeOut = 3 }
        XCTAssertNil(m.activeLoopRange, "ループがオフのとき")
        m.rangeLoop.toggle()
        XCTAssertEqual(m.activeLoopRange, ExportRange(start: 1, end: 3))
        XCTAssertEqual(m.effectiveUndoManager.undoActionName, "範囲", "ループの切り替えは編集ではない")
    }
}
