import XCTest
import AppKit
import YukkuriCore
@testable import YukkuriEditor

// MARK: - 偽物

final class FakeBackend: AudioBackend {
    var running = false
    var loaded: [URL] = []
    var starts: [Double] = []
    var pauses = 0
    var time: Double?
    var onConfigurationChange: (() -> Void)?
    var isRunning: Bool { running }
    func load(url: URL) throws -> Double { loaded.append(url); return 10 }
    func unload() {}
    func start(at t: Double) throws { starts.append(t); running = true }
    func pause() { pauses += 1; running = false }
    func currentTime() -> Double? { time }
    func shutdown() { running = false }
}

final class FakeClock: PlaybackClock {
    var t = 100.0
    func now() -> Double { t }
}

@MainActor
final class PlaybackTests: XCTestCase {
    private func voiceProject(end: Double = 5) -> Project {
        var p = Project.new()
        var c = Clip(); c.type = .voice; c.src = "/tmp/a.wav"; c.start = 0; c.duration = end
        p.tracks[0].clips.append(c)
        return p
    }

    private func make(end: Double = 5) -> (ProjectModel, PlaybackController, FakeBackend, FakeClock) {
        let m = ProjectModel(project: voiceProject(end: end))
        let b = FakeBackend(), k = FakeClock()
        let c = PlaybackController(model: m, backend: b, clock: k, debounce: 0, mixer: { _, _ in 5 })
        c.timerFallback = false
        m.playback = c
        return (m, c, b, k)
    }

    private func startPlaying(_ c: PlaybackController) async {
        c.play()
        await c.preparation?.value
    }

    // MARK: 時間・座標

    func testTimeXRoundTrip() {
        var g = TimelineGeometry(); g.pps = 80; g.scrollX = 200
        XCTAssertEqual(g.x(forTime: 0), 90 - 200, accuracy: 1e-9)
        XCTAssertEqual(g.x(forTime: 5), 90 + 400 - 200, accuracy: 1e-9)
        XCTAssertEqual(g.time(forX: g.x(forTime: 3.25)), 3.25, accuracy: 1e-9)
    }

    func testTickStepSelection() {
        XCTAssertEqual(TimelineLayout.tickStep(pps: 400), 0.2)   // 0.1×400=40 <70, 0.2×400=80
        XCTAssertEqual(TimelineLayout.tickStep(pps: 140), 0.5)   // ちょうど 70
        XCTAssertEqual(TimelineLayout.tickStep(pps: 40), 2)
        XCTAssertEqual(TimelineLayout.tickStep(pps: 10), 10)
        XCTAssertEqual(TimelineLayout.tickStep(pps: 5), 30)
        XCTAssertEqual(TimelineLayout.tickStep(pps: 1), 60)      // 候補の最後
        XCTAssertEqual(TimelineLayout.tickLabel(seconds: 62, step: 2), "01:02")
        XCTAssertEqual(TimelineLayout.tickLabel(seconds: 1.5, step: 0.5), "00:01.5")
    }

    func testFitAndContentWidth() {
        XCTAssertEqual(TimelineLayout.fitPps(visibleWidth: 1000, projectEnd: 4), 100)   // 10 秒に収める
        XCTAssertEqual(TimelineLayout.fitPps(visibleWidth: 1000, projectEnd: 50), 20)
        XCTAssertEqual(TimelineLayout.fitPps(visibleWidth: 100000, projectEnd: 4), 400)  // 上限
        XCTAssertEqual(TimelineLayout.fitPps(visibleWidth: 100, projectEnd: 100), 5)     // 下限
        XCTAssertEqual(TimelineLayout.contentWidth(projectEnd: 0, pps: 40), 30 * 40)
        XCTAssertEqual(TimelineLayout.contentWidth(projectEnd: 60, pps: 10), 700)
    }

    func testClipRectGeometry() {
        var g = TimelineGeometry(); g.pps = 40
        let r = g.clipRect(start: 2, duration: 1.5, track: 2)
        XCTAssertEqual(r, CGRect(x: 90 + 80, y: 22 + 80 + 3, width: 60, height: 34))
        // 極端に短いクリップ
        XCTAssertEqual(g.clipRect(start: 0, duration: 0.001, track: 0).width, 4)
        XCTAssertEqual(g.clipRect(start: 0, duration: 0, track: 0).width, 4)
        g.scrollY = 10
        XCTAssertEqual(g.clipRect(start: 0, duration: 1, track: 0).minY, 22 - 10 + 3)
        XCTAssertEqual(g.rowIndex(forY: 22 + 45 - 10, rowCount: 5), 1)
        XCTAssertNil(g.rowIndex(forY: 10, rowCount: 5))
    }

    // MARK: 音声キャッシュの鍵

    func testAudioCacheKeyOnlyChangesForAudioFields() {
        var p = voiceProject()
        var img = Clip(); img.type = .image; img.src = "/tmp/x.png"; img.duration = 3
        p.tracks[1].clips.append(img)
        let dates: (String) -> Date? = { _ in Date(timeIntervalSinceReferenceDate: 1000) }
        let k0 = AudioCacheKey.make(for: p, fileDate: dates)
        func key(_ f: (inout Project) -> Void) -> AudioCacheKey { var q = p; f(&q); return AudioCacheKey.make(for: q, fileDate: dates) }
        // 音に関係しない変更
        XCTAssertEqual(key { $0.tracks[0].clips[0].text = "別のセリフ" }, k0)
        XCTAssertEqual(key { $0.tracks[0].clips[0].fontSize = 99; $0.tracks[0].clips[0].charId = "zzz"; $0.tracks[0].clips[0].subtitle = false }, k0)
        XCTAssertEqual(key { $0.tracks[1].clips[0].x = 0.1; $0.tracks[1].clips[0].opacity = 0.5; $0.tracks[1].clips[0].start = 9 }, k0)
        XCTAssertEqual(key { $0.tracks[0].hidden = true }, k0)
        XCTAssertEqual(key { $0.width = 1280; $0.bg = "#ffffff" }, k0)
        XCTAssertEqual(key { $0.tracks.append(Track(name: "追加")) }, k0)            // ＋レイヤー
        XCTAssertEqual(key { $0.tracks[4].muted = true }, k0)                       // 音のないレイヤーの消音
        XCTAssertEqual(key { $0.tracks[0].clips[0].volume = 1 }, k0)   // nil と 1 は同じ音
        // 音に関係する変更
        XCTAssertNotEqual(key { $0.tracks[0].clips[0].src = "/tmp/b.wav" }, k0)
        XCTAssertNotEqual(key { $0.tracks[0].clips[0].start = 0.5 }, k0)
        XCTAssertNotEqual(key { $0.tracks[0].clips[0].duration = 4 }, k0)
        XCTAssertNotEqual(key { $0.tracks[0].clips[0].offset = 0.2 }, k0)
        XCTAssertNotEqual(key { $0.tracks[0].clips[0].volume = 0.5 }, k0)
        XCTAssertNotEqual(key { $0.tracks[0].muted = true }, k0)
        XCTAssertNotEqual(key { var v = Clip(); v.type = .audio; v.src = "/tmp/c.wav"; v.duration = 1; $0.tracks[2].clips.append(v) }, k0)
        // ファイルの更新日時
        XCTAssertNotEqual(AudioCacheKey.make(for: p, fileDate: { _ in Date(timeIntervalSinceReferenceDate: 2000) }), k0)
        XCTAssertNotEqual(AudioCacheKey.make(for: p, fileDate: { _ in nil }), k0)
    }

    // MARK: 再生コントローラ

    func testPlayPauseSeekStep() async {
        let (m, c, b, k) = make()
        await startPlaying(c)
        XCTAssertTrue(c.isPlaying); XCTAssertTrue(m.isPlaying)
        XCTAssertEqual(b.starts, [0])
        XCTAssertEqual(b.loaded.count, 1)
        // 音のクロックに追従する(画面側で足し算しない)
        b.time = 1.25; c.tick()
        XCTAssertEqual(m.currentTime, 1.25)
        b.time = 1.20; c.tick()                      // 巻き戻らない
        XCTAssertEqual(m.currentTime, 1.25)
        // 再生中のシーク → 音も鳴らし直す
        c.seek(to: 3)
        XCTAssertEqual(m.currentTime, 3); XCTAssertEqual(b.starts.last, 3)
        b.time = 3.5; c.tick()
        XCTAssertEqual(m.currentTime, 3.5)
        c.pause()
        XCTAssertFalse(c.isPlaying); XCTAssertFalse(m.isPlaying)
        XCTAssertEqual(m.currentTime, 3.5)
        // コマ送り(60fps)
        c.step(frames: 1)
        XCTAssertEqual(m.currentTime, 3.5 + 1.0 / 60, accuracy: 1e-9)
        c.step(frames: -2)
        XCTAssertEqual(m.currentTime, 3.5 - 1.0 / 60, accuracy: 1e-9)
        c.goToStart()
        XCTAssertEqual(m.currentTime, 0)
        c.step(frames: -1)
        XCTAssertEqual(m.currentTime, 0)             // 0 より前へは行かない
        XCTAssertEqual(b.loaded.count, 1)            // ミックスは作り直していない
    }

    func testHostClockFallbackWhenBackendHasNoTime() async {
        let (m, c, b, k) = make()
        b.time = nil
        await startPlaying(c)
        k.t += 0.5; c.tick()
        XCTAssertEqual(m.currentTime, 0.5, accuracy: 1e-9)
        k.t += 0.5; c.tick()
        XCTAssertEqual(m.currentTime, 1.0, accuracy: 1e-9)
    }

    func testStopsAtEndAndRestartsFromZero() async {
        let (m, c, b, _) = make(end: 5)
        m.currentTime = 4.9
        await startPlaying(c)
        b.time = 5.01; c.tick()
        XCTAssertFalse(c.isPlaying)
        XCTAssertEqual(m.currentTime, 5)             // 終端で止まり、時刻は終わり
        await startPlaying(c)                        // 終わりから押すと先頭から
        XCTAssertTrue(c.isPlaying)
        XCTAssertEqual(b.starts.last, 0)
        XCTAssertEqual(m.currentTime, 0)
        XCTAssertEqual(b.loaded.count, 1)            // 同じミックスを使い回す
    }

    func testEditStopsPlaybackAndTriggersRebuild() async {
        let (m, c, b, _) = make()
        await startPlaying(c)
        XCTAssertTrue(c.isPlaying)
        m.edit("色") { $0.tracks[1].name = "名前だけ変更" }
        XCTAssertFalse(c.isPlaying)                  // 編集で止まる
        await Task.yield()
        XCTAssertEqual(b.loaded.count, 1)            // 音に関係しない編集では作り直さない
        m.edit("消音") { $0.tracks[0].muted = true }
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(b.loaded.count, 2)            // 消音で作り直した
        // Undo も止める
        m.edit("戻す準備") { $0.tracks[0].muted = nil }
        try? await Task.sleep(nanoseconds: 100_000_000)
        await startPlaying(c)
        XCTAssertTrue(c.isPlaying)
        m.effectiveUndoManager.undo()
        XCTAssertFalse(c.isPlaying)
    }

    func testScrubWhilePlayingRestartsOnce() async {
        let (m, c, b, _) = make()
        await startPlaying(c)
        let n = b.starts.count
        c.beginScrub()
        c.seek(to: 1); c.seek(to: 2); c.seek(to: 2.2)
        XCTAssertEqual(m.currentTime, 2.2)
        XCTAssertEqual(b.starts.count, n)            // ドラッグ中は鳴らし直さない
        b.time = 0.1; c.tick()
        XCTAssertEqual(m.currentTime, 2.2)           // ドラッグ中はクロックで上書きしない
        c.endScrub()
        XCTAssertEqual(b.starts.count, n + 1); XCTAssertEqual(b.starts.last, 2.2)
        XCTAssertTrue(c.isPlaying)
    }

    func testEmptyProjectDoesNotPlay() {
        let m = ProjectModel(project: .new())
        let c = PlaybackController(model: m, backend: FakeBackend(), clock: FakeClock(), debounce: 0, mixer: { _, _ in 0 })
        c.play()
        XCTAssertFalse(c.isPlaying)
    }

    func testMixFailureStillPlaysSilently() async {
        let m = ProjectModel(project: voiceProject())
        let b = FakeBackend(), k = FakeClock()
        struct Boom: Error {}
        let c = PlaybackController(model: m, backend: b, clock: k, debounce: 0, mixer: { _, _ in throw Boom() })
        c.timerFallback = false
        m.playback = c
        await startPlaying(c)
        XCTAssertTrue(c.isPlaying)
        XCTAssertTrue(b.loaded.isEmpty)
        XCTAssertNotNil(c.lastMixError)
    }

    // MARK: キー操作

    func testKeyRouterIgnoresTextInputs() {
        let space: UInt16 = 49, left: UInt16 = 123
        let tv = NSTextView(), tf = NSTextField(), plain = NSView()
        XCTAssertNil(KeyRouter.command(keyCode: space, modifiers: [], firstResponder: tv))
        XCTAssertNil(KeyRouter.command(keyCode: left, modifiers: [], firstResponder: tf))
        XCTAssertEqual(KeyRouter.command(keyCode: space, modifiers: [], firstResponder: plain), .playPause)
        XCTAssertEqual(KeyRouter.command(keyCode: left, modifiers: [.numericPad, .function], firstResponder: plain), .stepBack)  // 矢印キーの付随フラグは無視
        XCTAssertEqual(KeyRouter.command(keyCode: 124, modifiers: [.shift], firstResponder: nil), .stepForward)
        XCTAssertNil(KeyRouter.command(keyCode: space, modifiers: [.command], firstResponder: plain))
        XCTAssertNil(KeyRouter.command(keyCode: space, modifiers: [.option], firstResponder: plain))
        XCTAssertNil(KeyRouter.command(keyCode: space, modifiers: [.control], firstResponder: plain))
        XCTAssertNil(KeyRouter.command(keyCode: 0, modifiers: [], firstResponder: plain))
        XCTAssertEqual(KeyRouter.command(keyCode: 115, modifiers: [], firstResponder: plain), .toStart)
    }

    func testKeyRouterDispatchCallsHandlers() {
        let r = KeyRouter()
        var log: [KeyCommand] = []
        r.handlers[.playPause] = { log.append(.playPause); return true }
        r.handlers[.stepForward] = { log.append(.stepForward); return true }
        XCTAssertTrue(r.dispatch(keyCode: 49, modifiers: [], firstResponder: NSView()))
        XCTAssertFalse(r.dispatch(keyCode: 49, modifiers: [], firstResponder: NSTextView()))   // 入力欄では通す
        XCTAssertTrue(r.dispatch(keyCode: 124, modifiers: [], firstResponder: NSView()))
        XCTAssertFalse(r.dispatch(keyCode: 1, modifiers: [], firstResponder: NSView()))        // S: M4 まで未割り当て
        XCTAssertTrue(r.dispatch(keyCode: 49, modifiers: [], firstResponder: NSView(), isRepeat: true))   // 長押しは消費だけ
        XCTAssertEqual(log, [.playPause, .stepForward])
    }

    // MARK: モデル・別画面

    func testTrackActionsAreUndoable() {
        let m = ProjectModel(project: .new())
        m.addTrack()
        XCTAssertEqual(m.project.tracks.last?.name, "レイヤー6")
        m.toggleTrack(0, .hidden); m.toggleTrack(1, .muted)
        XCTAssertTrue(m.project.tracks[0].isHidden); XCTAssertTrue(m.project.tracks[1].isMuted)
        m.effectiveUndoManager.undo(); m.effectiveUndoManager.undo()
        XCTAssertFalse(m.project.tracks[0].isHidden); XCTAssertFalse(m.project.tracks[1].isMuted)
        XCTAssertEqual(m.project.tracks.count, 6)
        m.effectiveUndoManager.undo()
        XCTAssertEqual(m.project.tracks.count, 5)
    }

    func testSecondScreenPicksLargestNonBuiltin() {
        typealias S = SecondScreenController.ScreenInfo
        XCTAssertEqual(SecondScreenController.pickTarget([S(isBuiltin: true, area: 100), S(isBuiltin: false, area: 50), S(isBuiltin: false, area: 80)]), 2)
        XCTAssertNil(SecondScreenController.pickTarget([S(isBuiltin: true, area: 100)]))
        XCTAssertNil(SecondScreenController.pickTarget([]))
    }
}
