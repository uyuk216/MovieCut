import XCTest
import MovieCutCore
@testable import MovieCut

/// 書き出しキュー(App 側): 偽の書き出しで、順番・1 件ずつ・写しの中身・取り消し・失敗を確かめる。
@MainActor
final class ExportQueueAppTests: XCTestCase {
    private struct Boom: LocalizedError { var errorDescription: String? { "わざと失敗" } }

    /// 偽の書き出し。ファイル名で振る舞いを変える: slow.mp4 は取り消されるまで待つ、fail.mp4 は失敗する、他は進み具合を 1 回出して終わる。
    private final class Fake {
        var started: [String] = []
        var projects: [String: Project] = [:]
        var active = 0
        var maxActive = 0
    }

    private func makeController(_ fake: Fake) -> ExportQueueController {
        ExportQueueController { project, _, url, progress in
            fake.started.append(url.lastPathComponent)
            fake.projects[url.lastPathComponent] = project
            fake.active += 1
            fake.maxActive = max(fake.maxActive, fake.active)
            defer { fake.active -= 1 }
            if url.lastPathComponent == "fail.mp4" { throw Boom() }
            if url.lastPathComponent == "slow.mp4" {
                progress(0.3)
                while true { try await Task.sleep(nanoseconds: 5_000_000) }   // キャンセルで CancellationError
            }
            progress(0.5)
        }
    }

    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/moviecut-queue-test/\(name)") }

    /// 待っている件と実行中の件がなくなるまで待つ(タイムアウトしたら失敗)。
    private func settle(_ c: ExportQueueController, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<600 {
            if !c.queue.isBusy && c.entries.allSatisfy({ !$0.state.isActive }) { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("キューが終わらなかった", file: file, line: line)
    }

    private func state(_ c: ExportQueueController, _ name: String) -> ExportQueue.State? {
        c.entries.first { $0.title == name }?.state
    }

    func testJobsRunInOrderOneAtATimeAndFinish() async {
        let fake = Fake()
        let c = makeController(fake)
        c.enqueue(project: Project.new(), range: nil, to: url("a.mp4"))
        c.enqueue(project: Project.new(), range: nil, to: url("b.mp4"))
        c.enqueue(project: Project.new(), range: nil, to: url("c.mp4"))
        await settle(c)
        XCTAssertEqual(fake.started, ["a.mp4", "b.mp4", "c.mp4"], "投入された順に 1 件ずつ")
        XCTAssertEqual(fake.maxActive, 1, "並列にはしない")
        XCTAssertEqual(c.entries.map(\.state), [.finished, .finished, .finished])
        XCTAssertEqual(c.destination(of: c.entries[0].id), url("a.mp4").path, "保存先を一覧用に覚える")
    }

    func testQueuedJobKeepsSnapshotOfProjectAtEnqueueTime() async {
        let fake = Fake()
        let c = makeController(fake)
        let model = ProjectModel(project: Project.new())
        let before = model.project
        // 積んだあとで、本体の設定を変える(Undo も登録される普通の編集)
        c.enqueue(project: model.project, range: nil, to: url("snap.mp4"))
        model.edit("テスト") { $0.fps = 12 }
        model.edit("テスト2") { $0.codec = "hevc" }
        await settle(c)
        XCTAssertEqual(fake.projects["snap.mp4"], before, "書き出しは積んだ時点の写しで行う")
        XCTAssertNotEqual(model.project, before, "本体は変わっている")
    }

    func testCancellingWaitingJobNeverRunsIt() async {
        let fake = Fake()
        let c = makeController(fake)
        c.enqueue(project: Project.new(), range: nil, to: url("slow.mp4"))
        let waiting = c.enqueue(project: Project.new(), range: nil, to: url("next.mp4"))
        c.cancel(waiting)
        XCTAssertEqual(c.queue.state(of: waiting), .cancelled, "待っている件はすぐ取り消しになる")
        c.cancel(c.entries[0].id)            // 実行中の件を取り消す
        await settle(c)
        XCTAssertEqual(fake.started, ["slow.mp4"], "取り消した待ちの件は実行されない")
        XCTAssertEqual(state(c, "slow.mp4"), .cancelled)
        XCTAssertEqual(state(c, "next.mp4"), .cancelled)
    }

    func testFailureIsReportedAndQueueContinues() async {
        let fake = Fake()
        let c = makeController(fake)
        c.enqueue(project: Project.new(), range: nil, to: url("fail.mp4"))
        c.enqueue(project: Project.new(), range: nil, to: url("ok.mp4"))
        await settle(c)
        XCTAssertEqual(state(c, "fail.mp4"), .failed("わざと失敗"))
        XCTAssertEqual(state(c, "ok.mp4"), .finished, "失敗しても次の件は進む")
    }

    func testClearFinishedKeepsActiveJobs() async {
        let fake = Fake()
        let c = makeController(fake)
        c.enqueue(project: Project.new(), range: nil, to: url("done.mp4"))
        await settle(c)
        c.enqueue(project: Project.new(), range: nil, to: url("slow.mp4"))
        c.clearFinished()
        XCTAssertEqual(c.entries.map(\.title), ["slow.mp4"], "終わった件は消え、動いている件は残る")
        c.cancel(c.entries[0].id)
        await settle(c)
        c.clearFinished()
        XCTAssertTrue(c.entries.isEmpty)
        XCTAssertNil(c.destination(of: UUID()))
    }

    /// 直接の書き出しは、キューの件が動いている間は始めない(同じ時に 2 つ走らせない)。
    func testDirectExportIsRefusedWhileQueuedJobRuns() async {
        let fake = Fake()
        let c = makeController(fake)
        let m = ProjectModel(project: Project.new())
        m.notices = OneTimeNotices()
        m.exportQueueOverride = c
        c.enqueue(project: Project.new(), range: nil, to: url("slow.mp4"))
        for _ in 0..<400 where !c.queue.isBusy { try? await Task.sleep(nanoseconds: 5_000_000) }
        let outcome = await m.runExport(to: url("direct.mp4"))
        guard case .failure = outcome else { return XCTFail("キューが動いている間は直接書き出さない: \(outcome)") }
        XCTAssertFalse(m.isExporting)
        XCTAssertTrue(m.statusText.contains("キュー"), "理由を状態欄に出す: \(m.statusText)")
        c.cancel(c.entries[0].id)
        await settle(c)
    }

    /// キューの件は、書き出しシートと同じく Dock の進行バーとアプリ前面でない時の知らせを使う(終わったら消す)。
    func testQueuedJobDrivesDockProgressAndAttention() async {
        let dock = DockProgressController(tile: nil)
        dock.isAppActive = { false }
        var bounces = 0
        dock.requestAttention = { bounces += 1 }
        var seen: [Double] = []
        let c = ExportQueueController(runner: { _, _, _, progress in
            progress(0.5)
            try await Task.sleep(nanoseconds: 30_000_000)
            seen.append(dock.fraction ?? -1)
        }, dock: dock)
        c.enqueue(project: Project.new(), range: nil, to: url("dock.mp4"))
        await settle(c)
        XCTAssertEqual(seen, [0.5], "キューの件の間は Dock に進み具合が出る")
        XCTAssertNil(dock.fraction, "終わったら進行バーを消す")
        XCTAssertEqual(bounces, 1, "前面でなければ知らせる")
    }

    func testStatusTextForEachState() {
        XCTAssertEqual(ExportQueueSheet.statusText(.waiting), "待機中")
        XCTAssertEqual(ExportQueueSheet.statusText(.running(0.456)), "書き出し中 46%")
        XCTAssertEqual(ExportQueueSheet.statusText(.finished), "完了")
        XCTAssertEqual(ExportQueueSheet.statusText(.cancelled), "取り消し")
        XCTAssertEqual(ExportQueueSheet.statusText(.failed("x")), "失敗: x")
    }
}
