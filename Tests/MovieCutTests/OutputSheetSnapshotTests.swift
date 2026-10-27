import XCTest
import SwiftUI
import AppKit
import MovieCutCore
@testable import MovieCut

/// 「解像度を入力」「フレームレートを入力」シートを画面の外で描いて PNG にする(MC_SNAPSHOT_OUT_DIR で出力先を変えられる)。
@MainActor
final class OutputSheetSnapshotTests: XCTestCase {
    private func dir() throws -> URL {
        let d = ProcessInfo.processInfo.environment["MC_SNAPSHOT_OUT_DIR"]
            ?? "/private/tmp/claude-501/-Users-USER------------/07529bfa-5715-4444-bf9c-c37229b6ab4d/scratchpad/custom-sheets"
        let u = URL(fileURLWithPath: d)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    private func snapshot<V: View>(_ view: V, name: String, size: NSSize) throws -> Int {
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: try dir().appendingPathComponent(name))
        return png.count
    }

    func testResolutionAndFpsSheets() throws {
        let m = ProjectModel(project: .new())
        m.notices = OneTimeNotices()
        m.applyVideoSize(5120, 2880)
        m.project.fps = 120
        XCTAssertGreaterThan(try snapshot(ResolutionSheet(model: m), name: "resolution.png", size: NSSize(width: 480, height: 420)), 5_000)
        m.project.fps = 29.97
        XCTAssertGreaterThan(try snapshot(FrameRateSheet(model: m), name: "fps.png", size: NSSize(width: 480, height: 300)), 5_000)
        XCTAssertGreaterThan(try snapshot(SettingsSheet(model: m), name: "settings.png", size: NSSize(width: 560, height: 900)), 5_000)
    }
}
