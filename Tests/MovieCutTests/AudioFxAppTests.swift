import XCTest
import SwiftUI
import AppKit
import CryptoKit
import MovieCutCore
@testable import MovieCut

/// 音声エフェクト・パン・音量のキー: モデルの操作(Undo)、メニュー、再生用ミックスの鍵、インスペクタ(撮影)。
@MainActor
final class AudioFxAppTests: XCTestCase {
    static let snapshotDir = (ProcessInfo.processInfo.environment["MC_SNAPSHOT_OUT_DIR_AUDIOFX"]
        ?? "/private/tmp/claude-501/-Users-USER------------/07529bfa-5715-4444-bf9c-c37229b6ab4d/scratchpad/audiofx")

    private func clip(_ id: String, _ type: ClipType, start: Double, dur: Double) -> Clip {
        var c = Clip(); c.id = id; c.type = type; c.start = start; c.duration = dur
        if type == .image || type == .video { c.src = "/tmp/none.png" }
        if type == .audio { c.src = "/tmp/none.wav"; c.srcDuration = dur }
        if type == .voice { c.src = "/tmp/none.wav"; c.text = "こんにちは" }
        return c
    }

    /// a(画像)、m(音声 0〜6)、v(動画 2〜8)、k(ボイス 10〜12)
    private func makeModel() -> ProjectModel {
        var p = Project.new()
        p.fps = 60
        p.tracks[0].clips = [clip("a", .image, start: 0, dur: 4), clip("m", .audio, start: 0, dur: 6), clip("k", .voice, start: 10, dur: 2)]
        p.tracks[1].clips = [clip("v", .video, start: 2, dur: 6)]
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

    // MARK: モデル(1 操作 = 1 Undo)

    func testEachEditIsOneUndoStepAndNoOpsRegisterNothing() {
        let m = makeModel()
        let u = m.effectiveUndoManager
        m.selectedClipId = "m"
        m.setAudioFx({ _ = AudioFxEditing.setCompressorEnabled(&$0, false) }, name: "x")        // もともと無い → 何も変わらない
        m.setAudioFx({ _ = AudioFxEditing.setPan(&$0, 0) }, name: "x")
        m.setAudioFx({ _ = AudioFxEditing.resetEQ(&$0) }, name: "x")
        XCTAssertFalse(u.canUndo)
        m.setAudioFx({ _ = AudioFxEditing.setCompressorEnabled(&$0, true) }, name: "コンプレッサーの切り替え")
        XCTAssertEqual(u.undoActionName, "コンプレッサーの切り替え")
        XCTAssertEqual(m.clip("m")?.audioFx?.compressor?.isActive, true)
        m.setAudioFx({ _ = AudioFxEditing.setReverbSize(&$0, .hall) }, name: ProjectModel.reverbUndoName)
        m.setAudioFx({ _ = AudioFxEditing.setNormalizeEnabled(&$0, true) }, name: "ノーマライズの切り替え")
        XCTAssertEqual(undoSteps(m), 3)
        let n = undoSteps(m)
        m.setAudioFx({ _ = AudioFxEditing.setCompressorEnabled(&$0, true) }, name: "x")           // 同じ状態
        m.setAudioFx({ _ = AudioFxEditing.setReverbSize(&$0, .hall) }, name: "x")
        XCTAssertEqual(undoSteps(m), n)
        // 元に戻すと順にたどる
        u.undo(); XCTAssertNil(m.clip("m")?.audioFx?.normalize)
        u.undo(); XCTAssertNil(m.clip("m")?.audioFx?.reverb)
        u.undo(); XCTAssertNil(m.clip("m")?.audioFx)
    }

    func testSliderDragIsOneUndoStep() {
        let m = makeModel()
        m.selectedClipId = "m"
        let u = m.effectiveUndoManager
        m.beginGesture()
        for v in stride(from: 0.0, through: 9.0, by: 1.5) { m.liveAudioFx({ _ = AudioFxEditing.setEQ(&$0, band: .mid, db: v) }, name: ProjectModel.eqUndoName) }
        m.commitGesture(ProjectModel.eqUndoName)
        XCTAssertEqual(m.clip("m")?.audioFx?.eq?.midDb, 9)
        XCTAssertEqual(undoSteps(m), 1)
        XCTAssertEqual(u.undoActionName, ProjectModel.eqUndoName)
        u.undo()
        XCTAssertNil(m.clip("m")?.audioFx)
        // 動かして元に戻したドラッグは、何も登録しない
        m.beginGesture()
        m.liveAudioFx({ _ = AudioFxEditing.setPan(&$0, 0.6) }, name: ProjectModel.panUndoName)
        m.liveAudioFx({ _ = AudioFxEditing.setPan(&$0, 0) }, name: ProjectModel.panUndoName)
        m.commitGesture(ProjectModel.panUndoName)
        XCTAssertEqual(undoSteps(m), 0)
    }

    func testVolumeKeyframeFromInspectorPath() {
        let m = makeModel()
        m.selectedClipId = "m"
        m.playback.seek(to: 1)
        XCTAssertEqual(m.keyState("volume", of: m.clip("m")!), .none)
        XCTAssertTrue(m.toggleKeyframe("volume"))                      // ◇ → ◆
        XCTAssertEqual(m.clip("m")?.keyframes["volume"]?.count, 1)
        m.playback.seek(to: 4)
        m.setKeyed("volume", 0.25)
        XCTAssertEqual(m.clip("m")?.keyframes["volume"]?.map(\.t), [1, 4])
        XCTAssertEqual(m.clip("m")?.keyframes["volume"]?.map(\.v), [1, 0.25])
        XCTAssertEqual(m.animatedValue("volume", of: m.clip("m")!), 0.25, accuracy: 1e-9)
        m.playback.seek(to: 2.5)
        XCTAssertEqual(m.animatedValue("volume", of: m.clip("m")!), 0.625, accuracy: 1e-6)
        XCTAssertEqual(undoSteps(m), 2)
        // 動画・ボイスにも付く / 画像には付かない
        m.selectedClipId = "v"; m.playback.seek(to: 3)
        XCTAssertTrue(m.toggleKeyframe("volume"))
        m.selectedClipId = "k"; m.playback.seek(to: 11)
        XCTAssertTrue(m.toggleKeyframe("volume"))
        m.selectedClipId = "a"; m.playback.seek(to: 1)
        XCTAssertFalse(m.toggleKeyframe("volume"))
    }

    // MARK: メニュー

    private func state(_ configure: (inout MenuState) -> Void = { _ in }) -> MenuState {
        var s = MenuState()
        s.hasDocument = true; s.canExport = true
        s.resolutionKey = "1920x1080"; s.codec = "h264"; s.bg = "#000000"
        configure(&s)
        return s
    }

    func testMenuSpec() {
        let on = state { $0.canAudioFx = true; $0.hasAudioFx = true }
        let items = AppMenuSpec.audioItems(on)
        XCTAssertEqual(items.map(\.title), ["ノーマライズ（ピーク −1 dB）", "音量を上げる（+3 dB）", "音量を下げる（−3 dB）", "ボイス向けプリセット（EQ + コンプレッサー）", "音声エフェクトをすべて外す"])
        XCTAssertEqual(items.map(\.command), [.audioNormalize, .audioVolumeUp, .audioVolumeDown, .audioVoicePreset, .audioClear])
        XCTAssertTrue(items.allSatisfy { $0.enabled && $0.shortcut == nil })
        XCTAssertEqual(AppMenuSpec.audioItems(state()).map(\.enabled), [false, false, false, false, false])
        XCTAssertEqual(AppMenuSpec.audioItems(state { $0.canAudioFx = true }).map(\.enabled), [true, true, true, true, false], "外すものが無いときは外せない")
        XCTAssertTrue(AppMenuSpec.audioItems(state { $0.canAudioFx = true; $0.hasAudioFx = true; $0.isLocked = true }).allSatisfy { !$0.enabled })
        // 全項目の表に入っていて、ショートカットが衝突しない
        let all = AppMenuSpec.all(on)
        XCTAssertTrue(all.contains { $0.command == .audioVoicePreset })
        let used = all.compactMap(\.shortcut)
        XCTAssertEqual(used.count, Set(used).count)
    }

    func testMenuStateFromModelAndPerform() {
        let m = makeModel()
        m.selectedClipId = "a"
        XCTAssertFalse(MenuState(model: m).canAudioFx)
        AppMenu.perform(.audioNormalize, model: m)
        XCTAssertNil(m.clip("a")?.audioFx)
        m.selectedClipId = "m"
        var s = MenuState(model: m)
        XCTAssertTrue(s.canAudioFx); XCTAssertFalse(s.hasAudioFx)
        let u = m.effectiveUndoManager
        AppMenu.perform(.audioNormalize, model: m)
        XCTAssertEqual(m.clip("m")?.audioFx?.normalize, AudioFx.Normalize(targetDb: -1, mode: .peak))
        XCTAssertEqual(u.undoActionName, "ノーマライズ（ピーク −1 dB）")
        AppMenu.perform(.audioNormalize, model: m)                    // 同じ設定 → 何も増えない
        XCTAssertEqual(undoSteps(m), 1)
        AppMenu.perform(.audioVolumeUp, model: m)
        XCTAssertEqual(m.clip("m")!.volumeOrDefault, pow(10, 3.0 / 20), accuracy: 0.001)
        XCTAssertEqual(u.undoActionName, "音量を上げる")
        AppMenu.perform(.audioVolumeDown, model: m); AppMenu.perform(.audioVolumeDown, model: m)
        XCTAssertEqual(m.clip("m")!.volumeOrDefault, pow(10, -3.0 / 20), accuracy: 0.002)
        AppMenu.perform(.audioVoicePreset, model: m)
        XCTAssertNotNil(m.clip("m")?.audioFx?.eq); XCTAssertNotNil(m.clip("m")?.audioFx?.compressor)
        XCTAssertEqual(u.undoActionName, "ボイス向けプリセット")
        s = MenuState(model: m)
        XCTAssertTrue(s.hasAudioFx)
        AppMenu.perform(.audioClear, model: m)
        XCTAssertNil(m.clip("m")?.audioFx)
        XCTAssertEqual(u.undoActionName, "音声エフェクトをすべて外す")
        XCTAssertFalse(MenuState(model: m).hasAudioFx)
        u.undo()
        XCTAssertNotNil(m.clip("m")?.audioFx?.eq)                       // 1 回の Undo で戻る
        // 動画・ボイスにも効く / フリーズフレームには効かない
        m.selectedClipId = "k"; AppMenu.perform(.audioVoicePreset, model: m)
        XCTAssertNotNil(m.clip("k")?.audioFx)
        m.selectedClipId = "v"; AppMenu.perform(.audioNormalize, model: m)
        XCTAssertNotNil(m.clip("v")?.audioFx?.normalize)
    }

    // MARK: 再生用ミックスの鍵

    /// この機能の前の鍵の作り方(フェード・速度までの式)。
    private func legacyKey(_ project: Project, fileDate: (String) -> Date?) -> String {
        var lines: [String] = []
        for (i, tr) in project.tracks.enumerated() {
            var items: [String] = []
            for c in tr.clips where c.type == .audio || c.type == .voice || c.type == .video {
                guard let src = c.src, !src.isEmpty, c.duration > 0, !c.isFreeze else { continue }
                let date = fileDate(src).map { String($0.timeIntervalSinceReferenceDate) } ?? "-"
                let fade = c.hasAudioFade ? "|fade=\(c.fadeInOrDefault),\(c.fadeOutOrDefault),\(c.fadeCurve ?? "linear")" : ""
                var remap = ""
                if c.hasAudioRemap {
                    remap = "|rate=\(c.effectiveSpeed),rev=\(c.effectiveReverse ? 1 : 0)"
                    if c.effectiveSpeed != 1 && !c.keepPitchOrDefault { remap += ",pitch=0" }
                }
                items.append("\(c.type.rawValue)|\(src)|\(c.start)|\(c.duration)|\(c.offset)|\(c.volumeOrDefault)|\(date)\(fade)\(remap)")
            }
            if items.isEmpty { continue }
            items.sort()
            lines.append("T\(i)|muted=\(tr.isMuted ? 1 : 0)")
            lines.append(contentsOf: items)
        }
        return SHA256.hash(data: Data(lines.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func testAudioCacheKeyStaysTheSameWithoutFxAndChangesWithFx() {
        let m = makeModel()
        var p = m.project
        p.tracks[0].clips[1].fadeIn = 0.5
        p.tracks[1].clips[0].speed = 2
        let dates: (String) -> Date? = { _ in Date(timeIntervalSinceReferenceDate: 1000) }
        let k0 = AudioCacheKey.make(for: p, fileDate: dates)
        XCTAssertEqual(k0.value, legacyKey(p, fileDate: dates), "エフェクトの無いプロジェクトの鍵は従来のまま")
        func key(_ f: (inout Project) -> Void) -> AudioCacheKey { var q = p; f(&q); return AudioCacheKey.make(for: q, fileDate: dates) }
        // 音に効かないもの: 同じ鍵
        XCTAssertEqual(key { $0.tracks[0].clips[1].audioFx = AudioFx() }, k0)
        XCTAssertEqual(key { $0.tracks[0].clips[1].audioFx = AudioFx(compressor: AudioFx.Compressor(enabled: false)) }, k0)
        XCTAssertEqual(key { $0.tracks[0].clips[1].audioFx = AudioFx(eq: AudioFx.EQ(), reverb: AudioFx.Reverb(mix: 0)) }, k0)
        XCTAssertEqual(key { $0.tracks[0].clips[1].pan = 0 }, k0)
        XCTAssertEqual(key { $0.tracks[0].clips[0].audioFx = AudioFx(eq: AudioFx.EQ(low: 3)) }, k0, "画像に付いたエフェクトは音に関係しない")
        // 音に効くもの: 鍵が変わる
        let eq = key { $0.tracks[0].clips[1].audioFx = AudioFx(eq: AudioFx.EQ(mid: 3)) }
        XCTAssertNotEqual(eq, k0)
        XCTAssertNotEqual(key { $0.tracks[0].clips[1].audioFx = AudioFx(eq: AudioFx.EQ(mid: 4)) }, eq)
        XCTAssertNotEqual(key { $0.tracks[0].clips[1].audioFx = AudioFx(compressor: AudioFx.Compressor()) }, k0)
        XCTAssertNotEqual(key { $0.tracks[0].clips[1].audioFx = AudioFx(reverb: AudioFx.Reverb(mix: 0.2, size: .hall)) }, k0)
        XCTAssertNotEqual(key { $0.tracks[0].clips[1].audioFx = AudioFx(normalize: AudioFx.Normalize()) }, k0)
        XCTAssertNotEqual(key { $0.tracks[0].clips[1].pan = 0.3 }, k0)
        let vk = key { $0.tracks[0].clips[1].keyframes["volume"] = [Keyframe(t: 0, v: 0.5), Keyframe(t: 1, v: 1)] }
        XCTAssertNotEqual(vk, k0)
        XCTAssertNotEqual(key { $0.tracks[0].clips[1].keyframes["volume"] = [Keyframe(t: 0, v: 0.5), Keyframe(t: 1, v: 0.9)] }, vk)
        XCTAssertEqual(key { $0.tracks[0].clips[1].keyframes["x"] = [Keyframe(t: 0, v: 0.5)] }, k0, "音量以外のキーは音に関係しない")
    }

    // MARK: 画像(見て確かめる)

    private func writePNG(_ view: NSView, _ name: String) throws {
        view.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let dir = URL(fileURLWithPath: Self.snapshotDir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try png.write(to: dir.appendingPathComponent(name))
        XCTAssertGreaterThan(png.count, 3000)
    }

    func testSnapshotInspectorAudioSection() throws {
        let m = makeModel()
        m.selectedClipId = "m"
        m.playback.seek(to: 2)
        m.toggleKeyframe("volume"); m.playback.seek(to: 4); m.setKeyed("volume", 0.4)
        m.setAudioFade(0.5, edge: .in)
        m.setAudioFx({ c in
            AudioFxEditing.setEQ(&c, band: .low, db: 3); AudioFxEditing.setEQ(&c, band: .mid, db: -2.5); AudioFxEditing.setEQ(&c, band: .high, db: 4.5)
            AudioFxEditing.setCompressor(&c, .threshold, -24); AudioFxEditing.setCompressor(&c, .ratio, 4)
            AudioFxEditing.setReverbEnabled(&c, true); AudioFxEditing.setReverbMix(&c, 0.3); AudioFxEditing.setReverbSize(&c, .large)
            AudioFxEditing.setNormalizeEnabled(&c, true); AudioFxEditing.setNormalizeMode(&c, .loudness); AudioFxEditing.setNormalizeTarget(&c, -14)
            AudioFxEditing.setPan(&c, -0.35)
        }, name: "snapshot")
        ClipInspector_expand(true)
        defer { ClipInspector_expand(false) }
        let host = NSHostingView(rootView: InspectorView(model: m, speakers: SpeakerCatalog()).frame(width: 300, height: 1500).background(Color(red: 0.14, green: 0.15, blue: 0.17)).preferredColorScheme(.dark))
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 1500)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        try writePNG(host, "inspector-audio-expanded.png")
        // 既定(エフェクトなしの動画)
        m.selectedClipId = "v"
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        try writePNG(host, "inspector-video-default.png")
    }

    private func ClipInspector_expand(_ on: Bool) { ClipInspector.expandAudioFx = on }
}
