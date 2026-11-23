import XCTest
import MovieCutCore
@testable import MovieCut

/// 第2部 A02〜A07 のアプリ側修正の回帰テスト。
@MainActor
final class BugHunt2AppFixTests: XCTestCase {

    // A02: グループの有効/無効の切り替え方向は、ロックされたメンバーに引きずられない
    func testGroupToggleDirectionIgnoresLockedMembers() {
        let m = ProjectModel(project: .new())
        var a = Clip(); a.id = "a"; a.type = .image; a.start = 0; a.duration = 2
        var c = Clip(); c.id = "c"; c.type = .text; c.start = 1; c.duration = 2
        m.project.tracks[0].clips = [a]
        if m.project.tracks.count < 2 { m.project.tracks.append(Track(name: "下")) }
        m.project.tracks[1].clips = [c]
        m.setSelection(ClipSelection(ids: ["a", "c"], primary: "a"))
        XCTAssertTrue(m.groupSelectedClips())
        // 編集できる a だけが無効、ロック側の c は有効なまま、という状態を作る
        m.project.tracks[0].clips[0].disabled = true
        m.project.tracks[1].locked = true
        m.selectOnly("a")
        XCTAssertTrue(m.toggleGroupDisabledSelected())
        XCTAssertFalse(m.clip("a")?.isDisabled ?? true,
                       "編集できるメンバーが全員無効なら、切り替えは有効化でなければならない")
    }

    // A06: 素材キャッシュの鍵は、秒未満の更新時刻の違いを区別する
    func testThumbKeyDistinguishesSubSecondStamps() {
        let k1 = TimelineMediaCache.thumbKey(path: "/x.mp4", stamp: 100.4, time: 1.0)
        let k2 = TimelineMediaCache.thumbKey(path: "/x.mp4", stamp: 100.6, time: 1.0)
        XCTAssertNotEqual(k1, k2)
    }

    // A07: 画面より背の高いウィンドウでも、上端は画面の中に残る
    func testWindowSanitizeKeepsTopOnScreen() {
        let r = WindowFramePolicy.sanitize(NSRect(x: 100, y: 50, width: 800, height: 2000),
                                      minSize: NSSize(width: 400, height: 1200),
                                      visibleFrames: [NSRect(x: 0, y: 0, width: 1920, height: 1080)])
        XCTAssertEqual(r.maxY, 1080, accuracy: 0.5)
    }

    // A07: キューの書き出しは、素材が無ければ欠けたまま完了にしない
    func testQueuedExportFailsOnMissingMedia() async {
        var p = Project.new()
        var v = Clip(); v.id = "v"; v.type = .video; v.src = "/nonexistent-bughunt2/nope.mp4"; v.start = 0; v.duration = 2
        p.tracks[0].clips = [v]
        do {
            try await ExportQueueController.defaultRunner(p, nil, URL(fileURLWithPath: "/tmp/bughunt2-out.mp4")) { _ in }
            XCTFail("素材が無いのに書き出しが始まってしまった")
        } catch {
            XCTAssertTrue(error is MissingMediaExportError, "素材不足の失敗でなければならない: \(error)")
        }
    }
}
