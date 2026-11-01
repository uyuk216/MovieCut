import XCTest
@testable import MovieCutCore

/// J/K/L シャトルの速度状態。
final class ShuttleTests: XCTestCase {
    func testStoppedStartsFromZero() {
        XCTAssertEqual(ShuttleState.stopped.speed, 0)
        XCTAssertTrue(ShuttleState.stopped.isStopped)
        XCTAssertEqual(ShuttleState.normal.speed, 1)
    }

    func testLFromStopGoesForwardOneXThenTwoThenFour() {
        var s = ShuttleState.stopped
        s = s.moved(by: 1); XCTAssertEqual(s.speed, 1)
        s = s.moved(by: 1); XCTAssertEqual(s.speed, 2)
        s = s.moved(by: 1); XCTAssertEqual(s.speed, 4)
        s = s.moved(by: 1); XCTAssertEqual(s.speed, 4, "上限は 4 倍")
    }

    func testJFromStopGoesReverseOneXThenTwoThenFour() {
        var s = ShuttleState.stopped
        s = s.moved(by: -1); XCTAssertEqual(s.speed, -1)
        s = s.moved(by: -1); XCTAssertEqual(s.speed, -2)
        s = s.moved(by: -1); XCTAssertEqual(s.speed, -4)
        s = s.moved(by: -1); XCTAssertEqual(s.speed, -4, "逆再生の上限も 4 倍")
    }

    func testJWhileForwardSlowsDownAndStopsAtZero() {
        var s = ShuttleState.stopped.moved(by: 1).moved(by: 1).moved(by: 1)   // 4 倍
        s = s.moved(by: -1); XCTAssertEqual(s.speed, 2)
        s = s.moved(by: -1); XCTAssertEqual(s.speed, 1)
        s = s.moved(by: -1); XCTAssertEqual(s.speed, 0)
        XCTAssertTrue(s.isStopped)
    }

    func testStopAndNormalAreDistinctFromLadderEdges() {
        XCTAssertEqual(ShuttleState.normal.moved(by: -1).speed, 0)
        XCTAssertEqual(ShuttleState.stopped.stoppedState, .stopped)
        XCTAssertEqual(ShuttleState.normal.stoppedState.speed, 0)
    }

    func testLadderIsSymmetricAroundStop() {
        XCTAssertEqual(ShuttleState.ladder[ShuttleState.stopIndex], 0)
        XCTAssertEqual(ShuttleState.ladder.first, ShuttleState.ladder.last.map { -$0 })
        XCTAssertEqual(ShuttleState.ladder[ShuttleState.normalIndex], 1)
    }
}
