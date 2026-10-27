import XCTest
import SwiftUI
import AppKit
import MovieCutCore
@testable import MovieCut

/// 速度・逆再生・フリーズフレーム: モデルの操作(1 操作 = 1 Undo)、メニューの項目表、音声キャッシュの鍵、インスペクタとタイムラインの見た目。
@MainActor
final class SpeedAppTests: XCTestCase {
    static let snapshotDir = (ProcessInfo.processInfo.environment["MC_SNAPSHOT_OUT_DIR_SPEED"]
        ?? "/private/tmp/claude-501/-Users-USER------------/07529bfa-5715-4444-bf9c-c37229b6ab4d/scratchpad/speed")

    private func clip(_ id: String, _ type: ClipType, start: Double, dur: Double, offset: Double = 0) -> Clip {
        var c = Clip(); c.id = id; c.type = type; c.start = start; c.duration = dur; c.offset = offset
        if type == .image || type == .video { c.src = "/tmp/none.png" }
        if type == .video { c.src = "/tmp/clip-sample.mp4"; c.srcDuration = 60 }
        if type == .audio { c.src = "/tmp/none.wav"; c.srcDuration = 60 }
        if type == .text { c.text = "テキスト"; c.fontSize = 80 }
        return c
    }

    private func makeModel() -> ProjectModel {
        var p = Project.new()
        p.fps = 60
        p.tracks[0].clips = [clip("a", .image, start: 0, dur: 4), clip("m", .audio, start: 14, dur: 6, offset: 1)]
        p.tracks[1].clips = [clip("v", .video, start: 2, dur: 6, offset: 1), clip("w", .video, start: 12, dur: 3)]
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

    // MARK: モデル

    func testSpeedReverseKeepPitchAreOneUndoStepEach() {
        let m = makeModel()
        let u = m.effectiveUndoManager
        m.selectedClipId = "v"
        XCTAssertTrue(m.setSpeed(2))
        XCTAssertEqual(u.undoActionName, "速度の変更")
        XCTAssertEqual(m.clip("v")?.speed, 2); XCTAssertEqual(m.clip("v")!.duration, 3, accuracy: 1e-9)
        XCTAssertTrue(m.setReverse(true))
        XCTAssertEqual(u.undoActionName, "逆再生にする")
        XCTAssertTrue(m.setKeepPitch(false))
        XCTAssertEqual(m.clip("v")?.keepPitch, false)
        XCTAssertEqual(undoSteps(m), 3)
        u.undo(); XCTAssertNil(m.clip("v")?.keepPitch)
        u.undo(); XCTAssertNil(m.clip("v")?.reverse)
        u.undo(); XCTAssertNil(m.clip("v")?.speed); XCTAssertEqual(m.clip("v")!.duration, 6, accuracy: 1e-9)
        XCTAssertFalse(u.canUndo)
    }

    func testNoOpEditsRegisterNothing() {
        let m = makeModel()
        m.selectedClipId = "v"
        XCTAssertFalse(m.setSpeed(1), "もとから等倍")
        XCTAssertFalse(m.setReverse(false))
        XCTAssertFalse(m.setKeepPitch(true))
        XCTAssertTrue(m.toggleReverseSelected())            // 切り替えは変わるので true。戻して、登録が 1 つだけなのを確かめる
        XCTAssertEqual(undoSteps(m), 1)
        m.effectiveUndoManager.undo()
        XCTAssertFalse(m.effectiveUndoManager.canUndo)
        m.selectedClipId = "a"                                 // 画像は対象外
        XCTAssertFalse(m.setSpeed(2)); XCTAssertFalse(m.setReverse(true)); XCTAssertFalse(m.toggleReverseSelected())
        XCTAssertFalse(m.effectiveUndoManager.canUndo)
        m.selectedClipId = nil
        XCTAssertFalse(m.setSpeed(2))
        m.selectedClipId = "v"
        XCTAssertTrue(m.setSpeed(2)); let n = undoSteps(m)
        XCTAssertFalse(m.setSpeed(2)); XCTAssertEqual(undoSteps(m), n)
    }

    func testSliderDragIsOneUndoStepAndDerivesFromDragStart() {
        let m = makeModel()
        m.selectedClipId = "v"
        m.beginGesture()
        for v in [1.25, 1.5, 2.0, 3.0, 2.0] { m.liveSpeed(v, clipId: "v") }
        XCTAssertEqual(m.clip("v")?.speed, 2)
        XCTAssertEqual(m.clip("v")!.duration, 3, accuracy: 1e-6, "ドラッグ開始時から毎回計算するので誤差が積もらない")
        m.commitGesture(ProjectModel.speedUndoName)
        XCTAssertEqual(undoSteps(m), 1)
        // 元の速度に戻して離したら何も登録しない
        let m2 = makeModel(); m2.selectedClipId = "v"
        m2.beginGesture(); m2.liveSpeed(2, clipId: "v"); m2.liveSpeed(1, clipId: "v"); m2.commitGesture(ProjectModel.speedUndoName)
        XCTAssertFalse(m2.effectiveUndoManager.canUndo)
        XCTAssertEqual(m2.clip("v")!.duration, 6)
        XCTAssertNil(m2.clip("v")?.speed)
    }

    func testSteppedSpeedCoalescesIntoOneUndo() async throws {
        let m = makeModel()
        m.selectedClipId = "v"
        m.coalescedSpeed(1.5); m.coalescedSpeed(1.75); m.coalescedSpeed(2)
        m.flushCoalesced()
        XCTAssertEqual(m.clip("v")?.speed, 2)
        XCTAssertEqual(undoSteps(m), 1)
    }

    func testSpeedClampsToNextClipOnTheSameLayer() {
        let m = makeModel()
        m.selectedClipId = "v"               // 2〜8。次は 12 から
        XCTAssertTrue(m.setSpeed(0.25))       // 6 ÷ 0.25 = 24 秒だが、12 の手前(10 秒)まで
        XCTAssertEqual(m.clip("v")!.duration, 10, accuracy: 1e-9)
        XCTAssertEqual(m.clip("w")!.start, 12)
    }

    func testFreezeFrameThroughModel() {
        let m = makeModel()
        m.selectedClipId = "v"
        m.currentTime = 1
        XCTAssertFalse(m.canFreezeFrame); XCTAssertFalse(m.freezeFrameSelected(), "クリップの外")
        m.currentTime = 4
        XCTAssertTrue(m.canFreezeFrame)
        XCTAssertTrue(m.freezeFrameSelected())
        XCTAssertEqual(m.effectiveUndoManager.undoActionName, "フリーズフレーム")
        let freeze = m.project.allClips.filter(\.isFreeze)
        XCTAssertEqual(freeze.count, 1)
        XCTAssertEqual(m.selectedClipId, freeze[0].id)
        XCTAssertEqual(freeze[0].offset, 1 + 2, accuracy: 1e-9)
        XCTAssertEqual(m.project.tracks[1].clips.count, 4)
        XCTAssertEqual(m.clip("w")!.start, 14, "後ろのクリップは 2 秒ずれる")
        XCTAssertEqual(undoSteps(m), 1)
        m.effectiveUndoManager.undo()
        XCTAssertEqual(m.project.tracks[1].clips.count, 2); XCTAssertEqual(m.clip("w")!.start, 12)
        // 静止画そのものには速度の操作はできない
        m.effectiveUndoManager.redo()
        XCTAssertFalse(m.setSpeed(2, clipId: freeze[0].id))
    }

    func testSplitAndDuplicateThroughModelKeepSpeed() {
        let m = makeModel()
        m.selectedClipId = "v"
        m.setSpeed(2); m.setReverse(true)
        m.currentTime = 3.5                          // クリップは 2〜5(3 秒)
        XCTAssertTrue(m.splitSelected())
        let parts = m.project.tracks[1].clips.filter { $0.type == .video && $0.start < 10 }
        XCTAssertEqual(parts.count, 2)
        XCTAssertTrue(parts.allSatisfy { $0.speed == 2 && $0.reverse == true })
        // 左(先に出る側)が素材の終わり側
        XCTAssertGreaterThan(parts[0].offset, parts[1].offset)
        XCTAssertEqual(parts[1].offset, 1)
        XCTAssertEqual(parts[0].offset, 1 + (3 - 1.5) * 2, accuracy: 1e-9)
    }

    // MARK: メニュー

    private func state(_ f: (inout MenuState) -> Void = { _ in }) -> MenuState {
        var s = MenuState(); s.hasDocument = true; s.canExport = true
        s.resolutionKey = "1920x1080"; s.codec = "h264"; s.bg = "#000000"
        f(&s); return s
    }

    func testMenuSpec() {
        let s = state { $0.canSpeed = true; $0.speedValue = 2; $0.isReversed = true; $0.canFreezeFrame = true }
        let items = AppMenuSpec.speedItems(s)
        XCTAssertEqual(items.map(\.title), ["0.25倍", "0.5倍", "通常（1倍）", "2倍", "4倍", "逆再生にする"])
        XCTAssertEqual(items.map(\.command), [.speed(0.25), .speed(0.5), .speed(1), .speed(2), .speed(4), .toggleReverse])
        XCTAssertEqual(items.filter { $0.checked == true }.map(\.title), ["2倍", "逆再生にする"])
        XCTAssertTrue(items.allSatisfy { $0.shortcut == nil && $0.enabled })
        XCTAssertEqual(AppMenuSpec.freezeFrameItem(s).title, "フリーズフレーム（静止画にする）")
        XCTAssertTrue(AppMenuSpec.freezeFrameItem(s).enabled)
        // 無効の条件
        let none = state()
        XCTAssertTrue(AppMenuSpec.speedItems(none).allSatisfy { !$0.enabled && $0.checked == nil })
        XCTAssertFalse(AppMenuSpec.freezeFrameItem(none).enabled)
        XCTAssertFalse(AppMenuSpec.freezeFrameItem(state { $0.canSpeed = true }).enabled, "再生位置がクリップの外")
        let locked = state { $0.isLocked = true; $0.canSpeed = true; $0.canFreezeFrame = true }
        XCTAssertTrue((AppMenuSpec.speedItems(locked) + [AppMenuSpec.freezeFrameItem(locked)]).allSatisfy { !$0.enabled })
        // 通常の速度のとき「通常」にチェック、逆再生のチェックは外れる
        let normal = state { $0.canSpeed = true; $0.speedValue = 1 }
        XCTAssertEqual(AppMenuSpec.speedItems(normal).filter { $0.checked == true }.map(\.title), ["通常（1倍）"])
        // ショートカットは増えない(重複なし・修飾キーなしなし)
        let all = AppMenuSpec.all(s)
        let keys = all.compactMap(\.shortcut)
        XCTAssertEqual(keys.count, Set(keys).count)
        XCTAssertTrue(keys.allSatisfy { !$0.modifiers.isEmpty })
        XCTAssertTrue(all.contains { $0.command == .freezeFrame }); XCTAssertTrue(all.contains { $0.command == .speed(0.25) })
    }

    func testMenuStateFollowsSelection() {
        let m = makeModel()
        XCTAssertFalse(MenuState(model: m).canSpeed)
        m.selectedClipId = "a"
        XCTAssertFalse(MenuState(model: m).canSpeed); XCTAssertFalse(MenuState(model: m).canFreezeFrame)
        m.selectedClipId = "v"
        m.currentTime = 0
        var s = MenuState(model: m)
        XCTAssertTrue(s.canSpeed); XCTAssertEqual(s.speedValue, 1); XCTAssertFalse(s.isReversed); XCTAssertFalse(s.canFreezeFrame)
        m.currentTime = 3
        m.setSpeed(0.5); m.setReverse(true)
        s = MenuState(model: m)
        XCTAssertEqual(s.speedValue, 0.5); XCTAssertTrue(s.isReversed); XCTAssertTrue(s.canFreezeFrame)
        m.selectedClipId = "m"
        s = MenuState(model: m)
        XCTAssertTrue(s.canSpeed); XCTAssertFalse(s.canFreezeFrame, "音声はフリーズできない")
    }

    func testPerformThroughSpecTable() {
        let m = makeModel()
        m.selectedClipId = "v"
        AppMenu.perform(.speed(4), model: m)
        XCTAssertEqual(m.clip("v")?.speed, 4)
        AppMenu.perform(.toggleReverse, model: m)
        XCTAssertEqual(m.clip("v")?.reverse, true)
        AppMenu.perform(.toggleReverse, model: m)
        XCTAssertNil(m.clip("v")?.reverse)
        AppMenu.perform(.speed(1), model: m)
        XCTAssertNil(m.clip("v")?.speed)
        m.currentTime = 4
        AppMenu.perform(.freezeFrame, model: m)
        XCTAssertEqual(m.project.allClips.filter(\.isFreeze).count, 1)
    }

    // MARK: 音声キャッシュの鍵

    func testAudioCacheKeyAddsSpeedFieldsOnlyWhenNonDefault() {
        let dates: (String) -> Date? = { _ in Date(timeIntervalSinceReferenceDate: 1000) }
        var base = Project.new(); base.tracks[0].clips = [clip("v", .video, start: 0, dur: 4)]
        let k0 = AudioCacheKey.make(for: base, fileDate: dates)
        func key(_ f: (inout Clip) -> Void) -> AudioCacheKey { var q = base; f(&q.tracks[0].clips[0]); return AudioCacheKey.make(for: q, fileDate: dates) }
        XCTAssertEqual(key { $0.speed = nil }, k0)
        XCTAssertEqual(key { $0.speed = 1; $0.reverse = false; $0.keepPitch = true }, k0, "既定と同じ値は鍵に出ない")
        XCTAssertNotEqual(key { $0.speed = 2 }, k0)
        XCTAssertNotEqual(key { $0.reverse = true }, k0)
        XCTAssertNotEqual(key { $0.speed = 2 }, key { $0.speed = 0.5 })
        XCTAssertNotEqual(key { $0.speed = 2 }, key { $0.speed = 2; $0.keepPitch = false })
        XCTAssertEqual(key { $0.keepPitch = false }, k0, "速度 1 なら音程は関係ない")
        // 画像に付いた速度は無視される
        var img = base; img.tracks[0].clips = [clip("a", .image, start: 0, dur: 4)]
        var img2 = img; img2.tracks[0].clips[0].speed = 3
        XCTAssertEqual(AudioCacheKey.make(for: img, fileDate: dates), AudioCacheKey.make(for: img2, fileDate: dates))
        // 静止画のクリップは無音: 鍵に影響しない
        var fr = base; var f = clip("f", .video, start: 4, dur: 2); f.freeze = true; fr.tracks[0].clips.append(f)
        XCTAssertEqual(AudioCacheKey.make(for: fr, fileDate: dates), k0)
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

    private func inspectorHost(_ m: ProjectModel, height: CGFloat = 1200) -> NSHostingView<AnyView> {
        let host = NSHostingView(rootView: AnyView(InspectorView(model: m, speakers: SpeakerCatalog()).frame(width: 300, height: height).background(Color(red: 0.14, green: 0.15, blue: 0.17)).preferredColorScheme(.dark)))
        host.frame = NSRect(x: 0, y: 0, width: 300, height: height)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        return host
    }

    func testSnapshotInspector() throws {
        let m = makeModel()
        m.selectedClipId = "v"
        m.setSpeed(2); m.setReverse(true)
        let host = inspectorHost(m)
        try writePNG(host, "inspector-video-speed2-reverse.png")
        m.setKeepPitch(false)
        m.setSpeed(0.37)
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        try writePNG(host, "inspector-video-custom-nopitch.png")
        m.selectedClipId = "m"                                       // 音声
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        try writePNG(host, "inspector-audio.png")
        m.selectedClipId = "w"; m.currentTime = 13
        m.freezeFrameSelected()                                      // 静止画が選ばれる
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        try writePNG(host, "inspector-freeze.png")
        m.selectedClipId = "a"                                       // 画像(速度欄なし)
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    }

    func testInspectorSpeedSectionAppliesToVideoAndAudioOnly() throws {
        let m = makeModel()
        // 速度の欄は Clip.supportsSpeed(動画・音声)のときだけ出す。見た目は画像で確かめる(inspector-*.png)
        for (id, expect) in [("v", true), ("m", true), ("a", false)] {
            XCTAssertEqual(Clip.supportsSpeed(m.clip(id)!.type), expect, id)
        }
        m.selectedClipId = "a"
        try writePNG(inspectorHost(m, height: 900), "inspector-image-no-speed.png")
    }

    func testSnapshotTimelineBadges() throws {
        let m = makeModel()
        m.selectedClipId = "v"
        m.setSpeed(2)
        m.selectedClipId = "w"; m.setReverse(true); m.setSpeed(0.5)
        m.selectedClipId = "m"; m.setSpeed(4)
        m.selectedClipId = "v"; m.currentTime = 3
        m.freezeFrameSelected()
        m.selectedClipId = nil
        let host = NSHostingView(rootView: ContentView(model: m, fileURL: nil))
        host.frame = NSRect(x: 0, y: 0, width: 1400, height: 900)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        host.layoutSubtreeIfNeeded()
        try writePNG(host, "window-timeline-badges.png")
        // 同じ状態の印の文字
        XCTAssertEqual(m.project.allClips.compactMap { ClipTiming.badge(for: $0) }.sorted(), ["×2", "×2", "×4", "◀×0.5", "静止"].sorted())
    }
}
