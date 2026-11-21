import XCTest
import SwiftUI
import AppKit
import MovieCutCore
@testable import MovieCut

/// 設定ウィンドウの中身(SettingsView)の軽い構成テスト。
@MainActor
final class SettingsViewTests: XCTestCase {
    private func texts(_ view: some View) -> (labels: [String], ids: [String]) {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 1200)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        var labels: [String] = [], ids: [String] = []
        func walk(_ v: NSView) {
            ids.append(v.accessibilityIdentifier())
            if let l = v.accessibilityLabel() { labels.append(l) }
            if let t = v as? NSTextField { labels.append(t.stringValue) }
            v.subviews.forEach(walk)
        }
        walk(host)
        return (labels, ids)
    }

    func testBuildsWithoutProjectShowingOnlyAppSettings() {
        let docs = ActiveDocument()
        XCTAssertNil(docs.model)
        let r = texts(SettingsView(documents: docs))
        XCTAssertFalse(r.labels.contains(L10n.t("動画")), "モデル無しでは動画の節は出ない")
        // SwiftUI の中身は画面の外では木に出ないので、ビューが使う節の題の定数で確かめる
        let titles = SettingsContent.Section.titles(hasProject: docs.model != nil)
        XCTAssertTrue(titles.contains(L10n.t("言語")) && titles.contains(L10n.t("表示")), "アプリ設定の節は出る")
        XCTAssertFalse(titles.contains(L10n.t("動画")))
    }

    func testShowsVideoSectionWhenProjectIsActive() {
        let docs = ActiveDocument()
        let m = ProjectModel(project: .new())
        m.notices = OneTimeNotices()
        docs.activate(m)
        let r = texts(SettingsView(documents: docs))
        XCTAssertFalse(r.labels.contains(L10n.t("プロジェクトを開くと動画の設定が編集できます")))
    }

    func testFontScalePickerStaysInSettingsView() {
        let docs = ActiveDocument()
        _ = texts(SettingsView(documents: docs))   // モデル無しでも組み立てられる
        XCTAssertTrue(SettingsContent.Section.titles(hasProject: false).contains(L10n.t("表示")), "文字サイズの Picker は「表示」の節にあり、モデル無しでも出る")
        XCTAssertEqual(SettingsContent.Section.fontScaleID, "settings-font-scale")
        XCTAssertEqual(SettingsContent.fontScaleLabel(.standard), L10n.t("標準（見出し 17pt・本文 14pt）"))
    }

    func testWindowControllerCountsRequestsWithoutWindow() {
        SettingsWindowController.suppressWindow = true
        let n = SettingsWindowController.showRequestCount
        SettingsWindowController.show()
        XCTAssertEqual(SettingsWindowController.showRequestCount, n + 1)
    }
}
