import XCTest
import AVFoundation
import MovieCutCore
@testable import MovieCut

/// 無音カットと BGM の自動ダッキング: メニューの仕様表、モデルの操作(1 操作 = 1 回の Undo、何も変わらない操作は登録しない)、再生用ミックスの鍵。
@MainActor
final class SilenceDuckAppTests: XCTestCase {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("silduck-app-\(UUID().uuidString)")
    override func setUpWithError() throws { try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private func clip(_ id: String, _ type: ClipType, start: Double, dur: Double, src: String = "/tmp/none.wav") -> Clip {
        var c = Clip(); c.id = id; c.type = type; c.start = start; c.duration = dur; c.src = src; c.srcDuration = dur; c.volume = 1
        return c
    }

    private func makeModel(_ clips: [Clip], second: [Clip] = []) -> ProjectModel {
        var p = Project.new()
        p.tracks[0].clips = clips
        p.tracks[1].clips = second
        let m = ProjectModel(project: p)
        m.notices = OneTimeNotices()
        return m
    }

    private func undoSteps(_ m: ProjectModel) -> Int {
        let u = m.effectiveUndoManager
        var n = 0
        while u.canUndo { u.undo(); n += 1 }
        for _ in 0..<n { u.redo() }
        return n
    }

    private func state(_ configure: (inout MenuState) -> Void = { _ in }) -> MenuState {
        var s = MenuState()
        s.hasDocument = true; s.canExport = true
        s.resolutionKey = "1920x1080"; s.codec = "h264"; s.bg = "#000000"
        configure(&s)
        return s
    }

    // MARK: メニュー

    func testMenuSpecs() {
        let item = AppMenuSpec.silenceCutItem(state { $0.canSilenceCut = true })
        XCTAssertEqual(item.title, "無音をカット…"); XCTAssertEqual(item.command, .silenceCut)
        XCTAssertTrue(item.enabled); XCTAssertNil(item.shortcut)
        XCTAssertFalse(AppMenuSpec.silenceCutItem(state()).enabled)
        XCTAssertFalse(AppMenuSpec.silenceCutItem(state { $0.canSilenceCut = true; $0.isLocked = true }).enabled)

        let duck = AppMenuSpec.audioItems(state { $0.canAudioFx = true; $0.canDuck = true; $0.isDucking = true }).first { $0.command == .audioDuckToggle }
        XCTAssertEqual(duck?.enabled, true); XCTAssertEqual(duck?.checked, true)
        XCTAssertNil(AppMenuSpec.audioItems(state { $0.canAudioFx = true }).first { $0.command == .audioDuckToggle }?.checked)
        // 全項目の表に入り、ショートカットは衝突しない
        let all = AppMenuSpec.all(state { $0.canSilenceCut = true })
        XCTAssertTrue(all.contains { $0.command == .silenceCut })
        let used = all.compactMap(\.shortcut)
        XCTAssertEqual(used.count, Set(used).count)
    }

    func testMenuStateFromModel() {
        let m = makeModel([clip("bgm", .audio, start: 0, dur: 5), clip("img", .image, start: 6, dur: 2), clip("v", .voice, start: 8, dur: 2)])
        m.selectedClipId = "bgm"
        var s = MenuState(model: m)
        XCTAssertTrue(s.canSilenceCut); XCTAssertTrue(s.canDuck); XCTAssertFalse(s.isDucking)
        m.selectedClipId = "img"; s = MenuState(model: m)
        XCTAssertFalse(s.canSilenceCut); XCTAssertFalse(s.canDuck)
        m.selectedClipId = "v"; s = MenuState(model: m)
        XCTAssertTrue(s.canSilenceCut); XCTAssertFalse(s.canDuck, "ダッキングは BGM(音声クリップ)だけ")
    }

    // MARK: ダッキングの操作

    func testToggleDuckViaMenuIsOneUndoStepAndNoOpRegistersNothing() {
        let m = makeModel([clip("bgm", .audio, start: 0, dur: 5), clip("v", .voice, start: 8, dur: 2)])
        let u = m.effectiveUndoManager
        m.selectedClipId = "v"
        AppMenu.perform(.audioDuckToggle, model: m)          // ボイスには付かない
        XCTAssertNil(m.clip("v")?.duck); XCTAssertEqual(undoSteps(m), 0)
        m.selectedClipId = "bgm"
        AppMenu.perform(.audioDuckToggle, model: m)
        XCTAssertEqual(m.clip("bgm")?.hasDuck, true)
        XCTAssertEqual(u.undoActionName, "自動ダッキングをオン")
        XCTAssertEqual(undoSteps(m), 1)
        AppMenu.perform(.audioDuckToggle, model: m)
        XCTAssertNil(m.clip("bgm")?.duck)
        XCTAssertEqual(undoSteps(m), 2)
        u.undo(); u.undo()
        XCTAssertNil(m.clip("bgm")?.duck)
        // 数値を同じ値にしても履歴は増えない
        m.setDuck({ _ = DuckEditing.setEnabled(&$0, true) }, clipId: "bgm")
        m.setDuck({ _ = DuckEditing.setAmount(&$0, -18) }, clipId: "bgm")
        let n = undoSteps(m)
        m.setDuck({ _ = DuckEditing.setAmount(&$0, -18) }, clipId: "bgm")
        XCTAssertEqual(undoSteps(m), n)
    }

    func testSliderDragIsOneUndoStep() {
        let m = makeModel([clip("bgm", .audio, start: 0, dur: 5)])
        m.selectedClipId = "bgm"
        m.setDuck({ _ = DuckEditing.setEnabled(&$0, true) })
        let before = undoSteps(m)
        m.beginGesture()
        for v in stride(from: -12.0, through: -24, by: -1) { m.liveDuck({ _ = DuckEditing.setAmount(&$0, v) }) }
        m.commitGesture("自動ダッキングの変更")
        XCTAssertEqual(m.clip("bgm")?.duck?.amountDb, -24)
        XCTAssertEqual(undoSteps(m), before + 1)
    }

    func testDuckChangesPlaybackMixKey() {
        var p = makeModel([clip("bgm", .audio, start: 0, dur: 5), clip("v", .voice, start: 1, dur: 2)]).project
        let date: (String) -> Date? = { _ in Date(timeIntervalSinceReferenceDate: 1000) }
        let k0 = AudioCacheKey.make(for: p, fileDate: date)
        p.tracks[0].clips[0].duck = Duck()
        let k1 = AudioCacheKey.make(for: p, fileDate: date)
        XCTAssertNotEqual(k0, k1)
        p.tracks[0].clips[0].duck = Duck(amount: -20)
        XCTAssertNotEqual(k1, AudioCacheKey.make(for: p, fileDate: date))
        // 切ってある(enabled = false)なら鍵は変わらない
        p.tracks[0].clips[0].duck = Duck(amount: -20, enabled: false)
        XCTAssertEqual(k0, AudioCacheKey.make(for: p, fileDate: date))
    }

    // MARK: 無音カットの操作

    func writeWav(_ name: String, segments: [(Double, Float)]) throws -> String {
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

    func testOpenSheetOnlyForSupportedClip() {
        let m = makeModel([clip("bgm", .audio, start: 0, dur: 5), clip("img", .image, start: 6, dur: 2)])
        m.selectedClipId = "img"; AppMenu.perform(.silenceCut, model: m)
        XCTAssertFalse(m.showSilenceSheet)
        m.selectedClipId = "bgm"; AppMenu.perform(.silenceCut, model: m)
        XCTAssertTrue(m.showSilenceSheet); XCTAssertEqual(m.silenceClipId, "bgm")
    }

    func testCutSilenceIsOneUndoStepAndRestoresExactly() throws {
        let path = try writeWav("s.wav", segments: [(1, 0.3), (1.5, 0), (1, 0.3), (0.2, 0), (0.8, 0.3), (1.5, 0)])
        var main = clip("main", .audio, start: 0, dur: 6, src: path)
        main.srcDuration = 6
        let after = clip("after", .audio, start: 6, dur: 2)
        let m = makeModel([main, after])
        let original = m.project
        let u = m.effectiveUndoManager
        let prof = try XCTUnwrap(SilenceDetector.analyze(clip: main))
        XCTAssertTrue(m.cutSilence(clipId: "main", profile: prof, params: .default, ripple: true))
        XCTAssertEqual(u.undoActionName, "無音をカット")
        XCTAssertEqual(undoSteps(m), 1)
        XCTAssertEqual(m.project.tracks[0].clips.count, 3)
        XCTAssertEqual(m.clip("after")?.start ?? 0, 6 - 2.7, accuracy: 0.05)
        XCTAssertEqual(m.selectedClipId, "main")
        u.undo()
        XCTAssertEqual(m.project, original)                 // 1 回の Undo でぴったり元に戻る
        // 切る所が無い設定なら何も登録しない
        XCTAssertFalse(m.cutSilence(clipId: "main", profile: prof, params: SilenceParams(thresholdDb: -80, minSilence: 5, pad: 0), ripple: true))
        XCTAssertEqual(m.project, original); XCTAssertEqual(undoSteps(m), 0)
        // ロックされたレイヤーは編集できない
        m.project.tracks[0].locked = true
        XCTAssertFalse(m.cutSilence(clipId: "main", profile: prof, params: .default, ripple: true))
    }
}
