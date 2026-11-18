import XCTest
import AppIntents
@testable import MovieCut
@testable import MovieCutCore

/// バッチS(画面収録 X-3 / Shortcuts・AppleScript X-4)のアプリ側テスト。
/// 実物のキャプチャや TCC の許可には依存しない(エンジンと許可判定を差し替える)。
final class PlatformIntegrationAppTests: XCTestCase {

    // MARK: 偽のエンジン

    final class FakeEngine: ScreenRecordingEngine {
        var targetsToReturn = ScreenRecordingTargets(
            displays: [ScreenCaptureTarget(kind: .display, displayID: 7, title: "ディスプレイ 7", displayWidth: 1920, displayHeight: 1080)],
            windows: [ScreenCaptureTarget(kind: .window, displayID: 0, windowID: 9, title: "メモ帳")])
        var startError: Error?
        var stopURL = URL(fileURLWithPath: "/tmp/画面収録テスト.mov")
        private(set) var startedSettings: ScreenRecordingSettings?
        private(set) var startCount = 0
        private(set) var stopCount = 0
        private(set) var cancelCount = 0

        func loadTargets() async throws -> ScreenRecordingTargets { targetsToReturn }
        func start(settings: ScreenRecordingSettings, outputURL: URL) async throws {
            if let startError { throw startError }
            startedSettings = settings
            startCount += 1
        }
        func stop() async throws -> URL { stopCount += 1; return stopURL }
        func cancel() async { cancelCount += 1 }
    }

    @MainActor
    private func makeController(engine: FakeEngine, granted: Bool) -> ScreenRecordingController {
        ScreenRecordingController(engine: engine, permissionCheck: { granted }, permissionRequest: { granted })
    }

    // MARK: 画面収録コントローラ

    @MainActor
    func testPermissionDeniedDoesNotStartEngine() async {
        let engine = FakeEngine()
        let c = makeController(engine: engine, granted: false)
        await c.refreshTargets()
        await c.startRecording()
        XCTAssertEqual(c.phase, .failed)
        XCTAssertEqual(c.error, .permissionDenied)
        XCTAssertEqual(engine.startCount, 0)   // 許可が無いときはエンジンに触らない
    }

    @MainActor
    func testStartStopHappyPath() async {
        let engine = FakeEngine()
        let c = makeController(engine: engine, granted: true)
        await c.refreshTargets()
        XCTAssertEqual(c.displayID, 7)   // 一覧の先頭が選ばれる
        await c.startRecording()
        XCTAssertEqual(c.phase, .recording)
        XCTAssertEqual(engine.startedSettings?.target.displayID, 7)
        XCTAssertEqual(engine.startedSettings?.includeSystemAudio, true)
        await c.stopRecording()
        XCTAssertEqual(c.phase, .finished)
        XCTAssertEqual(c.finishedURL, engine.stopURL)
        XCTAssertEqual(engine.stopCount, 1)
    }

    @MainActor
    func testEngineFailureBecomesFailedState() async {
        let engine = FakeEngine()
        engine.startError = ScreenRecordingError.captureFailed("ダミーの失敗")
        let c = makeController(engine: engine, granted: true)
        await c.refreshTargets()
        await c.startRecording()
        XCTAssertEqual(c.phase, .failed)
        XCTAssertEqual(c.error, .captureFailed("ダミーの失敗"))
        // 失敗からはもう一度始められる
        engine.startError = nil
        c.backToIdle()
        await c.startRecording()
        XCTAssertEqual(c.phase, .recording)
    }

    @MainActor
    func testStopWhileIdleIsIgnored() async {
        let engine = FakeEngine()
        let c = makeController(engine: engine, granted: true)
        await c.stopRecording()
        XCTAssertEqual(c.phase, .idle)
        XCTAssertEqual(engine.stopCount, 0)
    }

    @MainActor
    func testNoTargetSelectedFailsCleanly() async {
        let engine = FakeEngine()
        engine.targetsToReturn = ScreenRecordingTargets()   // 対象ゼロ
        let c = makeController(engine: engine, granted: true)
        await c.refreshTargets()
        await c.startRecording()
        XCTAssertEqual(c.phase, .failed)
        XCTAssertEqual(c.error, .noTargetAvailable)
        XCTAssertEqual(engine.startCount, 0)
    }

    @MainActor
    func testRegionSettingsBuiltFromFields() async {
        let engine = FakeEngine()
        let c = makeController(engine: engine, granted: true)
        await c.refreshTargets()
        c.kind = .region
        c.regionX = 100; c.regionY = 50; c.regionWidth = 800; c.regionHeight = 450
        let settings = c.makeSettings()
        XCTAssertEqual(settings?.target.kind, .region)
        XCTAssertEqual(settings?.target.region, ScreenRecordingRegion(x: 100, y: 50, width: 800, height: 450))
        XCTAssertNil(settings?.validate())
    }

    @MainActor
    func testCancelWhileRecording() async {
        let engine = FakeEngine()
        let c = makeController(engine: engine, granted: true)
        await c.refreshTargets()
        await c.startRecording()
        XCTAssertEqual(c.phase, .recording)
        await c.cancelIfNeeded()
        XCTAssertEqual(c.phase, .idle)
        XCTAssertEqual(engine.cancelCount, 1)
    }

    // MARK: AppleScript の引数変換

    func testScriptArgumentConversion() {
        let url = NSURL(fileURLWithPath: "/tmp/a.mcpjc")
        XCTAssertEqual(ScriptArgumentConversion.path(from: url), "/tmp/a.mcpjc")
        XCTAssertEqual(ScriptArgumentConversion.path(from: "/tmp/b.mcpjc"), "/tmp/b.mcpjc")
        XCTAssertNil(ScriptArgumentConversion.path(from: 42))
        let req = ScriptArgumentConversion.exportRequest(
            directParameter: url,
            arguments: ["output": "/tmp/out.mp4", "preset": "youtube1080"])
        XCTAssertEqual(req?.projectPath, "/tmp/a.mcpjc")
        XCTAssertEqual(req?.outputPath, "/tmp/out.mp4")
        XCTAssertEqual(req?.presetName, "youtube1080")
        XCTAssertNil(ScriptArgumentConversion.exportRequest(directParameter: nil, arguments: nil))
    }

    // MARK: Shortcuts の引数変換

    func testIntentPresetMapping() {
        XCTAssertNil(ExportPresetIntentValue.current.corePresetName)
        XCTAssertEqual(ExportPresetIntentValue.youtube1080.corePresetName, ExportPreset.youtube1080.rawValue)
        XCTAssertEqual(ExportPresetIntentValue.audio.corePresetName, ExportPreset.audio.rawValue)
        // 全ての選択肢が Core のプリセットに対応する(「設定のまま」を除く)
        for value in ExportPresetIntentValue.allCases where value != .current {
            XCTAssertNotNil(ExportPreset(cliName: value.corePresetName!), "\(value)")
        }
    }
}
