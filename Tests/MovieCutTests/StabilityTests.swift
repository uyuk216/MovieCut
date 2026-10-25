import XCTest
import AppKit
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
