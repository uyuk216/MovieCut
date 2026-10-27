import XCTest
import SwiftUI
import AppKit
import MovieCutCore
@testable import MovieCut

/// 解像度・設定・書き出しをウィンドウから外し、メニューバー(出力)へ移した結果を、画面の外で描いて確かめる。
@MainActor
final class WindowSnapshotTests: XCTestCase {
    /// アクセシビリティの木から、ラベル・値・題の文字を集める。
    private func collectTexts(_ obj: Any?, into out: inout [String], depth: Int = 0) {
        guard depth < 60, let obj else { return }
        if let a = obj as? NSAccessibilityProtocol {
            if let t = a.accessibilityLabel(), !t.isEmpty { out.append(t) }
            if let t = a.accessibilityTitle(), !t.isEmpty { out.append(t) }
            if let t = a.accessibilityValue() as? String, !t.isEmpty { out.append(t) }
            for c in a.accessibilityChildren() ?? [] { collectTexts(c, into: &out, depth: depth + 1) }
        }
        if let v = obj as? NSView { for sub in v.subviews { collectTexts(sub, into: &out, depth: depth + 1) } }
    }

    func testWindowNoLongerHasResolutionSettingsOrExportControls() throws {
        let m = ProjectModel(project: .new())
        m.notices = OneTimeNotices()
        _ = m.addTextClip()
        m.playback.seek(to: 1)
        _ = m.addTextClip()
        _ = m.addBlurClip()
        m.statusText = "テスト中"

        let host = NSHostingView(rootView: ContentView(model: m, fileURL: nil))
        host.frame = NSRect(x: 0, y: 0, width: 1400, height: 900)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        host.layoutSubtreeIfNeeded()

        // 画像(PNG)
        let dir = ProcessInfo.processInfo.environment["MC_SNAPSHOT_OUT_DIR"]
            ?? "/private/tmp/claude-501/-Users-USER------------/07529bfa-5715-4444-bf9c-c37229b6ab4d/scratchpad/menu-move"
        let url = URL(fileURLWithPath: dir).appendingPathComponent("window.png")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: url)
        XCTAssertGreaterThan(png.count, 5_000)

        // 描かれたウィンドウの外観で見る(画像は上に出した)。ボタンの題の一覧は、ビューが実際に使う定数
        let titles = ToolbarBar.Title.all + TransportBar.Title.all
        for gone in ["解像度", "設定", "MP4 書き出し", "書き出し"] {
            XCTAssertFalse(titles.contains { $0.contains(gone) }, "\(gone) のボタンがウィンドウに残っている")
        }
        XCTAssertEqual(ToolbarBar.Title.all, ["素材を追加", "テキスト", "ぼかし範囲", "分割", "削除"])
        // 見える文字が取れる範囲(入力欄など)でも、取り除いたものが無い
        var texts: [String] = []
        collectTexts(host, into: &texts)
        for gone in ["解像度", "設定", "MP4 書き出し"] {
            XCTAssertFalse(texts.contains { $0.contains(gone) }, "\(gone) が木に出てくる")
        }
        // 絵の中の文字は、SwiftUI のボタンが木に出ないため、ここでは PNG で確かめる(上の画像)
    }
}
