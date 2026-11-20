import XCTest
@testable import MovieCutCore

/// ステッパー長押し(StepperRepeatScheduler)の発火計画。
/// 時刻はすべて手で渡すので、実タイマーなしで遅延・間隔・停止を固定できる。
/// 仕様: 押した瞬間 1 回 / 0.4 秒未満は連続が始まらない / 長押しは間隔どおり /
/// 離したら止まる。
final class StepperRepeatTests: XCTestCase {

    /// 押してから離すまで、10ms 刻みで poll し続けたときの発火時刻を集める。
    private func fireTimes(delay: Double = StepperRepeatScheduler.defaultInitialDelay,
                           interval: Double = StepperRepeatScheduler.defaultRepeatInterval,
                           pressAt start: Double = 0, releaseAt end: Double) -> [Double] {
        var s = StepperRepeatScheduler(initialDelay: delay, repeatInterval: interval)
        var times: [Double] = []
        if s.pressBegan(.increment, at: start) { times.append(start) }
        var t = start + 0.01
        while t < end {
            if s.poll(at: t) { times.append(t) }
            t += 0.01
        }
        s.pressEnded()
        return times
    }

    // MARK: 短押し = 1 回だけ

    func testShortPressFiresExactlyOnce() {
        var s = StepperRepeatScheduler()
        XCTAssertTrue(s.pressBegan(.increment, at: 10.0), "押した瞬間に 1 回発火する")
        XCTAssertEqual(s.firedCount, 1)
        XCTAssertEqual(s.direction, .increment)
        // 0.4 秒未満で離す間は、poll しても発火しない
        for t in stride(from: 10.01, to: 10.39, by: 0.01) {
            XCTAssertFalse(s.poll(at: t), "短押しでは連続発火しない (t=\(t))")
        }
        s.pressEnded()
        XCTAssertEqual(s.firedCount, 0)
        XCTAssertFalse(s.isPressed)
    }

    func testQuickTapSequenceFiresOncePerTap() {
        // タップを繰り返したら、その回数だけ発火する(連続扱いにならない)
        let times = fireTimes(pressAt: 0, releaseAt: 0.2)
        XCTAssertEqual(times, [0])
    }

    // MARK: 0.4 秒未満では連続が始まらない / 境界

    func testNoRepeatBeforeDelay() {
        var s = StepperRepeatScheduler()
        _ = s.pressBegan(.decrement, at: 0)
        XCTAssertFalse(s.poll(at: 0.39))
        XCTAssertFalse(s.poll(at: 0.399))
        XCTAssertEqual(s.firedCount, 1, "遅延が明けるまでは最初の 1 回だけ")
    }

    func testRepeatStartsAtDelay() {
        var s = StepperRepeatScheduler()
        _ = s.pressBegan(.increment, at: 0)
        XCTAssertTrue(s.poll(at: 0.4), "0.4 秒ちょうどで連続の 1 回目")
        XCTAssertEqual(s.firedCount, 2)
    }

    func testCustomDelayIsRespected() {
        var s = StepperRepeatScheduler(initialDelay: 1.0, repeatInterval: 0.25)
        _ = s.pressBegan(.increment, at: 0)
        XCTAssertFalse(s.poll(at: 0.9))
        XCTAssertTrue(s.poll(at: 1.0))
        XCTAssertFalse(s.poll(at: 1.1))
        XCTAssertTrue(s.poll(at: 1.25))
    }

    // MARK: 長押しは間隔どおり発火する

    func testLongPressFiresAtInterval() {
        // 遅延 0.4 / 間隔 0.05 で 1.0 秒押すと、発火は
        // 0(押下) + 0.40, 0.45, ..., 0.95 の 12 回 = 計 13 回。
        // poll は 10ms 刻みなので、各発火は予定時刻ちょうどの tick で起きる。
        let times = fireTimes(pressAt: 0, releaseAt: 1.0)
        XCTAssertEqual(times.count, 13, "発火時刻: \(times)")
        XCTAssertEqual(times.first, 0)
        for (i, t) in times.dropFirst().enumerated() {
            XCTAssertEqual(t, 0.4 + 0.05 * Double(i), accuracy: 0.011, "連続 \(i + 1) 回目")
        }
    }

    func testPollBetweenIntervalsDoesNotFire() {
        var s = StepperRepeatScheduler()
        _ = s.pressBegan(.increment, at: 0)
        XCTAssertTrue(s.poll(at: 0.4))
        XCTAssertFalse(s.poll(at: 0.42), "間隔の途中では発火しない")
        XCTAssertFalse(s.poll(at: 0.449))
        XCTAssertTrue(s.poll(at: 0.45))
    }

    func testLatePollFiresOnlyOnceAndDoesNotBurst() {
        // タイマーが大きく遅れても、取り戻す連射はせず 1 回だけ発火し、
        // 次回は現在時刻 + 間隔になる。
        var s = StepperRepeatScheduler()
        _ = s.pressBegan(.increment, at: 0)
        XCTAssertTrue(s.poll(at: 5.0), "遅れても 1 回は発火する")
        XCTAssertEqual(s.firedCount, 2)
        XCTAssertFalse(s.poll(at: 5.01))
        XCTAssertTrue(s.poll(at: 5.05))
        XCTAssertEqual(s.firedCount, 3)
    }

    // MARK: 離したら止まる

    func testReleaseStopsRepeating() {
        var s = StepperRepeatScheduler()
        _ = s.pressBegan(.increment, at: 0)
        XCTAssertTrue(s.poll(at: 0.4))
        s.pressEnded()
        XCTAssertNil(s.direction)
        XCTAssertNil(s.nextFireTime)
        for t in [0.45, 0.5, 1.0, 10.0] {
            XCTAssertFalse(s.poll(at: t), "離した後は発火しない (t=\(t))")
        }
    }

    func testPollWithoutPressNeverFires() {
        var s = StepperRepeatScheduler()
        XCTAssertFalse(s.poll(at: 0))
        XCTAssertFalse(s.poll(at: 100))
        XCTAssertEqual(s.firedCount, 0)
    }

    // MARK: 押し直し・向き

    func testRepressRestartsDelayAndDirection() {
        var s = StepperRepeatScheduler()
        _ = s.pressBegan(.increment, at: 0)
        XCTAssertTrue(s.poll(at: 0.4))
        s.pressEnded()
        // 向きを変えて押し直すと、即 1 回 + 遅延はそこから数え直す
        XCTAssertTrue(s.pressBegan(.decrement, at: 1.0))
        XCTAssertEqual(s.direction, .decrement)
        XCTAssertEqual(s.firedCount, 1)
        XCTAssertFalse(s.poll(at: 1.39))
        XCTAssertTrue(s.poll(at: 1.4))
    }

    func testPressBeganWhilePressedRestarts() {
        var s = StepperRepeatScheduler()
        _ = s.pressBegan(.increment, at: 0)
        XCTAssertTrue(s.poll(at: 0.4))
        _ = s.pressBegan(.decrement, at: 0.5)   // 押したまま向きが切り替わった扱い
        XCTAssertEqual(s.direction, .decrement)
        XCTAssertEqual(s.firedCount, 1, "切り替え時点を新しい押下として数え直す")
        XCTAssertFalse(s.poll(at: 0.89))
        XCTAssertTrue(s.poll(at: 0.9))
    }

    // MARK: 既定値と不正な指定

    func testDefaultsMatchSpec() {
        XCTAssertEqual(StepperRepeatScheduler.defaultInitialDelay, 0.4, accuracy: 1e-9)
        XCTAssertGreaterThan(StepperRepeatScheduler.defaultRepeatInterval, 0)
        let s = StepperRepeatScheduler()
        XCTAssertEqual(s.initialDelay, 0.4, accuracy: 1e-9)
    }

    func testInvalidParametersFallBackToDefaults() {
        for bad in [0.0, -1.0, Double.nan, Double.infinity] {
            let s = StepperRepeatScheduler(initialDelay: bad, repeatInterval: bad)
            XCTAssertEqual(s.initialDelay, StepperRepeatScheduler.defaultInitialDelay, "delay \(bad)")
            XCTAssertEqual(s.repeatInterval, StepperRepeatScheduler.defaultRepeatInterval, "interval \(bad)")
        }
    }
}

/// ステッパーの 1 ステップぶんの値計算(StepperValue)。ラベル付き行の共通部品が
/// SwiftUI Stepper の代わりに行う「ステップ幅ぶん動かして値域で止める」の固定。
final class StepperValueTests: XCTestCase {

    func testIntSteppingMovesByDelta() {
        XCTAssertEqual(StepperValue.stepped(4, by: 1, in: 1...8), 5)
        XCTAssertEqual(StepperValue.stepped(4, by: -1, in: 1...8), 3)
        XCTAssertEqual(StepperValue.stepped(0, by: 1, in: -24...24), 1)
        XCTAssertEqual(StepperValue.stepped(8, by: -3, in: 1...30), 5)
    }

    func testIntSteppingClampsAtRangeEnds() {
        XCTAssertEqual(StepperValue.stepped(8, by: 1, in: 1...8), 8, "上限では止まる")
        XCTAssertEqual(StepperValue.stepped(1, by: -1, in: 1...8), 1, "下限では止まる")
        XCTAssertEqual(StepperValue.stepped(0, by: -1, in: 0...128), 0)
        XCTAssertEqual(StepperValue.stepped(127, by: 5, in: 0...128), 128, "越える分は端で止まる")
    }

    func testDoubleSteppingMovesAndClamps() {
        XCTAssertEqual(StepperValue.stepped(2.0, by: 1, in: Figure.strokeWidthRange), 3.0, accuracy: 1e-9)
        XCTAssertEqual(StepperValue.stepped(0.1, by: 0.05, in: Figure.cornerRange), 0.15, accuracy: 1e-9)
        XCTAssertEqual(StepperValue.stepped(0.5, by: 0.05, in: Figure.cornerRange), 0.5, accuracy: 1e-9, "上限で止まる")
        XCTAssertEqual(StepperValue.stepped(0.0, by: -0.05, in: Figure.cornerRange), 0.0, accuracy: 1e-9, "下限で止まる")
        XCTAssertEqual(StepperValue.stepped(60.0, by: 1, in: Figure.strokeWidthRange), 60.0, accuracy: 1e-9)
    }

    func testDoubleSteppingKeepsNonFiniteValue() {
        XCTAssertTrue(StepperValue.stepped(Double.nan, by: 1, in: 0...10).isNaN)
        XCTAssertEqual(StepperValue.stepped(5.0, by: Double.nan, in: 0...10), 5.0, accuracy: 1e-9)
    }
}
