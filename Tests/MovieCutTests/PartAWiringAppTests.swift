import XCTest
import AppKit
import MovieCutCore
@testable import MovieCut

/// 配線(Part A・ソースの使用範囲): メニューの有効・無効、理由、選んだクリップの頭へ移す操作。
@MainActor
final class PartAWiringAppTests: XCTestCase {
    private func makeModel() -> ProjectModel {
        var p = Project.new()
        p.width = 320; p.height = 180; p.fps = 10
        var v = Clip(); v.id = "v"; v.type = .video; v.src = "/x.mp4"; v.start = 1; v.duration = 2; v.offset = 3; v.srcDuration = 20
        var t = Clip(); t.id = "t"; t.type = .text; t.text = "文字"; t.start = 5; t.duration = 1; t.fontSize = 60
        p.tracks[4].clips = [v, t]
        let m = ProjectModel(project: p)
        m.notices = OneTimeNotices()
        return m
    }

    func testSourceUsageMenuFollowsSelection() {
        let m = makeModel()
        XCTAssertFalse(MenuState(model: m).hasSourceUsage, "選択なし")
        m.selectOnly("v")
        XCTAssertTrue(MenuState(model: m).hasSourceUsage, "動画の 1 つを選ぶ")
        m.selectOnly("t")
        XCTAssertFalse(MenuState(model: m).hasSourceUsage, "文字には素材の区間が無い")
    }

    func testSourceUsageMenuItemIsDisabledWithReason() throws {
        let m = makeModel()
        let s = MenuState(model: m)
        let item = try XCTUnwrap(AppMenuSpec.clipNavigate(s).first { $0.command == .sourceUsage })
        XCTAssertFalse(item.enabled)
        XCTAssertEqual(AppMenuSpec.disabledReason(for: item, state: s), "動画・音声・画像のクリップを 1 つ選んでください(フリーズは対象外)")
        XCTAssertNil(item.shortcut, "ショートカットは付けない")
    }

    func testShowSourceUsageMovesPlayheadAndReportsRange() {
        let m = makeModel()
        XCTAssertFalse(m.showSourceUsage(), "選択が無いときは何もしない")
        m.selectOnly("v")
        XCTAssertTrue(m.showSourceUsage())
        XCTAssertEqual(m.currentTime, 1, accuracy: 1e-9, "クリップの頭へ移す")
        XCTAssertEqual(m.statusText, "ソースの使用範囲 00:03–00:05")
        m.selectOnly("t")
        XCTAssertFalse(m.showSourceUsage(), "文字は false")
    }

    func testScriptAndStoryboardItemsEnablement() {
        let m = makeModel()
        var s = MenuState(model: m)
        s.hasVoiceClips = false
        let items = AppMenuSpec.scriptStoryboardItems(s)
        let script = items.first { $0.command == .exportScript }!
        XCTAssertFalse(script.enabled)
        XCTAssertEqual(AppMenuSpec.disabledReason(for: script, state: s), "声のクリップがありません")
        XCTAssertTrue(items.allSatisfy { $0.shortcut == nil }, "ショートカットは付けない")
        s.hasVoiceClips = true
        XCTAssertTrue(AppMenuSpec.scriptStoryboardItems(s).first { $0.command == .exportScript }!.enabled)
        s.canExport = false
        let board = AppMenuSpec.scriptStoryboardItems(s).first { $0.command == .exportStoryboard }!
        XCTAssertFalse(board.enabled)
        XCTAssertEqual(AppMenuSpec.disabledReason(for: board, state: s), "書き出せるクリップがありません")
    }
}
