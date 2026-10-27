import XCTest
import SwiftUI
import AppKit
import MovieCutCore
@testable import MovieCut

/// トランジション / 音声フェード: モデルの操作(Undo)、メニュー、インスペクタ、タイムラインの三角。
@MainActor
final class TransitionAppTests: XCTestCase {
    static let snapshotDir = (ProcessInfo.processInfo.environment["MC_SNAPSHOT_OUT_DIR_TRANSITIONS"]
        ?? "/private/tmp/claude-501/-Users-USER------------/07529bfa-5715-4444-bf9c-c37229b6ab4d/scratchpad/transitions")

    private func clip(_ id: String, _ type: ClipType, start: Double, dur: Double) -> Clip {
        var c = Clip(); c.id = id; c.type = type; c.start = start; c.duration = dur
        if type == .image || type == .video { c.src = "/tmp/none.png" }
        if type == .audio { c.src = "/tmp/none.wav"; c.srcDuration = dur }
        if type == .text { c.text = "テキスト"; c.fontSize = 80 }
        return c
    }

    /// a(0〜4 画像・レイヤー1)、v(2〜8 動画・レイヤー2)、b(10〜12 文字)、m(14〜20 音声)
    private func makeModel() -> ProjectModel {
        var p = Project.new()
        p.fps = 60
        p.tracks[0].clips = [clip("a", .image, start: 0, dur: 4), clip("b", .text, start: 10, dur: 2), clip("m", .audio, start: 14, dur: 6)]
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

    func testSetKindDurationEaseAreOneUndoStepEach() {
        let m = makeModel()
        let u = m.effectiveUndoManager
        m.selectedClipId = "a"
        m.setTransitionKind(.zoom, edge: .in)
        XCTAssertEqual(m.clip("a")?.transitionIn, MovieCutCore.Transition(.zoom, duration: 0.5))
        XCTAssertEqual(u.undoActionName, "開始トランジションの変更")
        m.setTransitionDuration(1.5, edge: .in)
        XCTAssertEqual(m.clip("a")?.transitionIn?.duration, 1.5)
        m.setTransitionEase(.linear, edge: .in)
        XCTAssertEqual(m.clip("a")?.transitionIn?.ease, .linear)
        m.setTransitionKind(.wipeClock, edge: .out)
        XCTAssertEqual(m.clip("a")?.transitionOut?.known, .wipeClock)
        XCTAssertEqual(undoSteps(m), 4)
        m.setTransitionKind(nil, edge: .out)
        XCTAssertNil(m.clip("a")?.transitionOut)
        XCTAssertEqual(u.undoActionName, "終了トランジションを外す")
        // 元に戻すと途中の状態を順にたどる
        u.undo(); XCTAssertEqual(m.clip("a")?.transitionOut?.known, .wipeClock)
        u.undo(); XCTAssertNil(m.clip("a")?.transitionOut); XCTAssertEqual(m.clip("a")?.transitionIn?.ease, .linear)
        u.undo(); XCTAssertEqual(m.clip("a")?.transitionIn?.ease, .easeInOut)
        u.undo(); u.undo()
        XCTAssertNil(m.clip("a")?.transitionIn)
    }

    func testNoOpEditsRegisterNothing() {
        let m = makeModel()
        m.selectedClipId = "a"
        m.setTransitionKind(nil, edge: .in)                      // もともと無い
        m.setTransitionDuration(2, edge: .in)                    // 無い側の長さ
        m.setTransitionEase(.linear, edge: .out)
        m.setAudioFade(1, edge: .in)                             // 画像には音が無い
        XCTAssertFalse(m.effectiveUndoManager.canUndo)
        m.setTransitionKind(.fade, edge: .in)
        let n = undoSteps(m)
        m.setTransitionKind(.fade, edge: .in)                    // 同じ種類
        m.setTransitionDuration(0.5, edge: .in)                  // 同じ長さ
        m.setTransitionEase(.easeInOut, edge: .in)
        XCTAssertEqual(undoSteps(m), n)
        m.selectedClipId = "m"
        m.setTransitionKind(.fade, edge: .in)                    // 音声には映像のトランジションは付かない
        XCTAssertNil(m.clip("m")?.transitionIn)
    }

    func testLockedModelRefusesEdits() {
        let m = makeModel()
        m.selectedClipId = "a"
        m.busyMessage = "処理中"
        m.setTransitionKind(.fade, edge: .in)
        XCTAssertNil(m.clip("a")?.transitionIn)
        XCTAssertFalse(m.fadeBothSelected()); XCTAssertFalse(m.crossfadeSelected()); XCTAssertFalse(m.fadeInOutSelected())
    }

    func testAudioFadeAndLinkedToggleFollowTransitions() {
        let m = makeModel()
        m.selectedClipId = "v"
        m.setTransitionKind(.fade, edge: .in)
        m.setTransitionDuration(1, edge: .in)
        m.setAudioLinked(true)
        XCTAssertEqual(m.clip("v")?.fadeIn, 1); XCTAssertNil(m.clip("v")?.fadeOut)
        XCTAssertEqual(m.effectiveUndoManager.undoActionName, "音声フェードの連動の切り替え")
        let steps = undoSteps(m)
        m.setTransitionDuration(2, edge: .in)                    // 連動中: 音声も合う(1 回の Undo)
        XCTAssertEqual(m.clip("v")?.fadeIn, 2)
        XCTAssertEqual(undoSteps(m), steps + 1)
        m.effectiveUndoManager.undo()
        XCTAssertEqual(m.clip("v")?.fadeIn, 1); XCTAssertEqual(m.clip("v")?.transitionIn?.duration, 1)
        m.setAudioLinked(false)
        XCTAssertNil(m.clip("v")?.fadeIn)
        m.selectedClipId = "m"
        m.setAudioFade(0.7, edge: .out)
        XCTAssertEqual(m.clip("m")?.fadeOut, 0.7)
        m.setFadeCurve(equalPower: true)
        XCTAssertEqual(m.clip("m")?.fadeCurve, "equalPower")
        m.setAudioFade(0, edge: .out)
        XCTAssertNil(m.clip("m")?.fadeOut); XCTAssertNil(m.clip("m")?.fadeCurve)
    }

    func testMenuActionsAreOneUndoStepEach() {
        let m = makeModel()
        m.selectedClipId = "v"
        XCTAssertTrue(m.fadeBothSelected())
        XCTAssertEqual(m.clip("v")?.transitionIn?.known, .fade); XCTAssertEqual(m.clip("v")?.transitionOut?.known, .fade)
        XCTAssertEqual(undoSteps(m), 1)
        XCTAssertFalse(m.fadeBothSelected())
        XCTAssertTrue(m.clearTransitionsSelected())
        XCTAssertFalse(m.clip("v")!.hasTransition)
        XCTAssertFalse(m.clearTransitionsSelected())
        XCTAssertTrue(m.fadeInOutSelected())
        XCTAssertEqual(m.clip("v")?.fadeIn, 0.5); XCTAssertEqual(m.clip("v")?.fadeOut, 0.5)
        XCTAssertEqual(m.effectiveUndoManager.undoActionName, "フェードイン・アウトを付ける")
        XCTAssertEqual(undoSteps(m), 3)
    }

    func testCrossfadeSetsFadeInAndExplainsWhenThereIsNoOverlap() {
        let m = makeModel()
        m.selectedClipId = "v"                                    // 2〜8(レイヤー2)が a(0〜4・レイヤー1)の上に 2 秒重なる
        XCTAssertTrue(m.crossfadeSelected())
        XCTAssertEqual(m.clip("v")?.transitionIn, MovieCutCore.Transition(.fade, duration: 2))
        XCTAssertEqual(m.effectiveUndoManager.undoActionName, "クロスフェードにする")
        XCTAssertTrue(m.statusText.contains("2.00"), m.statusText)
        XCTAssertEqual(m.clip("a")!.hasTransition, false)
        // 重なりが無い
        m.selectedClipId = "b"
        let before = m.project
        m.statusText = ""
        XCTAssertFalse(m.crossfadeSelected())
        XCTAssertEqual(m.project, before)
        XCTAssertTrue(m.statusText.contains("重ねて"), m.statusText)
        // 音声は対象外
        m.selectedClipId = "m"
        XCTAssertFalse(m.crossfadeSelected())
        XCTAssertTrue(m.statusText.contains("画像・動画・テキスト"))
    }

    // MARK: メニュー

    private func state(_ f: (inout MenuState) -> Void = { _ in }) -> MenuState {
        var s = MenuState(); s.hasDocument = true; s.canExport = true
        s.resolutionKey = "1920x1080"; s.codec = "h264"; s.bg = "#000000"
        f(&s); return s
    }

    func testMenuSpec() {
        let s = state { $0.canTransition = true; $0.hasTransitions = true; $0.canFadeInOut = true; $0.transitionInKind = "zoom"; $0.transitionOutKind = nil }
        let ins = AppMenuSpec.transitionKindItems(s, edge: .in)
        XCTAssertEqual(ins.map(\.title), ["なし", "フェード", "ズーム", "スライド（左）", "スライド（右）", "スライド（上）", "スライド（下）", "ワイプ（左）", "ワイプ（右）", "ワイプ（上）", "ワイプ（下）", "円形ワイプ", "時計回りワイプ", "ぼかし", "回転"])
        XCTAssertEqual(ins.filter { $0.checked == true }.map(\.title), ["ズーム"])
        XCTAssertEqual(AppMenuSpec.transitionKindItems(s, edge: .out).filter { $0.checked == true }.map(\.title), ["なし"])
        XCTAssertTrue(ins.allSatisfy { $0.shortcut == nil && $0.enabled })
        XCTAssertEqual(ins[2].command, .transitionIn(.zoom)); XCTAssertEqual(AppMenuSpec.transitionKindItems(s, edge: .out)[2].command, .transitionOut(.zoom))
        let acts = AppMenuSpec.transitionActions(s)
        XCTAssertEqual(acts.map(\.title), ["両方にフェードを付ける", "トランジションをすべて外す"])
        XCTAssertEqual(acts[0].shortcut?.display, "⌥⌘F")
        XCTAssertEqual(AppMenuSpec.transitionQuick(s).map(\.title), ["クロスフェードにする", "フェードイン・アウトを付ける"])
        XCTAssertTrue(AppMenuSpec.transitionQuick(s).allSatisfy(\.enabled))
        // 無効の条件
        let none = state()
        for list in [AppMenuSpec.transitionKindItems(none, edge: .in), AppMenuSpec.transitionActions(none), AppMenuSpec.transitionQuick(none)] { XCTAssertTrue(list.allSatisfy { !$0.enabled }) }
        let audioOnly = state { $0.canFadeInOut = true }
        XCTAssertFalse(AppMenuSpec.transitionQuick(audioOnly)[0].enabled); XCTAssertTrue(AppMenuSpec.transitionQuick(audioOnly)[1].enabled)
        XCTAssertFalse(AppMenuSpec.transitionActions(state { $0.canTransition = true })[1].enabled, "外すものが無い")
        let locked = state { $0.isLocked = true; $0.canTransition = true; $0.hasTransitions = true; $0.canFadeInOut = true }
        XCTAssertTrue((AppMenuSpec.transitionKindItems(locked, edge: .in) + AppMenuSpec.transitionActions(locked) + AppMenuSpec.transitionQuick(locked)).allSatisfy { !$0.enabled })
        // どのショートカットともぶつからず、修飾キー無しも無い
        let all = AppMenuSpec.all(s).compactMap(\.shortcut)
        XCTAssertEqual(all.count, Set(all).count)
        XCTAssertTrue(all.allSatisfy { !$0.modifiers.isEmpty })
        XCTAssertTrue(AppMenuSpec.all(s).contains { $0.command == .fadeBoth })
        XCTAssertTrue(AppMenuSpec.all(s).contains { $0.command == .transitionOut(.wipeClock) })
        // ⌥⌘F は全画面(⌃⌘F)とは別物
        XCTAssertEqual(all.filter { $0.key == "f" }.count, 2)
    }

    func testMenuStateFollowsSelection() {
        let m = makeModel()
        XCTAssertFalse(MenuState(model: m).canTransition)
        m.selectedClipId = "a"
        var s = MenuState(model: m)
        XCTAssertTrue(s.canTransition); XCTAssertTrue(s.canFadeInOut); XCTAssertFalse(s.hasTransitions); XCTAssertNil(s.transitionInKind)
        m.setTransitionKind(.slideLeft, edge: .in)
        s = MenuState(model: m)
        XCTAssertTrue(s.hasTransitions); XCTAssertEqual(s.transitionInKind, "slideLeft"); XCTAssertNil(s.transitionOutKind)
        m.selectedClipId = "m"
        s = MenuState(model: m)
        XCTAssertFalse(s.canTransition); XCTAssertTrue(s.canFadeInOut)
    }

    func testPerformThroughSpecTable() {
        let m = makeModel()
        m.selectedClipId = "a"
        AppMenu.perform(.transitionIn(.wipeCircle), model: m)
        AppMenu.perform(.transitionOut(.spin), model: m)
        XCTAssertEqual(m.clip("a")?.transitionIn?.known, .wipeCircle); XCTAssertEqual(m.clip("a")?.transitionOut?.known, .spin)
        AppMenu.perform(.transitionIn(nil), model: m)
        XCTAssertNil(m.clip("a")?.transitionIn)
        AppMenu.perform(.fadeBoth, model: m)
        XCTAssertEqual(m.clip("a")?.transitionIn?.known, .fade); XCTAssertEqual(m.clip("a")?.transitionOut?.known, .fade)
        AppMenu.perform(.clearTransitions, model: m)
        XCTAssertFalse(m.clip("a")!.hasTransition)
        AppMenu.perform(.fadeInOut, model: m)
        XCTAssertTrue(m.clip("a")!.hasTransition)
        m.selectedClipId = "v"
        AppMenu.perform(.crossfade, model: m)
        XCTAssertEqual(m.clip("v")?.transitionIn?.duration, 2)
    }

    func testSplitThroughModelDistributesTransitions() {
        let m = makeModel()
        m.selectedClipId = "a"
        m.setTransitionKind(.fade, edge: .in); m.setTransitionKind(.fade, edge: .out)
        m.currentTime = 2
        XCTAssertTrue(m.splitSelected())
        let clips = m.project.tracks[0].clips.filter { $0.type == .image }
        XCTAssertEqual(clips.count, 2)
        XCTAssertNotNil(clips[0].transitionIn); XCTAssertNil(clips[0].transitionOut)
        XCTAssertNil(clips[1].transitionIn); XCTAssertNotNil(clips[1].transitionOut)
    }

    // MARK: タイムラインの三角

    private func makeCanvas(_ m: ProjectModel) -> (TimelineCanvas, NSWindow) {
        let canvas = TimelineCanvas(frame: NSRect(x: 0, y: 0, width: 1000, height: 300))
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = canvas
        canvas.model = m
        canvas.syncFromModel()
        return (canvas, window)
    }

    func testWedgeDragChangesLengthInOneUndoStepAndClamps() {
        let m = makeModel()
        m.pps = 100; m.snapEnabled = false
        m.selectedClipId = "a"                                     // 0〜4 秒
        m.setTransitionKind(.fade, edge: .in); m.setTransitionDuration(1, edge: .in)
        m.setTransitionKind(.fade, edge: .out)
        let (canvas, window) = makeCanvas(m)
        _ = window
        var c = m.clip("a")!
        var r = canvas.geometry.clipRect(start: c.start, duration: c.duration, track: 0)
        let h = try! XCTUnwrap(canvas.wedgeHandle(c, .in, rect: r))
        XCTAssertEqual(h.x, r.minX + 100, accuracy: 1e-6)
        let steps = undoSteps(m)
        // 頭のつまみを右へ 50pt: 1.0 → 1.5 秒
        canvas.mouseDown(at: h)
        for i in 1...5 { canvas.mouseDragged(to: NSPoint(x: h.x + 10 * CGFloat(i), y: h.y)) }
        XCTAssertEqual(m.clip("a")?.transitionIn?.duration, 1.5)
        XCTAssertEqual(undoSteps(m), steps, "ドラッグ中は Undo に積まない")
        canvas.mouseUp()
        XCTAssertEqual(undoSteps(m), steps + 1)
        XCTAssertEqual(m.effectiveUndoManager.undoActionName, "トランジションの長さの変更")
        m.effectiveUndoManager.undo()
        XCTAssertEqual(m.clip("a")?.transitionIn?.duration, 1)
        m.effectiveUndoManager.redo()
        // クリップの半分(2 秒)を超えて引いても収まる
        c = m.clip("a")!; canvas.syncFromModel()
        r = canvas.geometry.clipRect(start: c.start, duration: c.duration, track: 0)
        let h2 = try! XCTUnwrap(canvas.wedgeHandle(c, .in, rect: r))
        canvas.mouseDown(at: h2); canvas.mouseDragged(to: NSPoint(x: h2.x + 900, y: h2.y)); canvas.mouseUp()
        XCTAssertEqual(m.clip("a")?.transitionIn?.duration, 2)
        // 終わりのつまみは左へ引くと長くなる
        let h3 = try! XCTUnwrap(canvas.wedgeHandle(m.clip("a")!, .out, rect: r))
        canvas.mouseDown(at: h3); canvas.mouseDragged(to: NSPoint(x: h3.x - 30, y: h3.y)); canvas.mouseUp()
        XCTAssertEqual(m.clip("a")!.transitionOut!.duration, 0.8, accuracy: 1e-9)
        // 動かさずに離す = 何も登録しない
        let n = undoSteps(m)
        let h4 = try! XCTUnwrap(canvas.wedgeHandle(m.clip("a")!, .out, rect: r))
        canvas.mouseDown(at: h4); canvas.mouseUp()
        XCTAssertEqual(undoSteps(m), n)
    }

    func testWedgeDragOnAudioFadeAndLinkedVideo() {
        let m = makeModel()
        m.pps = 100; m.snapEnabled = false
        m.selectedClipId = "m"
        m.setAudioFade(1, edge: .in)
        let (canvas, window) = makeCanvas(m)
        _ = window
        let c = m.clip("m")!
        let r = canvas.geometry.clipRect(start: c.start, duration: c.duration, track: 0)
        let h = try! XCTUnwrap(canvas.wedgeHandle(c, .in, rect: r))
        canvas.mouseDown(at: h); canvas.mouseDragged(to: NSPoint(x: h.x - 60, y: h.y)); canvas.mouseUp()
        XCTAssertEqual(m.clip("m")!.fadeIn!, 0.4, accuracy: 1e-9)
        // 映像: 連動していれば音声も合う
        m.selectedClipId = "v"
        m.setTransitionKind(.fade, edge: .in); m.setTransitionDuration(1, edge: .in); m.setAudioLinked(true)
        canvas.syncFromModel()
        let vc = m.clip("v")!
        let vr = canvas.geometry.clipRect(start: vc.start, duration: vc.duration, track: 1)
        let vh = try! XCTUnwrap(canvas.wedgeHandle(vc, .in, rect: vr))
        canvas.mouseDown(at: vh); canvas.mouseDragged(to: NSPoint(x: vh.x + 50, y: vh.y)); canvas.mouseUp()
        XCTAssertEqual(m.clip("v")!.transitionIn!.duration, 1.5, accuracy: 1e-9)
        XCTAssertEqual(m.clip("v")!.fadeIn!, 1.5, accuracy: 1e-9)
    }

    func testWedgeHandleNeedsSelectionAndAnExistingTransition() {
        let m = makeModel()
        m.pps = 100
        m.selectedClipId = "a"
        m.setTransitionKind(.fade, edge: .in)
        let (canvas, window) = makeCanvas(m)
        _ = window
        let c = m.clip("a")!
        let r = canvas.geometry.clipRect(start: c.start, duration: c.duration, track: 0)
        XCTAssertNotNil(canvas.wedgeHit(at: canvas.wedgeHandle(c, .in, rect: r)!))
        XCTAssertNil(canvas.wedgeHandle(c, .out, rect: r), "終わりには付けていない")
        m.selectedClipId = nil; canvas.syncFromModel()
        XCTAssertNil(canvas.wedgeHit(at: NSPoint(x: r.minX + 50, y: r.minY + 7)), "選択していないクリップのつまみは掴めない")
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

    func testSnapshotInspector() throws {
        let m = makeModel()
        m.selectedClipId = "v"
        m.setTransitionKind(.wipeClock, edge: .in); m.setTransitionDuration(1.25, edge: .in); m.setTransitionEase(.easeOut, edge: .in)
        m.setTransitionKind(.fade, edge: .out)
        m.setAudioLinked(true)
        let host = NSHostingView(rootView: InspectorView(model: m, speakers: SpeakerCatalog()).frame(width: 300, height: 1250).background(Color(red: 0.14, green: 0.15, blue: 0.17)).preferredColorScheme(.dark))
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 1250)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        try writePNG(host, "inspector-video.png")
        m.selectedClipId = "b"                                      // 文字(トランジションなし)
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        try writePNG(host, "inspector-text.png")
        m.selectedClipId = "m"
        m.setAudioFade(0.5, edge: .in); m.setAudioFade(1, edge: .out); m.setFadeCurve(equalPower: true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        try writePNG(host, "inspector-audio.png")
    }

    func testSnapshotTimelineWedges() throws {
        let m = makeModel()
        m.pps = 90; m.snapEnabled = false
        m.selectedClipId = "v"
        m.setTransitionKind(.zoom, edge: .in); m.setTransitionDuration(1, edge: .in)
        m.setTransitionKind(.wipeRight, edge: .out); m.setTransitionDuration(1.5, edge: .out)
        var a = m.clip("a")!
        a.transitionOut = MovieCutCore.Transition(.fade, duration: 0.8)
        m.project.tracks[0].clips[0] = a
        var au = m.clip("m")!
        au.fadeIn = 0.6; au.fadeOut = 1.2
        m.project.tracks[0].clips[2] = au
        let (canvas, window) = makeCanvas(m)
        _ = window
        canvas.frame = NSRect(x: 0, y: 0, width: 1000, height: 140)
        try writePNG(canvas, "timeline-wedges.png")
    }
}
