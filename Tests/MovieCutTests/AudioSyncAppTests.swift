import XCTest
import AVFoundation
import MovieCutCore
@testable import MovieCut

/// クリップ ▸ 音声で映像と音声を自動同期: 項目表・無効の理由・ショートカットなし、実際の音ファイルでのずれ検出、1 回の Undo。
@MainActor
final class AudioSyncAppTests: XCTestCase {
    private var tmp: URL!
    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("audiosync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    /// 長さの違う音の塊と無音の並び(同じ並びを毎回作る)。`lead` 秒の無音を頭に足す。
    private func writeWav(_ name: String, lead: Double) throws -> String {
        let pattern: [(Double, Float)] = [(0.5, 0.3), (0.4, 0), (0.2, 0.5), (0.3, 0), (0.9, 0.2), (0.6, 0),
                                          (0.3, 0.4), (0.2, 0), (0.7, 0.1), (0.5, 0), (0.4, 0.5), (0.3, 0)]
        let segments = (lead > 0 ? [(lead, Float(0))] : []) + pattern
        let url = tmp.appendingPathComponent(name)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1,
                                       AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let total = segments.reduce(0) { $0 + Int($1.0 * 48000) }
        let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(total))!
        buf.frameLength = AVAudioFrameCount(total)
        var i = 0
        for (d, a) in segments { for _ in 0..<Int(d * 48000) { buf.floatChannelData![0][i] = a * Float(sin(2 * .pi * 300 * Double(i) / 48000)); i += 1 } }
        try file.write(from: buf)
        return url.path
    }

    private func makeModel() throws -> ProjectModel {
        var v = Clip(); v.id = "v"; v.type = .video; v.src = try writeWav("v.wav", lead: 0); v.start = 5; v.duration = 5.3
        var a = Clip(); a.id = "a"; a.type = .audio; a.src = try writeWav("a.wav", lead: 0.37); a.start = 3; a.duration = 5.3
        var p = Project.new()
        p.tracks[0].clips = [v]
        var t2 = Track(); t2.clips = [a]; p.tracks.append(t2)
        let m = ProjectModel(project: p)
        m.notices = OneTimeNotices()
        return m
    }

    private func settle(until: () -> Bool) async {
        for _ in 0..<300 where !until() { try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    func testMenuItemConditionReasonAndNoShortcut() throws {
        var s = MenuState(); s.hasDocument = true
        XCTAssertFalse(AppMenuSpec.audioAutoSyncItem(s).enabled)
        XCTAssertEqual(AppMenuSpec.disabledReason(for: AppMenuSpec.audioAutoSyncItem(s), state: s), AudioSyncEditing.selectionHint)
        s.canAudioAutoSync = true
        let it = AppMenuSpec.audioAutoSyncItem(s)
        XCTAssertTrue(it.enabled); XCTAssertNil(it.shortcut)
        XCTAssertEqual(it.command, .audioAutoSync); XCTAssertEqual(it.title, "音声で映像と音声を自動同期")
        XCTAssertTrue(AppMenuSpec.all(s).contains { $0.command == .audioAutoSync })
        var locked = s; locked.isLocked = true
        XCTAssertFalse(AppMenuSpec.audioAutoSyncItem(locked).enabled)
    }

    func testMenuStateFollowsSelection() throws {
        let m = try makeModel()
        m.setSelection(ClipSelection(ids: ["v", "a"], primary: "v"))
        XCTAssertTrue(MenuState(model: m).canAudioAutoSync)
        m.setSelection(ClipSelection(ids: ["v"], primary: "v"))
        XCTAssertFalse(MenuState(model: m).canAudioAutoSync)
    }

    func testPerformSyncsRealAudioInOneUndoStep() async throws {
        let m = try makeModel()
        m.setSelection(ClipSelection(ids: ["v", "a"], primary: "v"))
        let u = m.effectiveUndoManager
        AppMenu.perform(.audioAutoSync, model: m)
        await settle { m.clip("a")?.start != 3 }
        XCTAssertEqual(try XCTUnwrap(m.clip("a")).start, 4.63, accuracy: 0.011)
        XCTAssertEqual(m.clip("v")!.start, 5)
        XCTAssertEqual(u.undoActionName, ProjectModel.audioSyncUndoName)
        var n = 0
        while u.canUndo { u.undo(); n += 1 }
        XCTAssertEqual(n, 1)
        XCTAssertEqual(m.clip("a")!.start, 3)
    }

    func testWrongSelectionDoesNothing() async throws {
        let m = try makeModel()
        m.selectedClipId = "a"
        AppMenu.perform(.audioAutoSync, model: m)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(m.clip("a")!.start, 3)
        XCTAssertFalse(m.effectiveUndoManager.canUndo)
    }

    func testNoChangeRegistersNoUndo() throws {
        let m = try makeModel()
        XCTAssertFalse(m.applyAudioSync(videoId: "v", audioId: "a", lag: 2.0), "すでに 3 秒 = 5 − 2 なので動かない")
        XCTAssertFalse(m.effectiveUndoManager.canUndo)
        XCTAssertTrue(m.applyAudioSync(videoId: "v", audioId: "a", lag: 1.0))
        XCTAssertEqual(m.clip("a")!.start, 4)
    }
}
