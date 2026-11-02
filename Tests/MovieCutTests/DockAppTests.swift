import XCTest
import SwiftUI
import AppKit
import MovieCutCore
@testable import MovieCut

/// 画面のドッキング: 保存、メニュー、別ウインドウ、キー操作、画面の外での描画(PNG)。
@MainActor
final class DockAppTests: XCTestCase {
    private func makeModel() -> ProjectModel {
        let m = ProjectModel(project: .new())
        m.voiceProviderFactory = { _ in ToneVoiceProvider() }
        m.notices = OneTimeNotices()
        return m
    }

    private func suite() -> UserDefaults {
        let name = "moviecut.test.dock.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        addTeardownBlock { d.removePersistentDomain(forName: name) }
        return d
    }

    private func state(_ configure: (inout MenuState) -> Void = { _ in }) -> MenuState {
        var s = MenuState(); s.hasDocument = true
        configure(&s)
        return s
    }

    private func spin(_ t: TimeInterval = 0.05) { RunLoop.current.run(until: Date().addingTimeInterval(t)) }

    // MARK: 保存

    func testStorePersistsAndRestoresAndFallsBackOnGarbage() {
        let d = suite()
        let a = DockStore(defaults: d)
        XCTAssertEqual(a.layout, .default)
        XCTAssertNil(d.data(forKey: DockStore.defaultsKey), "触っただけでは書かない")
        a.apply(.previewLarge)
        a.close(.characters)
        let b = DockStore(defaults: d)
        XCTAssertEqual(b.layout, a.layout)
        XCTAssertEqual(b.layout.location(of: .characters), .closed)

        d.set(Data("garbage".utf8), forKey: DockStore.defaultsKey)
        XCTAssertEqual(DockStore(defaults: d).layout, .default)
        d.set("文字列", forKey: DockStore.defaultsKey)
        XCTAssertEqual(DockStore(defaults: d).layout, .default)
        d.set(Data(#"{"root":{"kind":"group","panels":["preview"]}}"#.utf8), forKey: DockStore.defaultsKey)
        XCTAssertEqual(DockStore(defaults: d).layout, .default, "矛盾した配置は採らない")
    }

    func testFloatingPanelsComeBackDockedAtLaunch() {
        let d = suite()
        let a = DockStore(defaults: d)
        a.detach(.preview); a.detach(.inspector)
        XCTAssertEqual(a.layout.floating, [.preview, .inspector])
        let b = DockStore(defaults: d)
        XCTAssertTrue(b.layout.floating.isEmpty)
        XCTAssertEqual(b.layout.location(of: .preview), .docked)
        XCTAssertTrue(b.layout.isValid)
    }

    func testDraggingASplitterSavesOnlyWhenReleased() throws {
        let d = suite()
        let s = DockStore(defaults: d)
        s.setFraction(at: [], to: 0.5, persist: false)
        s.setFraction(at: [], to: 0.6, persist: false)
        XCTAssertNil(d.data(forKey: DockStore.defaultsKey))
        s.commit()
        let saved = DockLayout.decoded(from: d.data(forKey: DockStore.defaultsKey))
        XCTAssertEqual(saved, s.layout)
        guard case .split(_, let f, _, _)? = saved.root else { return XCTFail() }
        XCTAssertEqual(f, 0.6, accuracy: 1e-9)
    }

    func testNoOpChangesNeitherPublishNorSave() {
        let d = suite()
        let s = DockStore(defaults: d)
        var changes = 0
        s.onChange = { changes += 1 }
        s.attach(.timeline)                          // すでにドッキング中
        s.moveToEdge(.timeline, .top, ofGroupContaining: .timeline)
        s.moveToTab(.timeline, ofGroupContaining: .timeline)
        s.setActive(.timeline)                       // すでに選ばれている
        XCTAssertEqual(changes, 0)
        XCTAssertNil(d.data(forKey: DockStore.defaultsKey))
        s.detach(.timeline)
        XCTAssertEqual(changes, 1)
    }

    // MARK: メニュー(項目表)

    func testPanelAndLayoutMenuSpecs() {
        let panels = AppMenuSpec.dockPanels(state())
        XCTAssertEqual(panels.map(\.title), ["キャラクター", "プレビュー", "プロパティ", "タイムライン"])
        XCTAssertEqual(panels.map(\.checked), [true, true, true, true])
        XCTAssertEqual(panels.map(\.command), DockPanel.allCases.map { MenuCommand.dockPanel($0) })
        XCTAssertTrue(panels.allSatisfy { $0.shortcut == nil && $0.enabled })
        let hidden = AppMenuSpec.dockPanels(state { $0.dockVisible.remove(.inspector) })
        XCTAssertEqual(hidden.map(\.checked), [true, true, false, true])

        let layouts = AppMenuSpec.dockLayouts(state())
        XCTAssertEqual(layouts.map(\.title), ["初期配置に戻す", "1つのタブにまとめる", "すべて分離", "プレビューを大きく"])
        XCTAssertEqual(layouts.map(\.command), DockPreset.allCases.map { MenuCommand.dockLayout($0) })
        XCTAssertTrue(layouts.allSatisfy { $0.shortcut == nil && $0.checked == nil })
        // 書類が無いとき・書き出し中は選べない(ほかの項目と同じ)
        XCTAssertTrue((AppMenuSpec.dockPanels(state { $0.isLocked = true }) + AppMenuSpec.dockLayouts(state { $0.isLocked = true })).allSatisfy { !$0.enabled })
        XCTAssertTrue((AppMenuSpec.dockPanels(MenuState()) + AppMenuSpec.dockLayouts(MenuState())).allSatisfy { !$0.enabled })
    }

    func testNewItemsAreInTheTableAndAddNoAccelerators() {
        let all = AppMenuSpec.all(state())
        for p in DockPanel.allCases { XCTAssertNotNil(all.first { $0.command == .dockPanel(p) }) }
        for p in DockPreset.allCases { XCTAssertNotNil(all.first { $0.command == .dockLayout(p) }) }
        let used = all.compactMap(\.shortcut)
        XCTAssertEqual(used.count, Set(used).count, "ショートカットが重複しています")
        XCTAssertTrue(used.allSatisfy { !$0.modifiers.isEmpty })
        // ⌘P(別画面)は空いたまま、割り当てない
        XCTAssertFalse(used.contains(MenuShortcut(key: "p", modifiers: .command)))
    }

    func testPerformTogglesPanelsAndAppliesLayoutsThroughTheStore() {
        let saved = AppServices.panelDock
        defer { AppServices.panelDock = saved }
        let store = DockStore(defaults: nil)
        AppServices.panelDock = store
        AppMenu.perform(.dockPanel(.inspector), model: nil)          // ドキュメントが無くても動く(アプリ全体の設定)
        XCTAssertEqual(store.layout.location(of: .inspector), .closed)
        XCTAssertFalse(MenuState(model: nil).dockVisible.contains(.inspector), "メニューの状態に反映")
        AppMenu.perform(.dockPanel(.inspector), model: nil)
        XCTAssertEqual(store.layout, .default)
        AppMenu.perform(.dockLayout(.singleTab), model: nil)
        XCTAssertEqual(store.layout, DockLayout.preset(.singleTab))
        AppMenu.perform(.dockLayout(.initial), model: nil)
        XCTAssertEqual(store.layout, .default)
    }

    func testLayoutChangesAreNotUndoSteps() {
        let m = makeModel()
        let store = DockStore(defaults: nil)
        let before = m.project
        store.apply(.singleTab); store.detach(.timeline); store.apply(.initial)
        XCTAssertFalse(m.effectiveUndoManager.canUndo)
        XCTAssertEqual(m.project.tracks.count, before.tracks.count)
    }

    // MARK: 別ウインドウ

    func testDetachOpensAWindowForTheSameModelAndCloseReattaches() {
        let m = makeModel()
        let store = DockStore(defaults: nil)
        m.installDock(store: store, presents: false)
        let mgr = try! XCTUnwrap(m.dockWindows)
        XCTAssertTrue(mgr.windows.isEmpty)

        store.detach(.preview)
        let w = try! XCTUnwrap(mgr.windows[.preview])
        XCTAssertTrue(w.title.hasPrefix("プレビュー"))
        XCTAssertTrue(w.model === m)
        XCTAssertTrue(w.undoManager === m.effectiveUndoManager, "取り消しは書類と同じ履歴")
        XCTAssertNotNil(w.contentView)

        store.detach(.timeline)
        XCTAssertEqual(Set(mgr.windows.keys), [.preview, .timeline])
        // メニューから閉じる → ウインドウも閉じる
        store.close(.timeline)
        XCTAssertEqual(Set(mgr.windows.keys), [.preview])

        // 利用者がウインドウを閉じる → ドッキングに戻る
        w.close()
        spin(0.2)
        XCTAssertEqual(store.layout.location(of: .preview), .docked)
        XCTAssertTrue(mgr.windows.isEmpty)
        XCTAssertTrue(store.layout.isValid)
        XCTAssertFalse(m.effectiveUndoManager.canUndo)
    }

    /// 切り離し → ドッキングの端へ再ドック(外の帯で離した場合)と、「ウインドウに戻す」(戻し先の記録どおり)。
    func testRedockToOuterEdgeAndRestoreGoHome() {
        let m = makeModel()
        let store = DockStore(defaults: nil)
        m.installDock(store: store, presents: false)
        let mgr = try! XCTUnwrap(m.dockWindows)

        store.detach(.timeline)
        XCTAssertNotNil(mgr.windows[.timeline], "切り離すとウインドウが出る")
        store.redock(.timeline, outer: .bottom)
        XCTAssertNil(mgr.windows[.timeline], "再ドックするとウインドウは消える")
        XCTAssertEqual(store.layout.docked.last, .timeline, "ドック全体の下の端へ入る")
        XCTAssertTrue(store.layout.isValid)

        // 「ウインドウに戻す」: 切り離して、戻す。戻し先の記録(隣と割合)どおり
        store.detach(.preview)
        store.attach(.preview)
        XCTAssertEqual(store.layout.location(of: .preview), .docked)
        XCTAssertTrue(store.layout.isValid)
        XCTAssertNil(store.layout.homes?["preview"], "戻したら記録は消える")
    }

    /// 端の帯の判定(書類のウインドウの左の帯は .left、中央は nil)。
    func testOuterEdgeOfMainWindowFromScreenPoint() {
        let w = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        XCTAssertEqual(DockTearOffTracker.outerEdge(of: w, at: NSPoint(x: 105, y: 400)), .left)
        XCTAssertEqual(DockTearOffTracker.outerEdge(of: w, at: NSPoint(x: 500, y: 400)), nil, "中央は端ではない")
        XCTAssertEqual(DockTearOffTracker.outerEdge(of: w, at: NSPoint(x: 895, y: 400)), .right)
    }

    func testDockWindowsJoinTheKeyRouterAndShutdownKeepsTheLayout() {
        let m = makeModel()
        let store = DockStore(defaults: nil)
        m.installKeyboard()
        m.installDock(store: store, presents: false)
        store.detach(.timeline)
        let w = try! XCTUnwrap(m.dockWindows?.windows[.timeline])
        XCTAssertTrue(m.keyRouter.windows().contains { $0 === w }, "別ウインドウのキー入力も KeyRouter が受ける")
        XCTAssertFalse(m.isDocumentKeyWindow)
        m.shutdown()
        XCTAssertNil(m.dockWindows)
        spin(0.2)
        XCTAssertEqual(store.layout.location(of: .timeline), .floating, "書類を閉じてもパネルの配置は変えない")
    }

    func testSecondDocumentOpensWindowsForAlreadyFloatingPanels() {
        let store = DockStore(defaults: nil)
        store.detach(.inspector)
        let m = makeModel()
        m.installDock(store: store, presents: false)
        XCTAssertEqual(Set(m.dockWindows!.windows.keys), [.inspector])
        m.shutdown()
    }

    // MARK: 画面の外での描画

    private func outDir() throws -> URL {
        let d = ProcessInfo.processInfo.environment["MC_SNAPSHOT_OUT_DIR"]
            ?? "/private/tmp/claude-501/-Users-USER------------/07529bfa-5715-4444-bf9c-c37229b6ab4d/scratchpad/docking"
        let u = URL(fileURLWithPath: d)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    @discardableResult
    private func snapshot(_ layout: DockLayout, name: String, size: NSSize = NSSize(width: 1400, height: 900)) throws -> Int {
        let m = makeModel()
        _ = m.addTextClip()
        m.playback.seek(to: 1)
        _ = m.addTextClip()
        let store = DockStore(defaults: nil)
        store.mutate { $0 = layout; return true }
        let host = NSHostingView(rootView: ContentView(model: m, fileURL: nil, dock: store, presentsDockWindows: false))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        spin(0.6)
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: try outDir().appendingPathComponent(name))
        m.shutdown()
        return png.count
    }

    func testSnapshotsOfTheLayouts() throws {
        XCTAssertGreaterThan(try snapshot(.default, name: "1-default.png"), 20_000)
        XCTAssertGreaterThan(try snapshot(.preset(.singleTab), name: "2-single-tab.png"), 20_000)
        XCTAssertGreaterThan(try snapshot(.preset(.previewLarge), name: "3-preview-large.png"), 20_000)
        XCTAssertGreaterThan(try snapshot(.preset(.allSeparate), name: "4-all-separate.png"), 20_000)
        var detached = DockLayout.default
        detached.detach(.preview)
        XCTAssertGreaterThan(try snapshot(detached, name: "5-preview-detached.png"), 20_000)
        var all = DockLayout.default
        for p in DockPanel.allCases { all.detach(p) }
        XCTAssertGreaterThan(try snapshot(all, name: "6-all-detached-placeholder.png"), 5_000)
        // 窓が小さくても潰れない
        XCTAssertGreaterThan(try snapshot(.default, name: "7-default-small.png", size: NSSize(width: 1100, height: 700)), 20_000)
    }

    /// 別ウインドウのパネルの中身(プレビュー・プロパティ)を描く。
    func testSnapshotOfDetachedPanelContents() throws {
        let m = makeModel()
        _ = m.addTextClip()
        for p in [DockPanel.preview, .inspector, .characters] {
            let host = NSHostingView(rootView: DockPanelWindowRoot(model: m, panel: p, store: DockStore(defaults: nil)))
            host.frame = NSRect(origin: .zero, size: DockWindowManager.defaultSize(of: p))
            let w = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: true)
            w.contentView = host
            host.layoutSubtreeIfNeeded(); spin(0.4); host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try png.write(to: try outDir().appendingPathComponent("8-window-\(p.rawValue).png"))
            XCTAssertGreaterThan(png.count, 3_000)
        }
        m.shutdown()
    }
}
