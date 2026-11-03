import XCTest
import SwiftUI
import AppKit
import MovieCutCore
@testable import MovieCut

/// 範囲を指定してサブクリップを一括作成(候補 38)。全体が 1 回の Undo。
@MainActor
final class SubclipBatchAppTests: XCTestCase {
    private func model() -> ProjectModel {
        var p = Project.new()
        p.mediaPool = ["/m/intro.mov", "/m/bgm.wav", "/m/photo.png"]
        let m = ProjectModel(project: p)
        m.candidateProbe = { url, _ in url.lastPathComponent == "bgm.wav" ? 10 : 60 }
        m.currentTime = 3
        return m
    }

    func testMenuItem() throws {
        let m = model()
        let s = MenuState(model: m)
        let item = try XCTUnwrap(AppMenuSpec.clipCompareAndTransfer(s).first { $0.command == .subclipBatch })
        XCTAssertTrue(item.enabled); XCTAssertNil(item.shortcut)
        AppMenu.perform(.subclipBatch, model: m)
        XCTAssertTrue(m.showSubclipSheet)
        XCTAssertEqual(m.subclipPoolItems, ["/m/intro.mov", "/m/bgm.wav"], "画像は指定の候補に出さない")
    }

    func testCreateOneUndoPlacedAtPlayhead() async throws {
        let m = model()
        let before = try m.project.encoded()
        let n = await m.createSubclips(from: "intro 0:05-0:12, 0:30-0:41\nbgm 8-20\nphoto.png 1-2\nzzz 1-2")
        XCTAssertEqual(n, 3)
        let clips = m.project.tracks.flatMap(\.clips)
        XCTAssertEqual(clips.map(\.start), [3, 10, 21])
        XCTAssertEqual(clips.map(\.offset), [5, 30, 8])
        XCTAssertEqual(clips.map(\.duration), [7, 11, 2], "bgm は素材の長さ(10 秒)までに詰まる")
        XCTAssertEqual(Set(m.project.mediaPool), ["/m/intro.mov", "/m/bgm.wav", "/m/photo.png"])
        XCTAssertEqual(m.selectedClipIDs.count, 3)
        XCTAssertTrue(m.statusText.contains("3 個のサブクリップを作りました"))
        XCTAssertTrue(m.statusText.contains("2 件"), m.statusText)
        XCTAssertEqual(m.effectiveUndoManager.undoActionName, "サブクリップを一括作成")
        m.effectiveUndoManager.undo()
        XCTAssertFalse(m.effectiveUndoManager.canUndo, "1 回で元に戻る")
        XCTAssertEqual(try m.project.encoded(), before)
    }

    func testNothingValidCreatesNothing() async throws {
        let m = model()
        let n = await m.createSubclips(from: "zzz 1-2")
        XCTAssertEqual(n, 0)
        XCTAssertTrue(m.statusText.contains("1 行目"))
        let n2 = await m.createSubclips(from: "   ")
        XCTAssertEqual(n2, 0)
        XCTAssertFalse(m.effectiveUndoManager.canUndo)
        XCTAssertTrue(m.project.allClips.isEmpty)
    }

    func testSheetRenders() throws {
        let m = model()
        let host = NSHostingView(rootView: SubclipBatchSheet(model: m).background(Color(nsColor: .windowBackgroundColor)))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 420)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        XCTAssertGreaterThan(try XCTUnwrap(rep.representation(using: .png, properties: [:])).count, 5_000)
    }
}
