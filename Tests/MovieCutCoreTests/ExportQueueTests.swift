import XCTest
@testable import MovieCutCore

/// 書き出しキュー: 実際の書き出しの代わりに偽の作業(fake)を入れて、順番・同時実行なし・取り消し・失敗を確かめる。
@MainActor
final class ExportQueueTests: XCTestCase {

    /// 作業の記録(開始・終了の順、同時に走った最大数)。
    final class Recorder {
        var started: [String] = []
        var finished: [String] = []
        var running = 0
        var maxRunning = 0
    }

    /// `steps` 回の小さな待ちを挟み、毎回進み具合を出す偽の書き出し。キャンセルされたら CancellationError。
    private func fake(_ name: String, _ rec: Recorder, steps: Int = 3, failWith: String? = nil) -> ExportWork {
        return { progress in
            rec.started.append(name)
            rec.running += 1
            rec.maxRunning = max(rec.maxRunning, rec.running)
            defer { rec.running -= 1 }
            for i in 1...steps {
                try await Task.sleep(nanoseconds: 5_000_000)
                try Task.checkCancellation()
                progress(Double(i) / Double(steps))
            }
            if let msg = failWith { throw FakeError(message: msg) }
            rec.finished.append(name)
        }
    }

    struct FakeError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// 条件が成り立つまで待つ(最大 10 秒)。
    private func waitUntil(_ what: String = "条件", _ cond: () -> Bool) async throws {
        for _ in 0..<1000 where !cond() {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(cond(), "\(what) が来なかった")
    }

    private func settled(_ q: ExportQueue) -> Bool { !q.isBusy && q.entries.allSatisfy { !$0.state.isActive } }

    func testRunsOneAtATimeInOrder() async throws {
        let q = ExportQueue()
        let rec = Recorder()
        q.enqueue(title: "A", fake("A", rec))
        q.enqueue(title: "B", fake("B", rec))
        q.enqueue(title: "C", fake("C", rec))
        try await waitUntil { self.settled(q) }
        XCTAssertEqual(rec.started, ["A", "B", "C"], "投入した順")
        XCTAssertEqual(rec.finished, ["A", "B", "C"])
        XCTAssertEqual(rec.maxRunning, 1, "同時に 1 件だけ")
        XCTAssertEqual(q.entries.map(\.state), [.finished, .finished, .finished])
    }

    func testProgressIsReportedWhileRunning() async throws {
        let q = ExportQueue()
        let rec = Recorder()
        let id = q.enqueue(title: "P", fake("P", rec, steps: 4))
        try await waitUntil { self.settled(q) }
        XCTAssertEqual(q.state(of: id), .finished)
        XCTAssertEqual(rec.finished, ["P"])
    }

    func testCancelWaitingJobNeverRuns() async throws {
        let q = ExportQueue()
        let rec = Recorder()
        q.enqueue(title: "A", fake("A", rec, steps: 20))
        let b = q.enqueue(title: "B", fake("B", rec))
        q.enqueue(title: "C", fake("C", rec))
        q.cancel(b)
        XCTAssertEqual(q.state(of: b), .cancelled, "待ちの件は即・取り消し")
        try await waitUntil { self.settled(q) }
        XCTAssertEqual(rec.started, ["A", "C"], "取り消した B は走らない")
        XCTAssertEqual(q.entries.map(\.state), [.finished, .cancelled, .finished])
    }

    func testCancelRunningJobEndsCancelledAndNextStarts() async throws {
        let q = ExportQueue()
        let rec = Recorder()
        let a = q.enqueue(title: "A", fake("A", rec, steps: 1_000))   // 長い: 途中で止める
        q.enqueue(title: "B", fake("B", rec))
        try await waitUntil("A の進み具合") { if case .running(let v)? = q.state(of: a) { return v > 0 }; return false }
        q.cancel(a)
        try await waitUntil { self.settled(q) }
        XCTAssertEqual(q.state(of: a), .cancelled)
        XCTAssertEqual(rec.finished, ["B"], "A は完了しない・B は続けて走る")
        XCTAssertEqual(q.entries.last?.state, .finished)
    }

    func testFailureMarksFailedAndQueueContinues() async throws {
        let q = ExportQueue()
        let rec = Recorder()
        let bad = q.enqueue(title: "bad", fake("bad", rec, failWith: "ディスクがいっぱいです"))
        let ok = q.enqueue(title: "ok", fake("ok", rec))
        try await waitUntil { self.settled(q) }
        XCTAssertEqual(q.state(of: bad), .failed("ディスクがいっぱいです"))
        XCTAssertEqual(q.state(of: ok), .finished)
        XCTAssertEqual(rec.finished, ["ok"])
    }

    func testCancelAllClearsWaitingAndRunning() async throws {
        let q = ExportQueue()
        let rec = Recorder()
        let a = q.enqueue(title: "A", fake("A", rec, steps: 1_000))
        let b = q.enqueue(title: "B", fake("B", rec))
        try await waitUntil("A の開始") { if case .running? = q.state(of: a) { return true }; return false }
        q.cancelAll()
        try await waitUntil { self.settled(q) }
        XCTAssertEqual(q.state(of: a), .cancelled)
        XCTAssertEqual(q.state(of: b), .cancelled)
        XCTAssertEqual(rec.started, ["A"], "B は一度も走らない")
    }

    func testClearFinishedKeepsActiveEntries() async throws {
        let q = ExportQueue()
        let rec = Recorder()
        let a = q.enqueue(title: "A", fake("A", rec))
        let b = q.enqueue(title: "B", fake("B", rec, steps: 1_000))
        try await waitUntil("A 完了") { q.state(of: a) == .finished }
        q.clearFinished()
        XCTAssertEqual(q.entries.map(\.id), [b], "終わった A は消え、実行中の B は残る")
        q.cancel(b)
        try await waitUntil { self.settled(q) }
    }

    func testOnChangeFiresForEachTransition() async throws {
        let q = ExportQueue()
        var calls = 0
        q.onChange = { calls += 1 }
        let rec = Recorder()
        q.enqueue(title: "A", fake("A", rec, steps: 2))
        try await waitUntil { self.settled(q) }
        XCTAssertGreaterThanOrEqual(calls, 4, "投入・開始・進み具合・完了で通知")
    }

    func testUnknownAndFinishedIDsAreNoOps() async throws {
        let q = ExportQueue()
        let rec = Recorder()
        let a = q.enqueue(title: "A", fake("A", rec, steps: 1))
        try await waitUntil { self.settled(q) }
        q.cancel(a)
        q.cancel(UUID())
        XCTAssertEqual(q.state(of: a), .finished, "終わった件は取り消しても変わらない")
        XCTAssertNil(q.state(of: UUID()))
    }
}
