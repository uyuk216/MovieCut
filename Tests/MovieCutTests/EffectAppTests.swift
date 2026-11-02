import XCTest
import SwiftUI
import AppKit
import MovieCutCore
@testable import MovieCut

/// エフェクト: モデルの操作(1 操作 = 1 Undo)、メニューの項目表、キーフレーム、インスペクタ。
@MainActor
final class EffectAppTests: XCTestCase {
    static let snapshotDir = (ProcessInfo.processInfo.environment["MC_SNAPSHOT_OUT_DIR_EFFECTS"]
        ?? "/private/tmp/claude-501/-Users-USER------------/07529bfa-5715-4444-bf9c-c37229b6ab4d/scratchpad/effects")

    private func clip(_ id: String, _ type: ClipType, start: Double, dur: Double) -> Clip {
        var c = Clip(); c.id = id; c.type = type; c.start = start; c.duration = dur
        if type == .image || type == .video { c.src = "/tmp/none.png" }
        if type == .audio { c.src = "/tmp/none.wav"; c.srcDuration = dur }
        if type == .text { c.text = "テキスト"; c.fontSize = 80 }
        return c
    }

    private func makeModel() -> ProjectModel {
        var p = Project.new()
        p.fps = 60
        p.tracks[0].clips = [clip("a", .image, start: 0, dur: 4), clip("b", .text, start: 10, dur: 2), clip("m", .audio, start: 14, dur: 6), clip("z", .blur, start: 20, dur: 2)]
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

    // MARK: LUT・クロマキー

    func testLoadLUTIsOneUndoStepAndNoOpRegistersNothing() throws {
        let m = makeModel()
        let u = m.effectiveUndoManager
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lut-app-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let good = dir.appendingPathComponent("a.cube"), bad = dir.appendingPathComponent("bad.cube")
        try "LUT_1D_SIZE 2\n0 0 0\n1 1 1\n".write(to: good, atomically: true, encoding: .utf8)
        try "not a cube".write(to: bad, atomically: true, encoding: .utf8)
        m.selectedClipId = "a"
        XCTAssertTrue(m.loadLUT(from: good))
        XCTAssertEqual(m.clip("a")?.effects.map(\.kind), ["lut"])
        XCTAssertEqual(m.clip("a")?.effects[0].path, good.path)
        XCTAssertEqual(undoSteps(m), 1)
        XCTAssertTrue((u.undoActionName).hasPrefix("LUT の読み込み"))
        XCTAssertFalse(m.loadLUT(from: good), "同じファイルは何も変えない")
        XCTAssertFalse(m.loadLUT(from: bad), "壊れたファイルは断る")
        XCTAssertEqual(m.clip("a")?.effects.count, 1)
        XCTAssertEqual(undoSteps(m), 1)
        u.undo()
        XCTAssertEqual(m.clip("a")?.effects.count, 0)
        // 音声クリップには付けられない
        m.selectedClipId = "m"
        XCTAssertFalse(m.loadLUT(from: good))
    }

    func testLUTMenuItem() {
        var s = state { $0.canEffect = true }
        let item = AppMenuSpec.lutLoadItem(s)
        XCTAssertEqual(item.title, "LUT を読み込む…"); XCTAssertEqual(item.command, .lutLoad)
        XCTAssertTrue(item.enabled); XCTAssertNil(item.shortcut)
        XCTAssertFalse(AppMenuSpec.lutLoadItem(state()).enabled)
        XCTAssertTrue(AppMenuSpec.all(state()).contains { $0.command == .lutLoad })
    }

    // MARK: モデル

    func testAddRemoveMoveAreOneUndoStepEach() {
        let m = makeModel()
        let u = m.effectiveUndoManager
        m.selectedClipId = "a"
        XCTAssertTrue(m.addEffect(.brightness))
        XCTAssertEqual(u.undoActionName, "エフェクトの追加: 明るさ")
        XCTAssertTrue(m.addEffect(.gaussianBlur))
        XCTAssertTrue(m.addEffect(.sepia))
        XCTAssertEqual(m.clip("a")?.effects.map(\.kind), ["brightness", "gaussianBlur", "sepia"])
        XCTAssertTrue(m.moveEffect(at: 2, by: -1))
        XCTAssertEqual(m.clip("a")?.effects.map(\.kind), ["brightness", "sepia", "gaussianBlur"])
        XCTAssertEqual(u.undoActionName, "エフェクトの順番の変更")
        XCTAssertTrue(m.setEffectEnabled(false, at: 0))
        XCTAssertEqual(m.clip("a")?.effects[0].enabled, false)
        XCTAssertTrue(m.removeEffect(at: 1))
        XCTAssertEqual(u.undoActionName, "エフェクトの削除: セピア")
        XCTAssertEqual(undoSteps(m), 6)
        // 元に戻す
        u.undo(); XCTAssertEqual(m.clip("a")?.effects.map(\.kind), ["brightness", "sepia", "gaussianBlur"])
        u.undo(); XCTAssertEqual(m.clip("a")?.effects[0].enabled, true)
        u.undo(); XCTAssertEqual(m.clip("a")?.effects.map(\.kind), ["brightness", "gaussianBlur", "sepia"])
        u.undo(); u.undo(); u.undo()
        XCTAssertTrue(m.clip("a")!.effects.isEmpty)
    }

    func testNoOpEditsRegisterNothing() {
        let m = makeModel()
        m.selectedClipId = "a"
        XCTAssertFalse(m.removeEffect(at: 0))
        XCTAssertFalse(m.moveEffect(at: 0, by: 1))
        XCTAssertFalse(m.clearEffectsSelected())
        XCTAssertFalse(m.copyEffectsSelected())
        XCTAssertFalse(m.pasteEffectsSelected(), "コピーしていない")
        XCTAssertFalse(m.effectiveUndoManager.canUndo)
        m.addEffect(.mono)
        let n = undoSteps(m)
        XCTAssertFalse(m.setEffectEnabled(true, at: 0))
        XCTAssertFalse(m.resetEffect(at: 0), "すでに初期値")
        XCTAssertFalse(m.moveEffect(at: 0, by: -1))
        XCTAssertEqual(undoSteps(m), n)
        // 音声・ぼかし範囲には付けられない
        m.selectedClipId = "m"
        XCTAssertFalse(m.addEffect(.mono)); XCTAssertFalse(m.applyEffectPreset(.vintage))
        m.selectedClipId = "z"
        XCTAssertFalse(m.addEffect(.mono))
        XCTAssertEqual(undoSteps(m), n)
    }

    func testLockedModelRefuses() {
        let m = makeModel()
        m.selectedClipId = "a"
        m.isExporting = true
        XCTAssertTrue(m.isLocked)
        XCTAssertFalse(m.addEffect(.mono))
        XCTAssertTrue(m.clip("a")!.effects.isEmpty)
    }

    func testSliderDragIsOneUndoStepAndClampsAndKeyframes() {
        let m = makeModel()
        m.selectedClipId = "v"
        m.addEffect(.gaussianBlur)
        let u = m.effectiveUndoManager
        let base = undoSteps(m)
        // ドラッグ: begin → live × N → commit = 1 回の Undo
        m.beginGesture()
        for v in [5.0, 20, 60, 400] { m.liveKeyed("fx.0.radius", v, clipId: "v") }
        XCTAssertEqual(m.clip("v")!.effects[0].params["radius"], 100, "範囲に収まる")
        m.commitGesture("エフェクトの変更")
        XCTAssertEqual(undoSteps(m), base + 1)
        XCTAssertEqual(u.undoActionName, "エフェクトの変更")
        u.undo()
        XCTAssertEqual(m.clip("v")!.effects[0].params["radius"], 8)
        // 同じ値のまま離す = 何も登録しない
        let n = undoSteps(m)
        m.beginGesture(); m.liveKeyed("fx.0.radius", 8, clipId: "v"); m.commitGesture("エフェクトの変更")
        XCTAssertEqual(undoSteps(m), n)
        // ◇ でキーを付ける → 以後の編集はキーに入る(設定値は変わらない)
        m.playback.seek(to: m.clip("v")!.start + 1)
        XCTAssertEqual(m.keyState("fx.0.radius", of: m.clip("v")!), .none)
        XCTAssertTrue(m.toggleKeyframe("fx.0.radius", clipId: "v"))
        XCTAssertEqual(m.keyState("fx.0.radius", of: m.clip("v")!), .onKey)
        m.setKeyed("fx.0.radius", 30, clipId: "v")
        XCTAssertEqual(m.clip("v")!.keyframes["fx.0.radius"]!.first!.v, 30, accuracy: 1e-9)
        XCTAssertEqual(m.clip("v")!.effects[0].params["radius"], 8)
        // 並べ替えてもキーはついてくる
        m.addEffect(.sepia)
        XCTAssertTrue(m.moveEffect(at: 0, by: 1))
        XCTAssertNotNil(m.clip("v")!.keyframes["fx.1.radius"]); XCTAssertNil(m.clip("v")!.keyframes["fx.0.radius"])
        m.effectiveUndoManager.undo()
        XCTAssertNotNil(m.clip("v")!.keyframes["fx.0.radius"])
    }

    func testResetColorAndPresetCopyPaste() {
        let m = makeModel()
        m.selectedClipId = "a"
        m.addEffect(.dropShadow)
        m.coalescedEffectColor("#ff0000", at: 0); m.flushCoalesced()
        XCTAssertEqual(m.clip("a")!.effects[0].color, "#ff0000")
        m.setKeyed("fx.0.opacity", 0.1)
        XCTAssertTrue(m.resetEffect(at: 0))
        XCTAssertEqual(m.clip("a")!.effects[0].value("opacity"), 0.6)
        // プリセットは 1 回の Undo
        let before = undoSteps(m)
        XCTAssertTrue(m.applyEffectPreset(.vintage))
        XCTAssertEqual(m.clip("a")!.effects.map(\.kind), ["dropShadow", "sepia", "vignette", "contrast"])
        XCTAssertEqual(undoSteps(m), before + 1)
        XCTAssertEqual(m.effectiveUndoManager.undoActionName, "エフェクトのプリセット: ビンテージ")
        // コピー → 別のクリップへ貼り付け
        XCTAssertTrue(m.copyEffectsSelected())
        XCTAssertEqual(m.effectClipboard.count, 4)
        m.selectedClipId = "b"
        XCTAssertTrue(m.pasteEffectsSelected())
        XCTAssertEqual(m.clip("b")!.effects, m.clip("a")!.effects)
        m.selectedClipId = "m"
        XCTAssertFalse(m.pasteEffectsSelected(), "音声には貼れない")
        m.selectedClipId = "b"
        XCTAssertTrue(m.clearEffectsSelected())
        XCTAssertTrue(m.clip("b")!.effects.isEmpty)
        m.effectiveUndoManager.undo()
        XCTAssertEqual(m.clip("b")!.effects.count, 4)
    }

    // MARK: メニュー

    private func state(_ configure: (inout MenuState) -> Void = { _ in }) -> MenuState {
        var s = MenuState()
        s.hasDocument = true; s.canExport = true
        s.resolutionKey = "1920x1080"; s.codec = "h264"; s.bg = "#000000"
        configure(&s)
        return s
    }

    func testMenuSpecTitlesCommandsAndEnabling() {
        let on = state { $0.canEffect = true; $0.hasEffects = true; $0.canPasteEffects = true }
        let kinds = AppMenuSpec.effectKindItems(on)
        XCTAssertEqual(kinds.map(\.title), ["明るさ", "コントラスト", "彩度", "色相", "露出", "シャープ", "モノクロ", "セピア", "ビネット", "モザイク", "ガウスぼかし", "ズームぼかし", "モーションぼかし", "グロー", "ドロップシャドウ", "縁取り", "クロマキー", "LUT", "顔ぼかし", "ホワイトバランス", "カラーホイール", "光学ミスト", "ハイライト補正", "絞りぼかし"])
        XCTAssertEqual(kinds.map(\.command), EffectKind.allCases.map { MenuCommand.effectAdd($0) })
        XCTAssertTrue(kinds.allSatisfy { $0.enabled && $0.shortcut == nil })
        XCTAssertEqual(AppMenuSpec.effectPresetItems(on).map(\.title), ["ビンテージ", "白黒映画", "夢のような", "強調", "モザイク全体"])
        XCTAssertEqual(AppMenuSpec.effectActions(on).map(\.title), ["エフェクトをすべて外す", "エフェクトのコピー", "エフェクトの貼り付け"])
        XCTAssertTrue(AppMenuSpec.effectActions(on).allSatisfy(\.enabled))
        // 音声など付けられないクリップ / 書き出し中
        let off = state()
        XCTAssertTrue(AppMenuSpec.effectKindItems(off).allSatisfy { !$0.enabled })
        XCTAssertTrue(AppMenuSpec.effectPresetItems(off).allSatisfy { !$0.enabled })
        XCTAssertTrue(AppMenuSpec.effectActions(off).allSatisfy { !$0.enabled })
        let noFx = state { $0.canEffect = true }
        XCTAssertEqual(AppMenuSpec.effectActions(noFx).map(\.enabled), [false, false, false], "外すもの・コピーするもの・貼るものがない")
        let locked = state { $0.canEffect = true; $0.hasEffects = true; $0.canPasteEffects = true; $0.isLocked = true }
        XCTAssertTrue(AppMenuSpec.effectKindItems(locked).allSatisfy { !$0.enabled })
    }

    func testMenuStateFromModelAndPerform() {
        let m = makeModel()
        m.selectedClipId = "a"
        var s = MenuState(model: m)
        XCTAssertTrue(s.canEffect); XCTAssertFalse(s.hasEffects); XCTAssertFalse(s.canPasteEffects)
        AppMenu.perform(.effectAdd(.vignette), model: m)
        AppMenu.perform(.effectPreset(.dreamy), model: m)
        XCTAssertEqual(m.clip("a")!.effects.map(\.kind), ["vignette", "glow", "brightness"])
        s = MenuState(model: m)
        XCTAssertTrue(s.hasEffects)
        AppMenu.perform(.effectCopy, model: m)
        XCTAssertTrue(MenuState(model: m).canPasteEffects)
        m.selectedClipId = "v"
        AppMenu.perform(.effectPaste, model: m)
        XCTAssertEqual(m.clip("v")!.effects.count, 3)
        AppMenu.perform(.effectClear, model: m)
        XCTAssertTrue(m.clip("v")!.effects.isEmpty)
        m.selectedClipId = "m"
        XCTAssertFalse(MenuState(model: m).canEffect)
        AppMenu.perform(.effectAdd(.sepia), model: m)
        XCTAssertTrue(m.clip("m")!.effects.isEmpty)
    }

    func testNoDuplicateAcceleratorsIncludingEffects() {
        let s = state { $0.canEffect = true; $0.hasEffects = true; $0.canPasteEffects = true }
        var seen: [MenuShortcut: String] = [:]
        for it in AppMenuSpec.all(s) {
            guard let sc = it.shortcut else { continue }
            XCTAssertNil(seen[sc], "\(it.title) と \(seen[sc] ?? "") のショートカットが重複")
            seen[sc] = it.title
        }
        XCTAssertFalse(AppMenuSpec.all(s).filter { if case .effectAdd = $0.command { return true }; if case .effectPreset = $0.command { return true }; return false }.contains { $0.shortcut != nil })
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
        m.addEffect(.brightness); m.addEffect(.gaussianBlur); m.addEffect(.dropShadow); m.addEffect(.vignette); m.addEffect(.outline)
        m.setEffectEnabled(false, at: 3)
        m.playback.seek(to: 3)
        m.toggleKeyframe("fx.1.radius", clipId: "v")
        m.playback.seek(to: 5)
        m.setKeyed("fx.1.radius", 40, clipId: "v")
        m.coalescedEffectColor("#3366ff", at: 2); m.flushCoalesced()
        let host = NSHostingView(rootView: InspectorView(model: m, speakers: SpeakerCatalog()).frame(width: 300, height: 2300).background(Color(red: 0.14, green: 0.15, blue: 0.17)).preferredColorScheme(.dark))
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 2300)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        try writePNG(host, "inspector-effects.png")
        m.selectedClipId = "b"                                      // 文字(エフェクトなし)
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        try writePNG(host, "inspector-effects-empty.png")
        m.selectedClipId = "m"                                      // 音声(エフェクト欄なし)
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        try writePNG(host, "inspector-effects-audio.png")
    }
}
