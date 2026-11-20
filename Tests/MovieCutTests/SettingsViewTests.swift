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
        XCTAssertTrue(r.ids.contains("settings-font-scale") || r.ids.contains("settings-language"), "アプリ設定の節は出る")
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
        let r = texts(SettingsView(documents: docs))
        XCTAssertTrue(r.ids.contains("settings-font-scale"), "文字サイズの Picker は設定ウィンドウから到達できる")
        XCTAssertEqual(SettingsContent.fontScaleLabel(.standard), L10n.t("標準（見出し 17pt・本文 14pt）"))
    }

    func testWindowControllerCountsRequestsWithoutWindow() {
        SettingsWindowController.suppressWindow = true
        let n = SettingsWindowController.showRequestCount
        SettingsWindowController.show()
        XCTAssertEqual(SettingsWindowController.showRequestCount, n + 1)
    }
}
