import XCTest
import SwiftUI
import AppKit
import MovieCutCore
@testable import MovieCut

/// キーフレームとアニメーション: モデルの操作(Undo)、メニュー、タイムラインの菱形、プレビューの直接操作。
@MainActor
final class KeyframeAppTests: XCTestCase {
    static let snapshotDir = (ProcessInfo.processInfo.environment["MC_SNAPSHOT_OUT_DIR_KEYFRAMES"]
        ?? "/private/tmp/claude-501/-Users-USER------------/07529bfa-5715-4444-bf9c-c37229b6ab4d/scratchpad/keyframes")

    private func clip(_ id: String, _ type: ClipType, start: Double, dur: Double) -> Clip {
        var c = Clip(); c.id = id; c.type = type; c.start = start; c.duration = dur
        if type == .image || type == .video { c.src = "/tmp/none.png" }
        if type == .text { c.text = "テキスト"; c.fontSize = 80 }
        return c
    }

    /// T0: a(2〜6 画像)、b(8〜10 文字)、k(11〜13 ぼかし範囲)、m(14〜16 音声)
    private func makeModel() -> ProjectModel {
        var p = Project.new()
        p.fps = 60
        p.tracks[0].clips = [clip("a", .image, start: 2, dur: 4), clip("b", .text, start: 8, dur: 2), clip("k", .blur, start: 11, dur: 2), clip("m", .audio, start: 14, dur: 2)]
        let m = ProjectModel(project: p)
        m.notices = OneTimeNotices()
        return m
    }

    private var um: UndoManager!
    private func undoCount(_ m: ProjectModel) -> Int {
        var n = 0
        while m.effectiveUndoManager.canUndo { m.effectiveUndoManager.undo(); n += 1 }
        return n
    }

    // MARK: モデル

    func testDiamondToggleAddsAndRemovesWithOneUndoEach() {
        let m = makeModel()
        let u = m.effectiveUndoManager
        m.selectedClipId = "a"
        m.currentTime = 3                                   // クリップの頭から 1 秒
        XCTAssertTrue(m.toggleKeyframe("x"))
        XCTAssertEqual(m.clip("a")?.keyframes["x"], [Keyframe(t: 1, v: 0.5)])
        XCTAssertEqual(u.undoActionName, "キーフレームの追加")
        XCTAssertEqual(m.focusedAnimatableKey, "x")
        XCTAssertEqual(m.keyState("x", of: m.clip("a")!), .onKey)
        XCTAssertEqual(m.keyState("y", of: m.clip("a")!), .none)
        m.currentTime = 3.2
        XCTAssertEqual(m.keyState("x", of: m.clip("a")!), .between)
        m.currentTime = 3
        XCTAssertTrue(m.toggleKeyframe("x"))
        XCTAssertNil(m.clip("a")?.keyframes["x"])
        XCTAssertEqual(u.undoActionName, "キーフレームの削除")
        XCTAssertEqual(undoCount(m), 2)
        XCTAssertTrue(m.clip("a")!.keyframes.isEmpty)
    }

    func testEditingAnimatedPropertyCreatesOrUpdatesKeyInsteadOfStaticValue() {
        let m = makeModel()
        m.selectedClipId = "a"
        m.currentTime = 2                                   // 頭
        m.toggleKeyframe("x")
        m.currentTime = 6                                   // 終わり(クリップの中ではないので、頭から 4 秒に収める)
        m.setKeyed("x", 0.9)
        XCTAssertEqual(m.clip("a")?.keyframes["x"]?.map(\.t), [0, 4])
        XCTAssertEqual(m.clip("a")?.keyframes["x"]?.map(\.v), [0.5, 0.9])
        XCTAssertNil(m.clip("a")?.x, "設定値は触らない")
        // キーの上で編集すると更新だけ
        m.setKeyed("x", 0.8)
        XCTAssertEqual(m.clip("a")?.keyframes["x"]?.map(\.v), [0.5, 0.8])
        XCTAssertEqual(m.effectiveUndoManager.undoActionName, "位置の変更")
        // 再生ヘッドでの値が見える
        m.currentTime = 4
        XCTAssertEqual(m.animatedValue("x", of: m.clip("a")!), 0.65, accuracy: 1e-9)
        // キーのない項目は、従来どおり設定値(丸めも従来の範囲)
        m.setKeyed("y", 9)
        XCTAssertEqual(m.clip("a")?.y, 1)
        m.setKeyed("rotation", 45)
        XCTAssertEqual(m.clip("a")?.rotation, 45)
        m.setKeyed("rotation", 0)
        XCTAssertNil(m.clip("a")?.rotation)
    }

    func testNoOpEditsRegisterNothing() {
        let m = makeModel()
        m.selectedClipId = "a"
        m.currentTime = 3
        m.setKeyed("opacity", 1)                            // 既定値と同じ書き込み
        XCTAssertEqual(m.clip("a")?.opacity, 1)
        let n = undoCountSteps(m)
        m.setKeyed("opacity", 1)
        XCTAssertEqual(undoCountSteps(m), n)
        m.setFlip(horizontal: true, false)                  // すでに false
        XCTAssertNil(m.clip("a")?.flipH)
        XCTAssertFalse(m.clearKeyframes())
        XCTAssertFalse(m.resetTransform())
    }

    private func undoCountSteps(_ m: ProjectModel) -> Int {
        let u = m.effectiveUndoManager
        var n = 0
        while u.canUndo { u.undo(); n += 1 }
        for _ in 0..<n { u.redo() }
        return n
    }

    func testSliderGestureWithKeyIsOneUndoStep() {
        let m = makeModel()
        m.selectedClipId = "a"
        m.currentTime = 3
        m.toggleKeyframe("opacity")
        let before = undoCountSteps(m)
        m.beginGesture()
        for v in [0.9, 0.7, 0.4, 0.2] { m.liveKeyed("opacity", v) }
        m.commitGesture(ClipField.opacity.undoName)
        XCTAssertEqual(m.clip("a")?.keyframes["opacity"]?.last?.v, 0.2)
        XCTAssertEqual(undoCountSteps(m), before + 1)
    }

    func testSeekKeyframeFocusedKeyAndAllKeys() {
        let m = makeModel()
        m.selectedClipId = "a"
        m.currentTime = 3; m.toggleKeyframe("x")
        m.currentTime = 4; m.toggleKeyframe("x")
        m.currentTime = 5; m.toggleKeyframe("y")
        m.currentTime = 2
        XCTAssertEqual(m.focusedAnimatableKey, "y")
        // 最後に触った項目は y: 前後は y のキーだけ
        XCTAssertTrue(m.seekKeyframe(forward: true)); XCTAssertEqual(m.currentTime, 5)
        XCTAssertFalse(m.seekKeyframe(forward: true))
        XCTAssertFalse(m.seekKeyframe(forward: false), "y のキーは 5 秒の 1 つだけ(いまそこ)")
        // 項目を指定
        XCTAssertTrue(m.seekKeyframe(forward: false, key: "x")); XCTAssertEqual(m.currentTime, 4)
        // 選び直すと「最後に触った項目」は無くなり、全項目が対象
        m.selectedClipId = "b"; m.selectedClipId = "a"
        XCTAssertNil(m.focusedAnimatableKey)
        m.currentTime = 3.5
        XCTAssertTrue(m.seekKeyframe(forward: true)); XCTAssertEqual(m.currentTime, 4)
        XCTAssertTrue(m.seekKeyframe(forward: true)); XCTAssertEqual(m.currentTime, 5)
    }

    func testMenuToggleOnFocusedPropertyOrAllAnimated() {
        let m = makeModel()
        m.selectedClipId = "a"
        m.currentTime = 3
        // 何も動かしていない & 触った項目も無い → 何もしない(案内を出す)
        XCTAssertFalse(m.toggleKeyframeFromMenu())
        XCTAssertFalse(m.statusText.isEmpty)
        m.toggleKeyframe("x"); m.toggleKeyframe("y")
        m.currentTime = 4
        m.selectedClipId = "b"; m.selectedClipId = "a"       // 触った項目を忘れる
        XCTAssertTrue(m.toggleKeyframeFromMenu())             // 動いている全項目(x, y)にキー
        XCTAssertEqual(m.clip("a")?.keyframes["x"]?.map(\.t), [1, 2]); XCTAssertEqual(m.clip("a")?.keyframes["y"]?.map(\.t), [1, 2])
        XCTAssertEqual(m.effectiveUndoManager.undoActionName, "キーフレームの追加")
        XCTAssertTrue(m.toggleKeyframeFromMenu())             // ここにキーがあるので全部消す
        XCTAssertEqual(m.clip("a")?.keyframes["x"]?.map(\.t), [1])
        // 触った項目があればそれだけ
        m.focusedAnimatableKey = "x"
        m.currentTime = 5
        XCTAssertTrue(m.toggleKeyframeFromMenu())
        XCTAssertEqual(m.clip("a")?.keyframes["x"]?.map(\.t), [1, 3]); XCTAssertEqual(m.clip("a")?.keyframes["y"]?.map(\.t), [1])
    }

    func testFlipCropResetAndClearAreOneUndoStepEach() {
        let m = makeModel()
        m.selectedClipId = "a"
        m.setFlip(horizontal: true, true)
        XCTAssertEqual(m.clip("a")?.flipH, true)
        m.setFlip(horizontal: true, false)
        XCTAssertNil(m.clip("a")?.flipH, "オフは未設定に戻す(ファイルに書かない)")
        m.setCropEdge(.left, 0.2); m.setCropEdge(.right, 0.1)
        XCTAssertEqual(m.clip("a")?.crop, Crop(l: 0.2, t: 0, r: 0.1, b: 0))
        m.setKeyed("rotation", 30); m.setFlip(horizontal: false, true)
        XCTAssertTrue(m.resetTransform())
        let c = m.clip("a")!
        XCTAssertNil(c.rotation); XCTAssertNil(c.crop); XCTAssertNil(c.flipV)
        XCTAssertEqual(m.effectiveUndoManager.undoActionName, "変形のリセット")
        m.effectiveUndoManager.undo()
        XCTAssertEqual(m.clip("a")?.rotation, 30)
        m.effectiveUndoManager.redo()
        // すべてのキーを消す
        m.currentTime = 3; m.toggleKeyframe("x"); m.toggleKeyframe("scale")
        XCTAssertTrue(m.clearKeyframes())
        XCTAssertTrue(m.clip("a")!.keyframes.isEmpty)
        XCTAssertEqual(m.effectiveUndoManager.undoActionName, "すべてのキーフレームを消去")
    }

    func testPresetsThroughMenuOneUndoStepAndTypeRules() {
        let m = makeModel()
        m.selectedClipId = "a"
        AppMenu.perform(.animationPreset(.slideFromLeft), model: m)
        XCTAssertEqual(m.clip("a")?.keyframes["x"]?.map(\.v), [-0.5, 0.5])
        XCTAssertEqual(m.effectiveUndoManager.undoActionName, "アニメーション: 左からスライド")
        m.effectiveUndoManager.undo()
        XCTAssertTrue(m.clip("a")!.keyframes.isEmpty)
        m.selectedClipId = "k"                                // ぼかし範囲には当てられない
        let steps = undoCountSteps(m)
        XCTAssertFalse(m.applyAnimationPreset(.zoomIn))
        XCTAssertEqual(undoCountSteps(m), steps)
        m.selectedClipId = "b"                                // 文字には当てられる
        XCTAssertTrue(m.applyAnimationPreset(.spinIn))
        XCTAssertEqual(m.clip("b")?.keyframes["rotation"]?.first?.v, -180)
    }

    func testSplitAndTrimThroughModelKeepKeysGlued() {
        let m = makeModel()
        m.selectedClipId = "a"
        m.currentTime = 2; m.toggleKeyframe("x")
        m.currentTime = 6; m.setKeyed("x", 1)                 // 頭 0: 0.5 → 終わり 4: 1(キーの無い 6 秒は終わりに収める)
        m.currentTime = 4
        XCTAssertTrue(m.splitSelected())
        let l = m.clip("a")!, rightId = m.project.tracks[0].clips[1].id, r = m.clip(rightId)!
        XCTAssertEqual(l.keyframes["x"]?.map(\.v), [0.5, 0.75])
        XCTAssertEqual(r.keyframes["x"]?.map(\.v), [0.75, 1])
        XCTAssertEqual(r.keyframes["x"]?.map(\.t), [0, 2])
        XCTAssertEqual(m.effectiveUndoManager.undoActionName, "クリップの分割")
    }

    // MARK: メニューの項目表

    private func state(_ f: (inout MenuState) -> Void = { _ in }) -> MenuState {
        var s = MenuState(); s.hasDocument = true; s.canExport = true; s.resolutionKey = "1920x1080"; s.codec = "h264"; s.bg = "#000000"
        f(&s); return s
    }

    func testMenuSpecAndShortcuts() {
        let s = state { $0.canKeyframe = true; $0.hasKeyframes = true; $0.hasPrevKeyframe = true; $0.hasNextKeyframe = true; $0.canAnimatePreset = true }
        let k = AppMenuSpec.keyframeItems(s)
        XCTAssertEqual(k.map(\.title), ["キーフレームを追加/削除", "前のキーフレームへ", "次のキーフレームへ", "すべてのキーフレームを消去"])
        XCTAssertEqual(k.map { $0.shortcut?.display }, ["⌥⌘K", "⌥⌘,", "⌥⌘.", nil])
        XCTAssertTrue(k.allSatisfy(\.enabled))
        XCTAssertEqual(AppMenuSpec.animationItems(s).map(\.title), ["ズームイン", "ズームアウト", "左からスライド", "右からスライド", "上から", "下から", "回転しながら登場", "ゆっくり拡大（ケンバーンズ）"])
        XCTAssertTrue(AppMenuSpec.animationItems(s).allSatisfy { $0.shortcut == nil && $0.enabled })
        // 無効の条件
        let none = state()
        XCTAssertTrue(AppMenuSpec.keyframeItems(none).allSatisfy { !$0.enabled })
        XCTAssertTrue(AppMenuSpec.animationItems(none).allSatisfy { !$0.enabled })
        let locked = state { $0.isLocked = true; $0.canKeyframe = true; $0.canAnimatePreset = true }
        XCTAssertTrue(AppMenuSpec.keyframeItems(locked).allSatisfy { !$0.enabled })
        // ほかのどの項目ともショートカットがぶつからない(修飾キー無しも無い)
        let all = AppMenuSpec.all(s).compactMap(\.shortcut)
        XCTAssertEqual(all.count, Set(all).count)
        XCTAssertTrue(all.allSatisfy { !$0.modifiers.isEmpty })
        XCTAssertTrue(AppMenuSpec.all(s).contains { $0.command == .toggleKeyframe })
    }

    func testMenuStateFollowsSelectionAndPlayhead() {
        let m = makeModel()
        XCTAssertFalse(MenuState(model: m).canKeyframe)
        m.selectedClipId = "a"; m.currentTime = 3
        var s = MenuState(model: m)
        XCTAssertTrue(s.canKeyframe); XCTAssertTrue(s.canAnimatePreset); XCTAssertFalse(s.hasKeyframes)
        m.currentTime = 7                                      // クリップの外
        XCTAssertFalse(MenuState(model: m).canKeyframe)
        m.currentTime = 3; m.toggleKeyframe("x"); m.currentTime = 4; m.toggleKeyframe("x")
        m.focusedAnimatableKey = "x"
        m.currentTime = 3.5
        s = MenuState(model: m)
        XCTAssertTrue(s.hasKeyframes); XCTAssertTrue(s.hasPrevKeyframe); XCTAssertTrue(s.hasNextKeyframe)
        m.currentTime = 4
        XCTAssertFalse(MenuState(model: m).hasNextKeyframe)
        m.selectedClipId = "m"; m.currentTime = 15            // 音声: 動かす項目なし
        s = MenuState(model: m)
        XCTAssertFalse(s.canKeyframe); XCTAssertFalse(s.canAnimatePreset)
        m.selectedClipId = "k"; m.currentTime = 12            // ぼかし範囲: ◇ は使えるがプリセットは不可
        s = MenuState(model: m)
        XCTAssertTrue(s.canKeyframe); XCTAssertFalse(s.canAnimatePreset)
    }

    func testPerformThroughSpecTable() {
        let m = makeModel()
        m.selectedClipId = "a"; m.currentTime = 3
        m.focusedAnimatableKey = "x"
        AppMenu.perform(.toggleKeyframe, model: m)
        XCTAssertEqual(m.clip("a")?.keyframes["x"]?.count, 1)
        m.currentTime = 5
        AppMenu.perform(.toggleKeyframe, model: m)
        m.currentTime = 4
        AppMenu.perform(.nextKeyframe, model: m); XCTAssertEqual(m.currentTime, 5)
        AppMenu.perform(.prevKeyframe, model: m); XCTAssertEqual(m.currentTime, 3)
        AppMenu.perform(.clearKeyframes, model: m)
        XCTAssertTrue(m.clip("a")!.keyframes.isEmpty)
    }

    // MARK: タイムラインの菱形

    private func makeCanvas(_ m: ProjectModel) -> (TimelineCanvas, NSWindow) {
        let canvas = TimelineCanvas(frame: NSRect(x: 0, y: 0, width: 1000, height: 300))
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = canvas
        canvas.model = m
        canvas.syncFromModel()
        return (canvas, window)
    }

    func testDiamondClickSeeksAndDragMovesAllKeysAtThatTimeInOneUndoStep() {
        let m = makeModel()
        m.pps = 100; m.snapEnabled = false
        m.selectedClipId = "a"
        m.currentTime = 3; m.toggleKeyframe("x"); m.toggleKeyframe("y")      // 頭から 1 秒に 2 項目
        m.currentTime = 5; m.toggleKeyframe("x")                              // 頭から 3 秒
        let (canvas, window) = makeCanvas(m)
        _ = window
        let c = m.clip("a")!
        let r = canvas.geometry.clipRect(start: c.start, duration: c.duration, track: 0)
        let centers = canvas.keyframeDiamondCenters(c, rect: r)
        XCTAssertEqual(centers.map(\.time), [1, 3])
        // クリック: 選択も Undo もそのまま、再生ヘッドだけ動く
        let steps = undoCountSteps(m)
        m.currentTime = 0
        let p1 = centers[0].point
        canvas.mouseDown(at: p1); canvas.mouseUp()
        XCTAssertEqual(m.currentTime, 3, accuracy: 1e-9)
        XCTAssertEqual(m.selectedClipId, "a")
        XCTAssertEqual(undoCountSteps(m), steps)
        // ドラッグ: 1 秒 → 2 秒(100pt)。全項目の 1 秒のキーが動く
        canvas.mouseDown(at: p1)
        for i in 1...5 { canvas.mouseDragged(to: NSPoint(x: p1.x + 20 * CGFloat(i), y: p1.y)) }
        XCTAssertEqual(m.effectiveUndoManager.canUndo, steps > 0, "ドラッグ中は Undo に積まない")
        canvas.mouseUp()
        let moved = m.clip("a")!
        XCTAssertEqual(moved.keyframes["x"]?.map(\.t), [2, 3]); XCTAssertEqual(moved.keyframes["y"]?.map(\.t), [2])
        XCTAssertEqual(m.effectiveUndoManager.undoActionName, "キーフレームの移動")
        m.effectiveUndoManager.undo()
        XCTAssertEqual(m.clip("a")?.keyframes["x"]?.map(\.t), [1, 3])
        XCTAssertEqual(m.clip("a")?.keyframes["y"]?.map(\.t), [1])
        m.effectiveUndoManager.redo()
        XCTAssertEqual(undoCountSteps(m), steps + 1)
    }

    func testDragThereAndBackRegistersNothingAndClampsToClip() {
        let m = makeModel()
        m.pps = 100; m.snapEnabled = false
        m.selectedClipId = "a"
        m.currentTime = 3; m.toggleKeyframe("x")
        let (canvas, window) = makeCanvas(m)
        _ = window
        let c = m.clip("a")!
        let p = canvas.keyframeDiamondCenters(c, rect: canvas.geometry.clipRect(start: c.start, duration: c.duration, track: 0))[0].point
        let steps = undoCountSteps(m)
        canvas.mouseDown(at: p)
        canvas.mouseDragged(to: NSPoint(x: p.x + 50, y: p.y)); canvas.mouseDragged(to: p)
        canvas.mouseUp()
        XCTAssertEqual(undoCountSteps(m), steps)
        canvas.mouseDown(at: p)
        canvas.mouseDragged(to: NSPoint(x: p.x + 900, y: p.y))
        canvas.mouseUp()
        XCTAssertEqual(m.clip("a")?.keyframes["x"]?.map(\.t), [4], "クリップの終わりまで")
    }

    // MARK: プレビューの直接操作

    private func makePreview(_ m: ProjectModel, assets: RenderAssets, time: Double) -> PreviewCanvasView {
        let v = PreviewCanvasView()
        v.frame = NSRect(x: 0, y: 0, width: 640, height: 400)
        v.model = m
        v.setPlaceholder(project: m.project)
        v.layoutSubtreeIfNeeded()
        v.layout()
        v.updateOverlay(PreviewView.overlayTarget(model: m, project: m.project, time: time, assets: assets))
        return v
    }

    private func writeSolid(_ name: String, size: Int = 64) throws -> String {
        let c = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(CGColor(srgbRed: 0.9, green: 0.3, blue: 0.2, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: size, height: size))
        c.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)); c.fill(CGRect(x: 0, y: size / 2, width: size / 2, height: size / 2))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kf-\(UUID().uuidString)-\(name).png")
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, c.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url.path
    }

    private func previewModel() throws -> ProjectModel {
        var p = Project.new()
        p.width = 1280; p.height = 720; p.characters = []
        var c = Clip(); c.id = "p"; c.type = .image; c.src = try writeSolid("a"); c.start = 0; c.duration = 4; c.x = 0.5; c.y = 0.5; c.scale = 0.5
        p.tracks[0].clips = [c]
        let m = ProjectModel(project: p)
        m.selectedClipId = "p"
        m.currentTime = 1
        return m
    }

    func testPreviewOverlayAppearsOnlyForSelectedClipUnderPlayhead() throws {
        let m = try previewModel()
        let assets = m.assets
        let t = try XCTUnwrap(PreviewView.overlayTarget(model: m, project: m.project, time: 1, assets: assets))
        XCTAssertEqual(t.box.center.x, 640, accuracy: 1e-9); XCTAssertEqual(t.box.center.y, 360, accuracy: 1e-9)
        XCTAssertEqual(t.box.width, 360, accuracy: 1e-9)       // 64px 画像を 1280×720 に収めて 720 → ×0.5
        XCTAssertNil(PreviewView.overlayTarget(model: m, project: m.project, time: 5, assets: assets), "再生ヘッドがクリップの外")
        m.selectedClipId = nil
        XCTAssertNil(PreviewView.overlayTarget(model: m, project: m.project, time: 1, assets: assets))
        m.selectedClipId = "p"
        m.isPlaying = true
        XCTAssertNil(PreviewView.overlayTarget(model: m, project: m.project, time: 1, assets: assets), "再生中は出さない")
    }

    func testPreviewDragMoveScaleRotateAreEachOneUndoStep() throws {
        let m = try previewModel()
        let v = makePreview(m, assets: m.assets, time: 1)
        let o = try XCTUnwrap(v.overlay)
        let u = m.effectiveUndoManager
        // 本体をドラッグ: 画面の 64pt 右・32pt 上
        let center = v.viewPoint(o.box.center, canvas: o.canvas)
        XCTAssertTrue(v.beginManipulation(atViewPoint: center))
        for i in 1...4 { v.dragManipulation(toViewPoint: CGPoint(x: center.x + 16 * CGFloat(i), y: center.y + 8 * CGFloat(i))) }
        XCTAssertFalse(u.canUndo, "ドラッグ中は Undo に積まない")
        v.endManipulation()
        let moved = m.clip("p")!
        let f = v.frameForTest
        XCTAssertEqual(moved.x!, 0.5 + 64 / f.width, accuracy: 1e-6)
        XCTAssertEqual(moved.y!, 0.5 - 32 / f.height, accuracy: 1e-6)         // ビューは y 上向き
        XCTAssertEqual(u.undoActionName, "プレビューで移動")
        u.undo(); XCTAssertFalse(u.canUndo)
        XCTAssertEqual(m.clip("p")?.x, 0.5)

        // 角をドラッグして拡大
        let v2 = makePreview(m, assets: m.assets, time: 1)
        let o2 = try XCTUnwrap(v2.overlay)
        let corner = v2.viewPoint(o2.box.corners[2], canvas: o2.canvas)
        let cc = v2.viewPoint(o2.box.center, canvas: o2.canvas)
        XCTAssertTrue(v2.beginManipulation(atViewPoint: corner))
        v2.dragManipulation(toViewPoint: CGPoint(x: cc.x + (corner.x - cc.x) * 2, y: cc.y + (corner.y - cc.y) * 2))
        v2.endManipulation()
        XCTAssertEqual(m.clip("p")!.scale!, 1.0, accuracy: 1e-6)
        XCTAssertEqual(u.undoActionName, "プレビューで拡大")
        u.undo()

        // 回転の取っ手
        let v3 = makePreview(m, assets: m.assets, time: 1)
        let o3 = try XCTUnwrap(v3.overlay)
        let handle = v3.viewPoint(o3.box.rotationHandle, canvas: o3.canvas)
        let c3 = v3.viewPoint(o3.box.center, canvas: o3.canvas)
        XCTAssertTrue(v3.beginManipulation(atViewPoint: handle))
        // 中心から見て真上 → 真右(画面で時計回り 90 度)
        let r = hypot(handle.x - c3.x, handle.y - c3.y)
        v3.dragManipulation(toViewPoint: CGPoint(x: c3.x + r, y: c3.y))
        v3.endManipulation()
        XCTAssertEqual(m.clip("p")!.rotation!, 90, accuracy: 1e-6)
        XCTAssertEqual(u.undoActionName, "プレビューで回転")
        u.undo()
        XCTAssertFalse(u.canUndo)
        // 枠の外では何も始まらない
        let v4 = makePreview(m, assets: m.assets, time: 1)
        XCTAssertFalse(v4.beginManipulation(atViewPoint: CGPoint(x: 3, y: 3)))
        XCTAssertNil(v4.manipulation)
    }

    func testPreviewDragWritesKeysWhenPropertyIsAnimated() throws {
        let m = try previewModel()
        m.selectedClipId = "p"
        m.currentTime = 0; m.toggleKeyframe("x")
        m.currentTime = 2                                        // この時刻にはキーが無い
        let v = makePreview(m, assets: m.assets, time: 2)
        let o = try XCTUnwrap(v.overlay)
        let center = v.viewPoint(o.box.center, canvas: o.canvas)
        let steps = undoCountSteps(m)
        XCTAssertTrue(v.beginManipulation(atViewPoint: center))
        v.dragManipulation(toViewPoint: CGPoint(x: center.x + 40, y: center.y))
        v.endManipulation()
        let c = m.clip("p")!
        XCTAssertEqual(c.keyframes["x"]?.map(\.t), [0, 2])
        XCTAssertEqual(c.keyframes["x"]![1].v, 0.5 + 40 / v.frameForTest.width, accuracy: 1e-6)
        XCTAssertEqual(c.x, 0.5, "設定値は触らない")
        XCTAssertEqual(c.y!, 0.5, accuracy: 1e-9)                 // y にはキーが無いので設定値が書かれる(動かしていないので同じ値)
        XCTAssertEqual(undoCountSteps(m), steps + 1)
    }

    func testPreviewNoDragWhenLockedOrNoMovementRegistersNothing() throws {
        let m = try previewModel()
        let v = makePreview(m, assets: m.assets, time: 1)
        let center = v.viewPoint(try XCTUnwrap(v.overlay).box.center, canvas: try XCTUnwrap(v.overlay).canvas)
        XCTAssertTrue(v.beginManipulation(atViewPoint: center))
        v.endManipulation()
        XCTAssertFalse(m.effectiveUndoManager.canUndo, "動かさずに離しても何も登録しない")
        m.busyMessage = "作成中"
        XCTAssertFalse(v.beginManipulation(atViewPoint: center), "音声作成中などは触れない")
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

    func testSnapshotInspectorWithKeyframes() throws {
        let m = try previewModel()
        m.selectedClipId = "p"
        var c = m.clip("p")!
        c.rotation = 15; c.flipH = true; c.crop = Crop(l: 0.1, t: 0.05, r: 0.2, b: 0)
        c.keyframes["x"] = [Keyframe(t: 0, v: 0.2), Keyframe(t: 2, v: 0.8, ease: .easeInOut)]
        c.keyframes["opacity"] = [Keyframe(t: 1, v: 1)]
        c.keyframes["rotation"] = [Keyframe(t: 0, v: 0), Keyframe(t: 3, v: 15)]
        m.project.tracks[0].clips[0] = c
        m.currentTime = 1                                         // opacity のキーの上、x は途中、rotation は途中
        let host = NSHostingView(rootView: InspectorView(model: m, speakers: SpeakerCatalog()).frame(width: 300, height: 980).background(Color(red: 0.14, green: 0.15, blue: 0.17)).preferredColorScheme(.dark))
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 980)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        try writePNG(host, "inspector.png")
        // 文字の枠(別クリップ)でも崩れない
        m.project.tracks[0].clips.append({ var t = Clip(); t.id = "t"; t.type = .text; t.text = "動く文字"; t.start = 0; t.duration = 4; t.fontSize = 80; t.keyframes["scale"] = [Keyframe(t: 0, v: 1)]; return t }())
        m.selectedClipId = "t"
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        try writePNG(host, "inspector-text.png")
        m.project.tracks[0].clips.append({ var b = ClipEditing.makeBlurClip(at: 0, project: m.project); b.id = "bl"; b.keyframes["x"] = [Keyframe(t: 0, v: 0.2), Keyframe(t: 2, v: 0.6)]; return b }())
        m.selectedClipId = "bl"
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        try writePNG(host, "inspector-blur.png")
    }

    func testSnapshotTimelineDiamonds() throws {
        let m = makeModel()
        m.pps = 90; m.snapEnabled = false
        m.selectedClipId = "a"
        m.currentTime = 3; m.toggleKeyframe("x"); m.toggleKeyframe("scale")
        m.currentTime = 4.5; m.toggleKeyframe("x")
        m.currentTime = 5.5; m.toggleKeyframe("opacity")
        let (canvas, window) = makeCanvas(m)
        _ = window
        canvas.debugSetScroll(x: 90, y: 0)
        canvas.frame = NSRect(x: 0, y: 0, width: 700, height: 160)
        try writePNG(canvas, "timeline.png")
    }

    func testSnapshotPreviewHandles() throws {
        let m = try previewModel()
        var c = m.clip("p")!
        c.rotation = 20
        m.project.tracks[0].clips[0] = c
        let v = makePreview(m, assets: m.assets, time: 1)
        let img = Renderer(project: m.project, assets: m.assets).renderImage(t: 1)
        v.show(image: try XCTUnwrap(img))
        v.updateOverlay(PreviewView.overlayTarget(model: m, project: m.project, time: 1, assets: m.assets))
        v.layoutSubtreeIfNeeded()
        // CALayer を直接描く(NSView の cacheDisplay はサブレイヤーを含まないことがある)
        let size = v.bounds.size
        let ctx = CGContext(data: nil, width: Int(size.width * 2), height: Int(size.height * 2), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
        ctx.scaleBy(x: 2, y: 2)
        v.layer!.render(in: ctx)
        let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(atPath: Self.snapshotDir, withIntermediateDirectories: true)
        try png.write(to: URL(fileURLWithPath: Self.snapshotDir).appendingPathComponent("preview-handles.png"))
        XCTAssertGreaterThan(png.count, 3000)
    }
}
