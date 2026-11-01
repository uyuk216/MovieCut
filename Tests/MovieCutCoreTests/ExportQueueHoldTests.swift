import XCTest
@testable import MovieCutCore

/// 書き出しキューの保留(直接の書き出しが動いている間は、待っている件を始めない)。
@MainActor
final class ExportQueueHoldTests: XCTestCase {
    func testHeldQueueStartsWaitingJobsOnlyAfterRelease() async {
        let q = ExportQueue()
        var started: [String] = []
        q.isHeld = true
        let id = q.enqueue(title: "a") { _ in started.append("a") }
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(q.state(of: id), .waiting, "保留中は待ちの件を始めない")
        XCTAssertTrue(started.isEmpty)

        q.isHeld = false
        for _ in 0..<400 where q.state(of: id)?.isActive ?? false { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(started, ["a"], "保留を解くと始まる")
        XCTAssertEqual(q.state(of: id), .finished)
    }
}
