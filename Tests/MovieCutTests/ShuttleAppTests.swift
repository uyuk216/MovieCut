import XCTest
import AppKit
import MovieCutCore
@testable import MovieCut

/// J/K/L シャトル再生(再生コントローラと KeyRouter)。音の偽物は PlaybackTests の FakeBackend / FakeClock を使う。
@MainActor
final class ShuttleAppTests: XCTestCase {
    private func make(end: Double = 10) -> (ProjectModel, PlaybackController, FakeBackend, FakeClock) {
        var p = Project.new()
        var c = Clip(); c.type = .voice; c.src = "/tmp/a.wav"; c.start = 0; c.duration = end
        p.tracks[0].clips.append(c)
        let m = ProjectModel(project: p)
        let b = FakeBackend(), k = FakeClock()
        let pc = PlaybackController(model: m, backend: b, clock: k, debounce: 0, mixer: { _, _ in end })
        pc.timerFallback = false
        m.playback = pc
        return (m, pc, b, k)
    }

    func testLFromStopPlaysForwardWithAudio() async {
        let (m, c, b, _) = make()
        c.shuttle(by: 1)
        await c.preparation?.value
        XCTAssertTrue(c.isPlaying)
        XCTAssertEqual(c.shuttleState.speed, 1)
        XCTAssertEqual(b.starts, [0])               // 通常の再生は音を鳴らす
        XCTAssertEqual(m.currentTime, 0)
    }

    func testLTwiceGoesFourTimesWithoutAudioAndAdvancesByClock() async {
        let (m, c, b, k) = make()
        c.shuttle(by: 1)                             // 順 1 倍(音あり)
        await c.preparation?.value
        c.shuttle(by: 1)                             // 2 倍
        XCTAssertEqual(c.shuttleState.speed, 2)
        XCTAssertTrue(c.isPlaying)
        XCTAssertEqual(b.pauses, 1)                  // 1 倍 → 2 倍で音を止める(1 回)
        k.t += 1; c.tick()                           // 1 秒経過 → 2 秒進む
        XCTAssertEqual(m.currentTime, 2, accuracy: 1e-9)
        c.shuttle(by: 1)                             // 4 倍
        k.t += 0.5; c.tick()
        XCTAssertEqual(m.currentTime, 4, accuracy: 1e-9)
    }

    func testJFromStopReversesAndStopsAtStart() {
        let (m, c, _, k) = make()
        m.currentTime = 3
        c.shuttle(by: -1)                            // 逆 1 倍
        XCTAssertEqual(c.shuttleState.speed, -1)
        XCTAssertTrue(c.isPlaying)
        k.t += 1; c.tick()
        XCTAssertEqual(m.currentTime, 2, accuracy: 1e-9)
        k.t += 5; c.tick()                           // 先頭に着いたら止まる
        XCTAssertFalse(c.isPlaying)
        XCTAssertEqual(m.currentTime, 0)
        XCTAssertTrue(c.shuttleState.isStopped)
    }

    func testKStopsAndResetsSpeed() async {
        let (m, c, _, _) = make()
        c.shuttle(by: 1); await c.preparation?.value
        c.shuttle(by: 1)
        c.shuttleStop()
        _ = m
        XCTAssertFalse(c.isPlaying)
        XCTAssertTrue(c.shuttleState.isStopped)
    }

    func testJWhileForwardSlowsDownToNormalAudio() async {
        let (m, c, b, _) = make()
        c.shuttle(by: 1); await c.preparation?.value // 1 倍(音あり)
        c.shuttle(by: 1)                             // 2 倍
        let startsBefore = b.starts.count
        c.shuttle(by: -1)
        // 1 倍へ戻る → 音を鳴らし直す
        XCTAssertEqual(c.shuttleState.speed, 1)
        XCTAssertEqual(b.starts.count, startsBefore + 1)
        XCTAssertTrue(c.isPlaying)
    }

    func testEditStopsShuttle() async {
        let (m, c, _, _) = make()
        c.shuttle(by: 1); await c.preparation?.value
        c.shuttle(by: 1)
        c.projectDidChange()
        _ = m
        XCTAssertFalse(c.isPlaying)
    }

    func testKeyRouterMapsJKLAndIgnoresRepeat() {
        let r = KeyRouter()
        var log: [KeyCommand] = []
        r.handlers[.shuttleBack] = { log.append(.shuttleBack); return true }
        r.handlers[.shuttleStop] = { log.append(.shuttleStop); return true }
        r.handlers[.shuttleForward] = { log.append(.shuttleForward); return true }
        XCTAssertTrue(r.dispatch(keyCode: 38, modifiers: [], firstResponder: NSView()))   // J
        XCTAssertTrue(r.dispatch(keyCode: 40, modifiers: [], firstResponder: NSView()))   // K
        XCTAssertTrue(r.dispatch(keyCode: 37, modifiers: [], firstResponder: NSView()))   // L
        XCTAssertTrue(r.dispatch(keyCode: 37, modifiers: [], firstResponder: NSView(), isRepeat: true))
        XCTAssertFalse(r.dispatch(keyCode: 37, modifiers: [.command], firstResponder: NSView()))   // ⌘L は奪わない
        XCTAssertFalse(r.dispatch(keyCode: 38, modifiers: [], firstResponder: NSTextView()))      // 入力欄では通す
        XCTAssertEqual(log, [.shuttleBack, .shuttleStop, .shuttleForward])
    }
}
