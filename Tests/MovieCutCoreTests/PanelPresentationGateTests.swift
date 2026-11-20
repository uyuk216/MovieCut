import XCTest
@testable import MovieCutCore

/// ファイルパネルの同時提示ゲート。
final class PanelPresentationGateTests: XCTestCase {
    func testAcquireReleaseReacquire() {
        let gate = PanelPresentationGate()
        XCTAssertFalse(gate.isPresenting)
        let t = gate.tryAcquire()
        XCTAssertNotNil(t)
        XCTAssertTrue(gate.isPresenting)
        gate.release(t!)
        XCTAssertFalse(gate.isPresenting)
        XCTAssertNotNil(gate.tryAcquire())
    }

    func testSecondAcquireWhilePresentingIsNil() {
        let gate = PanelPresentationGate()
        XCTAssertNotNil(gate.tryAcquire())
        XCTAssertNil(gate.tryAcquire())
        XCTAssertTrue(gate.isPresenting)
    }

    func testReleaseWithOtherTokenDoesNotUnlock() {
        let gate = PanelPresentationGate()
        let stale = gate.tryAcquire()!
        gate.release(stale)
        let held = gate.tryAcquire()!
        XCTAssertNotEqual(stale, held)
        // 古い token(前回の保持者)では解除されない
        gate.release(stale)
        XCTAssertTrue(gate.isPresenting)
        gate.release(held)
        XCTAssertFalse(gate.isPresenting)
    }

    func testDoubleReleaseIsHarmless() {
        let gate = PanelPresentationGate()
        let t = gate.tryAcquire()!
        gate.release(t)
        gate.release(t)
        XCTAssertFalse(gate.isPresenting)
        // 二重 release の後に取得した新しい保持者を巻き込まない
        let t2 = gate.tryAcquire()!
        gate.release(t)
        XCTAssertTrue(gate.isPresenting)
        gate.release(t2)
        XCTAssertFalse(gate.isPresenting)
    }

    func testShouldPresentTruthTable() {
        for bits in 0..<16 {
            let userInitiated = bits & 1 != 0
            let hasHost = bits & 2 != 0
            let already = bits & 4 != 0
            let suppressed = bits & 8 != 0
            let expected = userInitiated && hasHost && !already && !suppressed
            XCTAssertEqual(
                PanelPresentationGate.shouldPresent(userInitiated: userInitiated, hasHostWindow: hasHost,
                                                    alreadyPresenting: already, environmentSuppressed: suppressed),
                expected, "bits=\(bits)")
        }
        XCTAssertTrue(PanelPresentationGate.shouldPresent(userInitiated: true, hasHostWindow: true,
                                                          alreadyPresenting: false, environmentSuppressed: false))
    }

    func testConcurrentAcquireHasExactlyOneWinner() {
        let gate = PanelPresentationGate()
        let lock = NSLock()
        var winners = 0
        DispatchQueue.concurrentPerform(iterations: 200) { _ in
            if gate.tryAcquire() != nil {
                lock.lock(); winners += 1; lock.unlock()
            }
        }
        XCTAssertEqual(winners, 1)
        XCTAssertTrue(gate.isPresenting)
    }
}
