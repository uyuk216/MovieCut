import XCTest
import MovieCutCore
@testable import MovieCut

/// 出力 ▸ 素材の内容を検索…(メディアインテリジェンス検索 第 1 段): ヒットへのジャンプとメニュー項目。
@MainActor
final class MediaSearchAppTests: XCTestCase {
    private func state(_ f: (inout MenuState) -> Void = { _ in }) -> MenuState {
        var s = MenuState(); s.hasDocument = true; f(&s); return s
    }

    /// 素材の 40 秒から 20 秒使うクリップが、タイムラインの 100 秒に置かれているモデル。
    private func makeModel() -> (ProjectModel, Clip) {
        var p = Project.new()
        var c = Clip()
        c.type = .video
        c.src = "/media/interview.mp4"
        c.start = 100
        c.duration = 20
        c.offset = 40
        p.tracks[0].clips = [c]
        let m = ProjectModel(project: p)
        m.notices = OneTimeNotices()
        return (m, c)
    }

    private func hit(src: String = "/media/interview.mp4", start: Double = 45) -> MediaSearch.Hit {
        MediaSearch.Hit(src: src, path: src, mediaName: (src as NSString).lastPathComponent,
                        start: start, end: start + 3, text: "キーボードの話", kind: .transcript)
    }

    func testJumpMovesPlayheadSelectsClipAndClosesSheet() {
        let (m, c) = makeModel()
        m.showMediaSearchSheet = true
        XCTAssertTrue(m.jumpToMediaHit(hit()))
        XCTAssertEqual(m.currentTime, 105, "100 + (45 - 40)")
        XCTAssertEqual(m.selectedClipIDs, [c.id])
        XCTAssertFalse(m.showMediaSearchSheet)
        XCTAssertTrue(m.statusText.contains("interview.mp4"))
    }

    func testJumpFailsForMediaNotOnTimeline() {
        let (m, _) = makeModel()
        m.currentTime = 7
        XCTAssertFalse(m.jumpToMediaHit(hit(src: "/media/other.wav", start: 1)))
        XCTAssertEqual(m.currentTime, 7, "対応づけられないときは何もしない")
    }

    func testMenuItemSpec() {
        let item = AppMenuSpec.mediaSearchItem(state())
        XCTAssertEqual(item.title, "素材の内容を検索…")
        XCTAssertEqual(item.command, .mediaSearch)
        XCTAssertNil(item.shortcut, "ショートカットは持たない")
        XCTAssertTrue(item.enabled)
        XCTAssertFalse(AppMenuSpec.mediaSearchItem(state { $0.hasDocument = false }).enabled)
        XCTAssertFalse(AppMenuSpec.mediaSearchItem(state { $0.isLocked = true }).enabled)
        XCTAssertTrue(AppMenuSpec.all(state()).contains { $0.command == .mediaSearch })
    }

    func testOpenMediaSearchShowsSheet() {
        let (m, _) = makeModel()
        m.openMediaSearch()
        XCTAssertTrue(m.showMediaSearchSheet)
    }
}
