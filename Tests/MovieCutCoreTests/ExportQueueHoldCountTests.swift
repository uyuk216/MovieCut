import XCTest
@testable import MovieCutCore

/// A01: 書き出しキューの保留は数え上げ式(先に終わった書類が、他の書類の保留を解かない)。
@MainActor
final class ExportQueueHoldCountTests: XCTestCase {
    func testHoldIsReferenceCounted() {
        let q = ExportQueue()
        q.acquireHold()
        q.acquireHold()
        XCTAssertTrue(q.isHeld)
        q.releaseHold()
        XCTAssertTrue(q.isHeld, "まだもう1件が保留している")
        q.releaseHold()
        XCTAssertFalse(q.isHeld)
        q.releaseHold()
        XCTAssertFalse(q.isHeld, "数え過ぎても負にならない")
    }
}
