import XCTest
import SwiftUI
import AppKit
import MovieCutCore
@testable import MovieCut

/// 同じセリフのテイク比較(候補 35)のモデル操作・メニュー・シート。
@MainActor
final class TakeCompareAppTests: XCTestCase {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("take-app-\(UUID().uuidString)")
    override func setUpWithError() throws { try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private func model() throws -> (ProjectModel, FakeAuditionPlayer) {
        var p = Project.new()
        var clips: [Clip] = []
        for (i, d) in [1.0, 1.4, 1.2].enumerated() {
            let u = tmp.appendingPathComponent("t\(i).wav")
            try ToneVoiceProvider.writeTone(to: u, duration: d, frequency: 220 + Double(i) * 40)
            var c = Clip(); c.id = "t\(i)"; c.type = .voice; c.text = i == 1 ? "[笑顔]こんにちは" : "こんにちは"; c.charId = p.characters[0].id
            c.src = u.path; c.start = Double(i) * 3; c.duration = d + 0.15
            clips.append(c)
        }
        p.tracks[0].clips = clips
        let m = ProjectModel(project: p)
        let fake = FakeAuditionPlayer()
        m.takePlayer = fake
        return (m, fake)
    }

    func testMenuItemAndReason() throws {
        let (m, _) = try model()
        var s = MenuState(model: m)
        let item = try XCTUnwrap(AppMenuSpec.clipCompareAndTransfer(s).first { $0.command == .compareTakes })
        XCTAssertTrue(item.enabled); XCTAssertNil(item.shortcut)
        m.project.tracks[0].clips.removeLast(2)
        s = MenuState(model: m)
        let off = try XCTUnwrap(AppMenuSpec.clipCompareAndTransfer(s).first { $0.command == .compareTakes })
        XCTAssertFalse(off.enabled)
        XCTAssertNotNil(AppMenuSpec.disabledReason(for: off, state: s))
        AppMenu.perform(.compareTakes, model: m)
        XCTAssertFalse(m.showTakeSheet, "テイクが無ければ開かない")
    }

    func testOpenPlayAndKeepOnlyWithOneUndo() throws {
        let (m, fake) = try model()
        let before = try m.project.encoded()
        AppMenu.perform(.compareTakes, model: m)
        XCTAssertTrue(m.showTakeSheet)
        XCTAssertEqual(m.takeGroups.count, 1)
        XCTAssertTrue(m.playTake(clipId: "t1"))
        XCTAssertEqual(fake.played.count, 1)
        XCTAssertEqual(m.takePlayingId, "t1")
        XCTAssertFalse(m.effectiveUndoManager.canUndo, "試聴は Undo に載せない")
        XCTAssertTrue(m.keepOnlyTake("t1"))
        XCTAssertEqual(m.project.allClips.map(\.id), ["t1"])
        XCTAssertNil(m.takePlayingId)
        XCTAssertGreaterThanOrEqual(fake.stopCount, 1)
        m.effectiveUndoManager.undo()
        XCTAssertFalse(m.effectiveUndoManager.canUndo)
        XCTAssertEqual(try m.project.encoded(), before)
    }

    func testMissingFileAndNoOps() throws {
        let (m, _) = try model()
        m.project.tracks[0].clips[0].src = "/nonexistent/x.wav"
        XCTAssertFalse(m.playTake(clipId: "t0"))
        XCTAssertFalse(m.playTake(clipId: "nope"))
        XCTAssertFalse(m.keepOnlyTake("nope"))
        XCTAssertFalse(m.effectiveUndoManager.canUndo)
    }

    func testSheetRendersWithMetrics() async throws {
        let (m, _) = try model()
        let host = NSHostingView(rootView: TakeCompareSheet(model: m).background(Color(nsColor: .windowBackgroundColor)))
        host.frame = NSRect(x: 0, y: 0, width: 760, height: 380)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        // 数字を測り終えるまで少し待つ
        for _ in 0..<20 { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 5_000)
        let out = tmp.appendingPathComponent("takes.png")
        try png.write(to: out)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
        XCTAssertTrue(TakeCompareSheet.metricText(TakeCompare.Metrics(averageDb: -20, peakDb: -10, leadSilence: 0.1, trailSilence: 0.2, speechLength: 1)).contains("平均 -20.0 dB"))
        XCTAssertEqual(TakeCompareSheet.metricText(TakeCompare.Metrics(averageDb: nil, peakDb: nil, leadSilence: 1, trailSilence: 0, speechLength: 0)), "声なし")
    }
}
