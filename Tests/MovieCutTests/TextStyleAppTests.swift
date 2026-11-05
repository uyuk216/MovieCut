import XCTest
import SwiftUI
import AppKit
import MovieCutCore
@testable import MovieCut

/// B1 文字の装飾・スタイル・文字アニメーション: モデルの操作(1 操作 = 1 Undo)、保存先、メニューの項目表、インスペクタ(撮影)。
@MainActor
final class TextStyleAppTests: XCTestCase {
    static let snapshotDir = (ProcessInfo.processInfo.environment["MC_SNAPSHOT_OUT_DIR_TEXTSTYLE"]
        ?? "/private/tmp/claude-501/-Users-USER------------/07529bfa-5715-4444-bf9c-c37229b6ab4d/scratchpad/textstyle")

    private var suites: [String] = []
    override func tearDown() { for s in suites { UserDefaults().removePersistentDomain(forName: s) }; suites = [] }

    private func store() -> (TextStyleStore, UserDefaults) {
        let name = "mc-tsapp-\(UUID().uuidString)"; suites.append(name)
        let d = UserDefaults(suiteName: name)!
        return (TextStyleStore(defaults: d), d)
    }

    private func makeModel() -> ProjectModel {
        var p = Project.new()
        p.fps = 60
        var t = Clip(); t.id = "t"; t.type = .text; t.start = 0; t.duration = 4; t.text = "テキスト"; t.fontSize = 80
        var i = Clip(); i.id = "i"; i.type = .image; i.start = 5; i.duration = 2; i.src = "/tmp/none.png"
        var v = Clip(); v.id = "v"; v.type = .voice; v.start = 8; v.duration = 2; v.text = "セリフ"
        p.tracks[0].clips = [t, i, v]
        let m = ProjectModel(project: p)
        m.notices = OneTimeNotices()
        m.textStyles = store().0
        return m
    }

    private func state(_ f: (inout MenuState) -> Void = { _ in }) -> MenuState {
        var s = MenuState(); s.hasDocument = true; s.canExport = true; f(&s); return s
    }

    private func undoSteps(_ m: ProjectModel) -> Int {
        let u = m.effectiveUndoManager
        var n = 0
        while u.canUndo { u.undo(); n += 1 }
        for _ in 0..<n { u.redo() }
        return n
    }

    // MARK: モデル

    func testStyleEditsAreOneUndoStepEachAndNoOpsRegisterNothing() {
        let m = makeModel(); let u = m.effectiveUndoManager
        m.selectedClipId = "t"
        XCTAssertTrue(m.setTextStyle({ $0.shadow = .init() }, name: "影の変更"))
        XCTAssertEqual(u.undoActionName, "影の変更")
        XCTAssertFalse(m.setTextStyle({ $0.shadow = .init() }, name: "影の変更"), "同じ値は何もしない")
        XCTAssertTrue(m.setTextStyle({ $0.italic = true }, name: "斜体の変更"))
        XCTAssertTrue(m.setTextAnim(.pop))
        XCTAssertEqual(u.undoActionName, "文字アニメーション: ポップ")
        XCTAssertFalse(m.setTextAnim(.pop))
        XCTAssertEqual(undoSteps(m), 3)
        u.undo(); XCTAssertNil(m.clip("t")?.textAnim)
        u.undo(); XCTAssertNil(m.clip("t")?.textStyle?.italic); XCTAssertNotNil(m.clip("t")?.textStyle?.shadow)
        u.undo(); XCTAssertNil(m.clip("t")?.textStyle)
        // 画像には付けられない / ロック中も拒否
        XCTAssertFalse(m.setTextStyle({ $0.italic = true }, name: "x", clipId: "i"))
        XCTAssertFalse(m.setTextAnim(.shake, clipId: "i"))
        // 字幕(ボイス)には装飾と(スクロール以外の)アニメーションが付くが、スタイル適用は文字だけ
        XCTAssertTrue(m.setTextStyle({ $0.shadow = .init() }, name: "影の変更", clipId: "v"))
        XCTAssertFalse(m.setTextAnim(.scrollUp, clipId: "v"))
        XCTAssertTrue(m.setTextAnim(.pop, clipId: "v"))
        XCTAssertFalse(m.applyTextStyle(id: "builtin.news", clipId: "v"))
    }

    func testSliderDragIsOneUndoStep() {
        let m = makeModel(); let u = m.effectiveUndoManager
        m.selectedClipId = "t"
        m.setTextStyle({ $0.shadow = .init() }, name: "影の変更")
        let before = undoSteps(m)
        m.beginGesture()
        for v in stride(from: 0.0, through: 30.0, by: 5) { m.liveClipProperty({ _ = TextStyleEditing.update(&$0) { $0.shadow?.dx = v } }, name: "影の変更") }
        m.commitGesture("影の変更")
        XCTAssertEqual(m.clip("t")?.textStyle?.shadow?.dx, 30)
        XCTAssertEqual(undoSteps(m), before + 1)
        u.undo(); XCTAssertEqual(m.clip("t")?.textStyle?.shadow?.dx, 4)
        // 色のような連続編集もまとめて 1 回
        m.coalescedTextStyle({ $0.shadow?.color = "#112233" }, name: "影の色の変更")
        m.coalescedTextStyle({ $0.shadow?.color = "#445566" }, name: "影の色の変更")
        m.flushCoalesced()
        XCTAssertEqual(m.clip("t")?.textStyle?.shadow?.color, "#445566")
        XCTAssertEqual(u.undoActionName, "影の色の変更")
        u.undo(); XCTAssertEqual(m.clip("t")?.textStyle?.shadow?.color, "#000000")
    }

    func testApplyStyleIsOneUndoStepAndKeepsSizeAndText() {
        let m = makeModel(); let u = m.effectiveUndoManager
        m.selectedClipId = "t"
        XCTAssertTrue(m.applyTextStyle(id: "builtin.bubble"))
        XCTAssertEqual(u.undoActionName, "スタイルを適用: 吹き出し風")
        let c = m.clip("t")!
        XCTAssertEqual(c.color, "#222222"); XCTAssertNotNil(c.bubble); XCTAssertNil(c.textStyle?.box); XCTAssertEqual(c.fontSize, 80); XCTAssertEqual(c.text, "テキスト")
        XCTAssertFalse(m.applyTextStyle(id: "builtin.bubble"), "同じスタイルをもう一度は変更なし")
        XCTAssertFalse(m.applyTextStyle(id: "nope"))
        XCTAssertEqual(undoSteps(m), 1)
        u.undo()
        XCTAssertNil(m.clip("t")?.color); XCTAssertNil(m.clip("t")?.textStyle)
        // 標準へ戻す
        m.applyTextStyle(id: "builtin.classic"); m.applyTextStyle(id: "builtin.standard")
        XCTAssertNil(m.clip("t")?.textStyle); XCTAssertNil(m.clip("t")?.outline)
    }

    func testSaveRenameDeleteStylePersistsAndAppliesAnywhere() throws {
        let (st, d) = store()
        let m = makeModel(); m.textStyles = st
        m.selectedClipId = "t"
        m.setTextStyle({ $0.gradient = .init(color1: "#00ff00", color2: "#0000ff", angle: 0) }, name: "g")
        m.setClipProperty({ $0.color = "#abcdef" }, name: "色の変更")
        XCTAssertNil(m.saveCurrentTextStyle(named: "   "), "名前が空なら保存しない")
        let id = try XCTUnwrap(m.saveCurrentTextStyle(named: "マイ見出し"))
        XCTAssertEqual(st.user.map(\.name), ["マイ見出し"])
        // 再起動しても残る
        XCTAssertEqual(TextStyleStore(defaults: d).user, st.user)
        // 元に戻すに載らない(アプリ全体の設定)
        XCTAssertFalse(m.effectiveUndoManager.canUndo && m.effectiveUndoManager.undoActionName.contains("保存"))
        m.setClipProperty({ _ = TextStyleEditing.clear(&$0); $0.color = nil }, name: "clear")
        XCTAssertTrue(m.applyTextStyle(id: id))
        XCTAssertEqual(m.clip("t")?.color, "#abcdef"); XCTAssertEqual(m.clip("t")?.textStyle?.gradient?.color1, "#00ff00")
        XCTAssertTrue(m.renameTextStyle(id: id, to: "新しい名前"))
        XCTAssertEqual(TextStyleStore(defaults: d).user.first?.name, "新しい名前")
        XCTAssertFalse(m.renameTextStyle(id: "builtin.news", to: "x"), "組み込みの名前は変えられない")
        XCTAssertFalse(m.deleteTextStyle(id: "builtin.news"))
        XCTAssertTrue(m.deleteTextStyle(id: id))
        XCTAssertTrue(TextStyleStore(defaults: d).user.isEmpty)
        // 壊れた保存データでも落ちずに空から始まる
        d.set(Data("garbage".utf8), forKey: TextStyleLibrary.defaultsKey)
        XCTAssertTrue(TextStyleStore(defaults: d).user.isEmpty)
        XCTAssertEqual(TextStyleStore(defaults: d).all.count, 16)
        XCTAssertNil(TextStyleStore(defaults: nil).add(name: "", look: TextLook()))
    }

    // MARK: メニュー

    func testMenuSpecAndPerform() {
        let on = state { $0.isTextClip = true; $0.textStyleChoices = TextStyleLibrary.builtins.map { .init(id: $0.id, name: $0.name, builtin: true) } + [.init(id: "user.1", name: "自分用", builtin: false)] }
        let items = AppMenuSpec.textStyleItems(on)
        XCTAssertEqual(items.map(\.title), ["標準", "ゆっくり風", "ニュース帯", "見出し", "吹き出し風", "注意", "フェードイン", "タイプライター", "ポップ"] + TextStyleLibrary.animatedTitles.map(\.name) + ["自分用"])
        XCTAssertEqual(items.map(\.command), (TextStyleLibrary.builtins.map(\.id) + ["user.1"]).map { MenuCommand.textStyleApply($0) })
        XCTAssertTrue(items.allSatisfy { $0.enabled && $0.shortcut == nil })
        XCTAssertEqual(AppMenuSpec.textAnimItems(on).map(\.title), ["なし", "タイプライター", "ポップ", "シェイク", "スクロール（上へ）", "スクロール（左へ）", "フェードイン"])
        XCTAssertEqual(AppMenuSpec.textAnimItems(on).map(\.checked), [true, false, false, false, false, false, false])
        let off = state { $0.textStyleChoices = on.textStyleChoices }
        XCTAssertTrue(AppMenuSpec.textStyleItems(off).allSatisfy { !$0.enabled })
        XCTAssertTrue(AppMenuSpec.textAnimItems(off).allSatisfy { !$0.enabled })
        let locked = state { $0.isTextClip = true; $0.isLocked = true; $0.textStyleChoices = on.textStyleChoices }
        XCTAssertTrue(AppMenuSpec.textStyleItems(locked).allSatisfy { !$0.enabled })

        let m = makeModel()
        m.selectedClipId = "t"
        var s = MenuState(model: m)
        XCTAssertTrue(s.isTextClip); XCTAssertEqual(s.textStyleChoices.count, 16)
        AppMenu.perform(.textStyleApply("builtin.warning"), model: m)
        XCTAssertEqual(m.clip("t")?.color, "#e53935")
        AppMenu.perform(.textAnim(.shake), model: m)
        s = MenuState(model: m)
        XCTAssertEqual(s.textAnimKind, .shake)
        XCTAssertEqual(AppMenuSpec.textAnimItems(s).map(\.checked), [false, false, false, true, false, false, false])
        // スクロールの速さ: 既定の値は書かない・Undo 1 回で戻る
        m.setTextAnim(.scrollUp, clipId: "t")
        XCTAssertNil(m.clip("t")?.textAnim?.speed)
        m.coalescedTextAnimSpeed(0.25, clipId: "t"); m.coalescedTextAnimSpeed(0.3, clipId: "t")
        XCTAssertEqual(m.clip("t")?.textAnim?.speed, 0.3)
        m.flushCoalesced()  // 連続編集は確定してから 1 回で戻す
        m.effectiveUndoManager.undo()
        XCTAssertNil(m.clip("t")?.textAnim?.speed, "速さの連続変更は 1 回で戻る")
        XCTAssertEqual(m.clip("t")?.textAnim?.kind, "scrollUp")
        m.selectedClipId = "i"
        XCTAssertFalse(MenuState(model: m).isTextClip)
        AppMenu.perform(.textStyleApply("builtin.news"), model: m)
        XCTAssertNil(m.clip("i")?.textStyle)
        // ショートカットは付けない・重複なし
        var seen: [MenuShortcut: String] = [:]
        for it in AppMenuSpec.all(on) { guard let sc = it.shortcut else { continue }; XCTAssertNil(seen[sc], it.title); seen[sc] = it.title }
        XCTAssertFalse(AppMenuSpec.all(on).filter { if case .textStyleApply = $0.command { return true }; if case .textAnim = $0.command { return true }; return false }.contains { $0.shortcut != nil })
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
        let (st, _) = store(); m.textStyles = st
        st.add(name: "自分の見出し", look: TextLook(color: "#ffcc00", outline: "#000000"))
        m.selectedClipId = "t"
        m.applyTextStyle(id: "builtin.heading")
        m.setTextStyle({ $0.box = .init(); $0.letterSpacing = 6; $0.align = "left"; $0.italic = true }, name: "x")
        m.setTextAnim(.typewriter, duration: 1.5)
        let host = NSHostingView(rootView: InspectorView(model: m, speakers: SpeakerCatalog()).frame(width: 300, height: 2000).background(Color(red: 0.14, green: 0.15, blue: 0.17)).preferredColorScheme(.dark))
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 2000)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        try writePNG(host, "inspector-textstyle.png")
        m.selectedClipId = "v"                                      // 字幕: 装飾だけ(スタイル・アニメーション欄なし)
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        try writePNG(host, "inspector-textstyle-voice.png")
    }
}

/// 縦書き・1 文字ずつの動き・字幕のアニメーション(メニューとモデル)。
@MainActor
final class VerticalTextAppTests: XCTestCase {
    private func makeModel() -> ProjectModel {
        var p = Project.new()
        var t = Clip(); t.id = "t"; t.type = .text; t.start = 0; t.duration = 4; t.text = "テキスト"; t.fontSize = 80
        var v = Clip(); v.id = "v"; v.type = .voice; v.start = 8; v.duration = 2; v.text = "セリフ"
        var i = Clip(); i.id = "i"; i.type = .image; i.start = 5; i.duration = 2; i.src = "/tmp/none.png"
        p.tracks[0].clips = [t, i, v]
        let m = ProjectModel(project: p)
        m.notices = OneTimeNotices()
        return m
    }

    func testVerticalToggleIsOneUndoAndMenuReflectsIt() {
        let m = makeModel(); let u = m.effectiveUndoManager
        m.selectedClipId = "t"
        var s = MenuState(model: m)
        XCTAssertTrue(AppMenuSpec.textVerticalItem(s).enabled)
        XCTAssertEqual(AppMenuSpec.textVerticalItem(s).checked, false)
        AppMenu.perform(.toggleVertical, model: m)
        XCTAssertEqual(m.clip("t")?.textStyle?.vertical, true)
        s = MenuState(model: m)
        XCTAssertEqual(AppMenuSpec.textVerticalItem(s).checked, true)
        u.undo()
        XCTAssertNil(m.clip("t")?.textStyle, "1 回で元に戻り、項目ごと消える")
        u.redo()
        AppMenu.perform(.toggleVertical, model: m)
        XCTAssertNil(m.clip("t")?.textStyle?.vertical)
        m.selectedClipId = "i"
        XCTAssertFalse(AppMenuSpec.textVerticalItem(MenuState(model: m)).enabled)
        XCTAssertNotNil(AppMenuSpec.disabledReason(for: AppMenuSpec.textVerticalItem(MenuState(model: m)), state: MenuState(model: m)))
    }

    func testSubtitleVoiceClipGetsVerticalAndAnimations() {
        let m = makeModel(); let u = m.effectiveUndoManager
        m.selectedClipId = "v"
        let s = MenuState(model: m)
        XCTAssertTrue(AppMenuSpec.textVerticalItem(s).enabled)
        let anim = AppMenuSpec.textAnimItems(s)
        XCTAssertEqual(anim.filter(\.enabled).map(\.title), ["なし", "タイプライター", "ポップ", "シェイク", "フェードイン"], "字幕はスクロール以外")
        AppMenu.perform(.textAnim(.pop), model: m)
        XCTAssertEqual(m.clip("v")?.textAnim?.kind, "pop")
        AppMenu.perform(.textAnim(.scrollUp), model: m)
        XCTAssertEqual(m.clip("v")?.textAnim?.kind, "pop", "字幕はスクロールにならない")
        AppMenu.perform(.toggleVertical, model: m)
        XCTAssertEqual(m.clip("v")?.textStyle?.vertical, true)
        u.undo(); u.undo()
        XCTAssertNil(m.clip("v")?.textAnim)
    }

    func testPerCharToggleNeedsAnimationAndIsOneUndo() {
        let m = makeModel(); let u = m.effectiveUndoManager
        m.selectedClipId = "t"
        XCTAssertFalse(AppMenuSpec.textPerCharItem(MenuState(model: m)).enabled, "アニメーションが無いうちは使えない")
        m.setTextAnim(.pop, clipId: "t")
        XCTAssertTrue(AppMenuSpec.textPerCharItem(MenuState(model: m)).enabled)
        AppMenu.perform(.togglePerChar, model: m)
        XCTAssertEqual(m.clip("t")?.textAnim?.perChar, TextAnim.defaultPerChar)
        XCTAssertEqual(AppMenuSpec.textPerCharItem(MenuState(model: m)).checked, true)
        m.coalescedTextAnimPerChar(0.2, clipId: "t"); m.coalescedTextAnimPerChar(0.25, clipId: "t")
        m.flushCoalesced()
        XCTAssertEqual(m.clip("t")?.textAnim?.perChar, 0.25)
        u.undo()
        XCTAssertEqual(m.clip("t")?.textAnim?.perChar, TextAnim.defaultPerChar, "連続変更は 1 回で戻る")
        AppMenu.perform(.togglePerChar, model: m)
        XCTAssertNil(m.clip("t")?.textAnim?.perChar)
        m.setTextAnim(.scrollUp, clipId: "t")
        XCTAssertFalse(AppMenuSpec.textPerCharItem(MenuState(model: m)).enabled, "スクロールには使えない")
    }

    func testNewMenuItemsHaveNoShortcut() {
        let s = MenuState()
        XCTAssertNil(AppMenuSpec.textVerticalItem(s).shortcut)
        XCTAssertNil(AppMenuSpec.textPerCharItem(s).shortcut)
    }
}
