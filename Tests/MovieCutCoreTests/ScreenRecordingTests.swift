import XCTest
@testable import MovieCutCore

/// 画面収録(X-3)の純粋な部分: 状態遷移・設定の検証・範囲の切り詰め・名前付け。
/// 実物のキャプチャや許可には依存しない。
final class ScreenRecordingTests: XCTestCase {

    private func displayTarget() -> ScreenCaptureTarget {
        ScreenCaptureTarget(kind: .display, displayID: 1, title: "ディスプレイ 1", displayWidth: 1920, displayHeight: 1080)
    }

    // MARK: 状態遷移

    func testStateMachineHappyPath() {
        var m = ScreenRecordingStateMachine()
        XCTAssertEqual(m.phase, .idle)
        XCTAssertTrue(m.canStart)
        XCTAssertFalse(m.canStop)
        XCTAssertTrue(m.transition(to: .preparing))
        XCTAssertTrue(m.transition(to: .recording))
        XCTAssertTrue(m.canStop)
        XCTAssertFalse(m.canStart)
        XCTAssertTrue(m.transition(to: .stopping))
        XCTAssertTrue(m.transition(to: .finished))
        XCTAssertTrue(m.canStart)
        XCTAssertTrue(m.transition(to: .idle))
    }

    func testStateMachineRejectsInvalidTransitions() {
        var m = ScreenRecordingStateMachine()
        XCTAssertFalse(m.transition(to: .recording))   // idle からいきなり収録中にはならない
        XCTAssertFalse(m.transition(to: .finished))
        XCTAssertFalse(m.transition(to: .stopping))
        XCTAssertEqual(m.phase, .idle)
        XCTAssertTrue(m.transition(to: .preparing))
        XCTAssertFalse(m.transition(to: .stopping))    // 準備中は止められない
        XCTAssertTrue(m.transition(to: .failed))       // 準備の失敗は許す
        XCTAssertTrue(m.transition(to: .preparing))    // 失敗からは再試行できる
        XCTAssertTrue(m.transition(to: .recording))
        XCTAssertFalse(m.transition(to: .preparing))
        XCTAssertFalse(m.transition(to: .finished))    // 停止を経ずに完了にはならない
        XCTAssertEqual(m.phase, .recording)
    }

    func testStateMachineReset() {
        var m = ScreenRecordingStateMachine()
        _ = m.transition(to: .preparing)
        _ = m.transition(to: .recording)
        m.reset()
        XCTAssertEqual(m.phase, .idle)
        XCTAssertFalse(m.isActive)
    }

    // MARK: 設定の検証

    func testValidateDisplayOK() {
        let s = ScreenRecordingSettings(target: displayTarget())
        XCTAssertNil(s.validate())
    }

    func testValidateDisplayMissing() {
        var t = displayTarget(); t.displayID = 0
        let s = ScreenRecordingSettings(target: t)
        XCTAssertEqual(s.validate(), .noTargetAvailable)
    }

    func testValidateWindowRequiresID() {
        let t = ScreenCaptureTarget(kind: .window, displayID: 0, windowID: 0, title: "x")
        XCTAssertEqual(ScreenRecordingSettings(target: t).validate(), .noTargetAvailable)
        let ok = ScreenCaptureTarget(kind: .window, displayID: 0, windowID: 42, title: "x")
        XCTAssertNil(ScreenRecordingSettings(target: ok).validate())
    }

    func testValidateRegionTooSmall() {
        var t = displayTarget(); t.kind = .region
        t.region = ScreenRecordingRegion(x: 0, y: 0, width: 8, height: 100)
        guard case .invalidRegion = ScreenRecordingSettings(target: t).validate() else {
            return XCTFail("小さい範囲は invalidRegion のはず")
        }
    }

    func testValidateRegionOutsideDisplay() {
        var t = displayTarget(); t.kind = .region
        t.region = ScreenRecordingRegion(x: 5000, y: 0, width: 200, height: 200)
        guard case .invalidRegion = ScreenRecordingSettings(target: t).validate() else {
            return XCTFail("画面外の範囲は invalidRegion のはず")
        }
    }

    func testValidateRegionOKAndClamp() {
        var t = displayTarget(); t.kind = .region
        t.region = ScreenRecordingRegion(x: 1800, y: 900, width: 400, height: 400)
        let s = ScreenRecordingSettings(target: t)
        XCTAssertNil(s.validate())
        let clamped = s.clampedToDisplay
        XCTAssertEqual(clamped.target.region?.width, 120)   // 1920 - 1800
        XCTAssertEqual(clamped.target.region?.height, 180)  // 1080 - 900
    }

    func testRegionClampedNoOverlap() {
        let r = ScreenRecordingRegion(x: 3000, y: 0, width: 200, height: 200)
        XCTAssertNil(r.clamped(toDisplayWidth: 1920, height: 1080))
    }

    func testFpsClampedInInit() {
        XCTAssertEqual(ScreenRecordingSettings(target: displayTarget(), fps: 0).fps, ScreenRecordingSettings.fpsRange.lowerBound)
        XCTAssertEqual(ScreenRecordingSettings(target: displayTarget(), fps: 999).fps, ScreenRecordingSettings.fpsRange.upperBound)
        XCTAssertEqual(ScreenRecordingSettings(target: displayTarget(), fps: 30).fps, 30)
    }

    func testOutputPixelSizeEven() {
        let odd = ScreenCaptureTarget(kind: .display, displayID: 1, title: "d", displayWidth: 1921, displayHeight: 1081)
        XCTAssertEqual(odd.outputPixelSize?.width, 1920)
        XCTAssertEqual(odd.outputPixelSize?.height, 1080)
        var region = displayTarget(); region.kind = .region
        region.region = ScreenRecordingRegion(x: 0, y: 0, width: 641, height: 361)
        XCTAssertEqual(region.outputPixelSize?.width, 640)
        XCTAssertEqual(region.outputPixelSize?.height, 360)
    }

    // MARK: エラーの案内

    func testPermissionErrorHasGuidance() {
        let e = ScreenRecordingError.permissionDenied
        XCTAssertFalse(e.message.isEmpty)
        XCTAssertNotNil(e.guidance)
        XCTAssertTrue(e.guidance!.contains("画面収録"))
        XCTAssertNil(ScreenRecordingError.alreadyRunning.guidance)
    }

    // MARK: 名前付け

    func testFileNaming() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let date = cal.date(from: DateComponents(year: 2026, month: 11, day: 19, hour: 12, minute: 3, second: 4))!
        // DateFormatter は実行環境のタイムゾーンで整形するので、名前の形だけを見る
        let name = ScreenRecordingFileNaming.baseName(for: date)
        XCTAssertTrue(name.hasPrefix("画面収録 "))
        let dir = URL(fileURLWithPath: "/tmp/rec")
        let first = ScreenRecordingFileNaming.outputURL(in: dir, date: date) { _ in false }
        XCTAssertEqual(first.pathExtension, "mov")
        let second = ScreenRecordingFileNaming.outputURL(in: dir, date: date) { $0 == first }
        XCTAssertTrue(second.lastPathComponent.contains("-2"))
    }

    func testElapsedText() {
        XCTAssertEqual(ScreenRecordingFileNaming.elapsedText(0), "0:00")
        XCTAssertEqual(ScreenRecordingFileNaming.elapsedText(7.9), "0:07")
        XCTAssertEqual(ScreenRecordingFileNaming.elapsedText(65), "1:05")
        XCTAssertEqual(ScreenRecordingFileNaming.elapsedText(3723), "1:02:03")
    }
}
