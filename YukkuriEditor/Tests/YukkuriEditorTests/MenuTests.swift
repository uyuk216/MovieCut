import XCTest
import SwiftUI
import YukkuriCore
@testable import YukkuriEditor

/// M5: メニューバーの構成・有効/無効・ラジオ、依存バナー、Dock、ヘルプ文書、About。
@MainActor
final class MenuTests: XCTestCase {
    private func makeModel() -> ProjectModel {
        let m = ProjectModel(project: .new())
        m.voiceProviderFactory = { _ in ToneVoiceProvider() }
        m.notices = OneTimeNotices()
        return m
    }

    private func state(_ configure: (inout MenuState) -> Void = { _ in }) -> MenuState {
        var s = MenuState()
        s.hasDocument = true
        s.canExport = true
        s.resolutionKey = "1920x1080"; s.codec = "h264"; s.bg = "#000000"
        configure(&s)
        return s
    }

    private func item(_ list: [MenuItemSpec], _ c: MenuCommand) -> MenuItemSpec? { list.first { $0.command == c } }

    // MARK: 構成(menu.js と同じ題・キー)

    func testLabelsAndAcceleratorsMatchMenuJs() {
        let s = state()
        func sc(_ k: KeyEquivalent, _ m: EventModifiers) -> MenuShortcut { MenuShortcut(key: k, modifiers: m) }
        XCTAssertEqual(AppMenuSpec.about.title, "ゆっくりエディタについて")
        XCTAssertEqual(AppMenuSpec.settings(s).title, "設定…")
        XCTAssertEqual(AppMenuSpec.settings(s).shortcut, sc(",", .command))
        let file = AppMenuSpec.file(s)
        XCTAssertEqual(file.map(\.title), ["素材を追加…", "MP4 を書き出す…"])
        XCTAssertEqual(file.map(\.shortcut), [sc("i", .command), sc("e", .command)])
        XCTAssertEqual(AppMenuSpec.editSelection(s).map(\.title), ["分割", "削除"])
        let add = AppMenuSpec.editAdd(s)
        XCTAssertEqual(add.map(\.title), ["テキストを追加", "ぼかし範囲を追加", "キャラクターを追加", "台本から音声を作る"])
        XCTAssertEqual(add.map(\.shortcut), [sc("t", [.command, .shift]), sc("b", [.command, .shift]), sc("c", [.command, .shift]), sc(.return, .command)])
        XCTAssertEqual(AppMenuSpec.playback(s).map(\.title), ["再生 / 停止", "先頭へ戻る", "1コマ戻る", "1コマ進む"])
        let zoom = AppMenuSpec.zoom(s)
        XCTAssertEqual(zoom.map(\.title), ["タイムラインを拡大", "タイムラインを縮小", "全体表示"])
        XCTAssertEqual(zoom.map(\.shortcut), [sc("+", .command), sc("-", .command), sc("0", .command)])
        XCTAssertEqual(AppMenuSpec.resolutions(s).map(\.title), ["1920×1080", "2560×1440", "3840×2160", "縦 1080×1920", "縦 720×1280", "正方形 1080×1080"])
        XCTAssertEqual(AppMenuSpec.customResolution(s).title, "自由…")
        XCTAssertEqual(AppMenuSpec.codecItems(s).map(\.title), ["H.264", "HEVC"])
        XCTAssertEqual(AppMenuSpec.backgroundItems(s).map(\.title), ["黒", "白", "緑（クロマキー）"])
        XCTAssertEqual(AppMenuSpec.secondScreen(s).title, "プレビューを別画面に表示")
        XCTAssertEqual(AppMenuSpec.secondScreen(s).shortcut, sc("p", .command))
        XCTAssertEqual(AppMenuSpec.help.map { $0.map(\.title) }, [["VOICEVOX 公式サイト", "AquesTalkPlayer 公式サイト"], ["ライセンス", "第三者の規約"]])
    }

    func testSecondScreenTitleChangesWhenOpen() {
        XCTAssertEqual(AppMenuSpec.secondScreen(state { $0.isSecondScreenOpen = true }).title, "別画面を閉じる")
        XCTAssertEqual(AppMenuSpec.secondScreen(state()).title, "プレビューを別画面に表示")
    }

    func testNoDuplicateAcceleratorsAndNoClashWithSystemOnes() {
        let all = AppMenuSpec.all(state())
        let used = all.compactMap(\.shortcut)
        XCTAssertEqual(used.count, Set(used).count, "ショートカットが重複しています")
        // DocumentGroup / AppKit が受け持つキー
        let system: [MenuShortcut] = [
            MenuShortcut(key: "n", modifiers: .command), MenuShortcut(key: "o", modifiers: .command), MenuShortcut(key: "w", modifiers: .command),
            MenuShortcut(key: "s", modifiers: .command), MenuShortcut(key: "s", modifiers: [.command, .shift]), MenuShortcut(key: "s", modifiers: [.command, .shift, .option]),
            MenuShortcut(key: "z", modifiers: .command), MenuShortcut(key: "z", modifiers: [.command, .shift]),
            MenuShortcut(key: "x", modifiers: .command), MenuShortcut(key: "c", modifiers: .command), MenuShortcut(key: "v", modifiers: .command),
            MenuShortcut(key: "a", modifiers: .command), MenuShortcut(key: "q", modifiers: .command), MenuShortcut(key: "h", modifiers: .command),
            MenuShortcut(key: "m", modifiers: .command),
        ]
        XCTAssertTrue(Set(used).isDisjoint(with: Set(system)))
    }

    func testPlainKeyItemsHaveNoAccelerator() {
        // S / Delete / Space / Home / ← / → は KeyRouter が受ける(登録すると入力欄で打てなくなる)
        let s = state()
        for c in [MenuCommand.split, .delete, .playPause, .toStart, .stepBack, .stepForward] {
            let spec = (AppMenuSpec.editSelection(s) + AppMenuSpec.playback(s)).first { $0.command == c }
            XCTAssertNotNil(spec)
            XCTAssertNil(spec?.shortcut, "\(c) にショートカットがあります")
        }
        // 通常キー(修飾キー無し)のショートカットは 1 つも無い
        XCTAssertTrue(AppMenuSpec.all(s).compactMap(\.shortcut).allSatisfy { !$0.modifiers.isEmpty })
    }

    func testShortcutDisplay() {
        XCTAssertEqual(MenuShortcut(key: "t", modifiers: [.command, .shift]).display, "⇧⌘T")
        XCTAssertEqual(MenuShortcut(key: .return, modifiers: .command).display, "⌘⏎")
        XCTAssertEqual(MenuShortcut(key: "f", modifiers: [.command, .control]).display, "⌃⌘F")
    }

    // MARK: 有効 / 無効

    func testNoDocumentDisablesEverythingButAboutAndHelp() {
        let s = MenuState()
        XCTAssertFalse(s.hasDocument)
        for spec in AppMenuSpec.all(s) {
            switch spec.command {
            case .about, .helpVoicevox, .helpAquestalk, .helpLicense, .helpThirdParty: XCTAssertTrue(spec.enabled, "\(spec.title)")
            default: XCTAssertFalse(spec.enabled, "\(spec.title) が有効です")
            }
        }
    }

    func testEmptyDocumentEnablesAddItemsButNotSelectionOnes() {
        let s = state { $0.canExport = false }
        XCTAssertTrue(AppMenuSpec.settings(s).enabled)
        XCTAssertTrue(item(AppMenuSpec.file(s), .addMedia)!.enabled)
        XCTAssertFalse(item(AppMenuSpec.file(s), .export)!.enabled, "中身が無いと書き出せない")
        XCTAssertFalse(item(AppMenuSpec.editSelection(s), .split)!.enabled)
        XCTAssertFalse(item(AppMenuSpec.editSelection(s), .delete)!.enabled)
        XCTAssertTrue(AppMenuSpec.editAdd(s).allSatisfy(\.enabled))
        XCTAssertTrue(AppMenuSpec.playback(s).allSatisfy(\.enabled))
    }

    func testSelectionEnablesDeleteAndSplitNeedsPlayheadInside() {
        var s = state { $0.hasSelection = true }
        XCTAssertTrue(item(AppMenuSpec.editSelection(s), .delete)!.enabled)
        XCTAssertFalse(item(AppMenuSpec.editSelection(s), .split)!.enabled, "再生ヘッドがクリップの外")
        s.canSplit = true
        XCTAssertTrue(item(AppMenuSpec.editSelection(s), .split)!.enabled)
    }

    func testEverythingWithADocumentIsDisabledWhileLocked() {
        let s = state { $0.isLocked = true; $0.hasSelection = true; $0.canSplit = true }
        for spec in AppMenuSpec.all(s) {
            switch spec.command {
            case .about, .helpVoicevox, .helpAquestalk, .helpLicense, .helpThirdParty, .fullScreen: XCTAssertTrue(spec.enabled, "\(spec.title)")
            default: XCTAssertFalse(spec.enabled, "\(spec.title) が書き出し中も有効です")
            }
        }
    }

    func testMenuStateFromModelFollowsSelectionAndExport() {
        let m = makeModel()
        XCTAssertEqual(MenuState(model: nil), MenuState())
        var s = MenuState(model: m)
        XCTAssertTrue(s.hasDocument); XCTAssertFalse(s.canExport); XCTAssertFalse(s.hasSelection)
        let id = m.addTextClip()
        XCTAssertNotNil(id)
        m.currentTime = 1
        s = MenuState(model: m)
        XCTAssertTrue(s.canExport); XCTAssertTrue(s.hasSelection); XCTAssertTrue(s.canSplit)
        m.isExporting = true
        s = MenuState(model: m)
        XCTAssertTrue(s.isLocked); XCTAssertFalse(s.canExport)
        XCTAssertFalse(s.canEdit)
    }

    // MARK: ラジオ(✓)

    func testResolutionRadioChecksCurrentPreset() {
        for (key, _) in ResolutionPresets.items {
            let list = AppMenuSpec.resolutions(state { $0.resolutionKey = key })
            XCTAssertEqual(list.count, ResolutionPresets.items.count)
            XCTAssertEqual(list.filter { $0.checked == true }.map(\.command), [.resolution(key)])
        }
    }

    func testCustomResolutionGetsAnExtraCheckedEntry() {
        let list = AppMenuSpec.resolutions(state { $0.resolutionKey = "1234x567" })
        XCTAssertEqual(list.count, ResolutionPresets.items.count + 1)
        XCTAssertEqual(list.last?.title, "1234×567")
        XCTAssertEqual(list.last?.command, .resolution("1234x567"))
        XCTAssertEqual(list.filter { $0.checked == true }.count, 1)
        XCTAssertEqual(list.last?.checked, true)
    }

    func testCodecAndBackgroundRadios() {
        XCTAssertEqual(AppMenuSpec.codecItems(state { $0.codec = "hevc" }).map(\.checked), [false, true])
        XCTAssertEqual(AppMenuSpec.codecItems(state { $0.codec = "h264" }).map(\.checked), [true, false])
        XCTAssertEqual(AppMenuSpec.backgroundItems(state { $0.bg = "#FFFFFF" }).map(\.checked), [false, true, false], "大文字小文字は区別しない")
        XCTAssertEqual(AppMenuSpec.backgroundItems(state { $0.bg = "#00b140" }).map(\.checked), [false, false, true])
        XCTAssertEqual(AppMenuSpec.backgroundItems(state { $0.bg = "#123456" }).map(\.checked), [false, false, false], "自由な色はどれにも付かない")
    }

    // MARK: メニューの操作がモデルの関数に届く

    func testPerformReachesModelFunctions() {
        let m = makeModel()
        AppMenu.perform(.resolution("1080x1920"), model: m)
        XCTAssertEqual(m.resolutionKey, "1080x1920")
        AppMenu.perform(.background("#ffffff"), model: m)
        XCTAssertEqual(m.project.bg, "#ffffff")
        AppMenu.perform(.codec("hevc"), model: m)
        XCTAssertEqual(m.project.codec, "hevc")
        AppMenu.perform(.addText, model: m)
        AppMenu.perform(.addBlur, model: m)
        XCTAssertEqual(m.project.allClips.count, 2)
        let chars = m.project.characters.count
        AppMenu.perform(.addCharacter, model: m)
        XCTAssertEqual(m.project.characters.count, chars + 1)
        AppMenu.perform(.resolution(ResolutionPresets.customKey), model: m)
        XCTAssertTrue(m.showSettings)
        m.showSettings = false
        AppMenu.perform(.settings, model: m)
        XCTAssertTrue(m.showSettings)
        AppMenu.perform(.toggleSecondScreen, model: nil)   // ドキュメントが無くても落ちない
        AppMenu.perform(.addText, model: nil)
    }

    func testBackgroundAndCodecAreUndoable() {
        let m = makeModel()
        let um = m.effectiveUndoManager
        m.setBackground("#00b140")
        XCTAssertEqual(um.undoActionName, "背景色の変更")
        m.setCodec("hevc")
        um.undo(); XCTAssertEqual(m.project.codec, "h264")
        um.undo(); XCTAssertEqual(m.project.bg, "#000000")
        um.redo(); XCTAssertEqual(m.project.bg, "#00b140")
        m.setCodec("av1")   // 知らない形式は無視
        XCTAssertEqual(m.project.codec, "h264")
    }

    func testMenuDoesNothingWhileLocked() {
        let m = makeModel()
        m.isExporting = true
        AppMenu.perform(.addText, model: m)
        AppMenu.perform(.background("#ffffff"), model: m)
        AppMenu.perform(.codec("hevc"), model: m)
        AppMenu.perform(.settings, model: m)
        XCTAssertTrue(m.project.allClips.isEmpty)
        XCTAssertEqual(m.project.bg, "#000000")
        XCTAssertEqual(m.project.codec, "h264")
        XCTAssertFalse(m.showSettings)
    }

    func testSplitAndDeleteThroughMenu() {
        let m = makeModel()
        AppMenu.perform(.addText, model: m)
        m.currentTime = 1
        AppMenu.perform(.split, model: m)
        XCTAssertEqual(m.project.allClips.count, 2)
        AppMenu.perform(.delete, model: m)
        XCTAssertEqual(m.project.allClips.count, 1)
    }

    func testZoomClampsAndSteps() {
        let m = makeModel()
        let p0 = m.pps
        AppMenu.perform(.zoomIn, model: m)
        XCTAssertEqual(m.pps, p0 * AppMenu.zoomStep, accuracy: 1e-9)
        AppMenu.perform(.zoomOut, model: m)
        XCTAssertEqual(m.pps, p0, accuracy: 1e-9)
        for _ in 0..<60 { AppMenu.perform(.zoomIn, model: m) }
        XCTAssertEqual(m.pps, TimelineLayout.maxPps)
        for _ in 0..<80 { AppMenu.perform(.zoomOut, model: m) }
        XCTAssertEqual(m.pps, TimelineLayout.minPps)
    }

    func testMakeVoicesFromScriptUsesScriptField() async {
        let m = makeModel()
        await m.generateVoicesFromScript()
        XCTAssertTrue(m.project.allClips.isEmpty)
        XCTAssertEqual(m.statusText, "左の台本欄にセリフを書いてください")
        m.scriptText = "霊夢: こんにちは\nずんだもん: やあ"
        await m.generateVoicesFromScript()
        XCTAssertEqual(m.project.allClips.filter { $0.type == .voice }.count, 2)
    }

    func testCommandEqualsKeyDetection() {
        XCTAssertTrue(KeyRouter.isCommandEquals(modifiers: .command, charactersIgnoringModifiers: "="))
        XCTAssertTrue(KeyRouter.isCommandEquals(modifiers: [.command, .shift], charactersIgnoringModifiers: "=", characters: "+"))
        XCTAssertTrue(KeyRouter.isCommandEquals(modifiers: [.command, .shift], charactersIgnoringModifiers: ";", characters: "+"))
        XCTAssertFalse(KeyRouter.isCommandEquals(modifiers: [], charactersIgnoringModifiers: "="))
        XCTAssertFalse(KeyRouter.isCommandEquals(modifiers: [.command, .option], charactersIgnoringModifiers: "="))
        XCTAssertFalse(KeyRouter.isCommandEquals(modifiers: .command, charactersIgnoringModifiers: "-"))
    }

    // MARK: 前面のドキュメント

    func testActiveDocumentTracksFrontModelState() async {
        let a = ActiveDocument()
        XCTAssertFalse(a.state.hasDocument)
        let m = makeModel()
        a.activate(m)
        XCTAssertTrue(a.state.hasDocument)
        XCTAssertEqual(a.state.codec, "h264")
        m.setCodec("hevc")
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(a.state.codec, "hevc")
        let other = makeModel()
        a.deactivate(other)             // 前面でないものを外しても変わらない
        XCTAssertTrue(a.state.hasDocument)
        a.deactivate(m)
        XCTAssertFalse(a.state.hasDocument)
        XCTAssertNil(a.model)
    }

    // MARK: 依存バナー

    private func status(vv: Bool = true, running: Bool = false, aq: Bool = true) -> DependencyStatus {
        DependencyStatus(voicevoxInstalled: vv, voicevoxRunning: running, aquestalkPlayerInstalled: aq)
    }

    func testBannerContentLogic() {
        XCTAssertNil(DependencyBannerContent.make(from: status()))
        let vv = DependencyBannerContent.make(from: status(vv: false))
        XCTAssertEqual(vv?.links, [.init(title: "VOICEVOX を入手", url: "https://voicevox.hiroshiba.jp/")])
        XCTAssertEqual(vv?.messages.count, 1)
        XCTAssertTrue(vv?.messages[0].contains("VOICEVOX が見つかりません") ?? false)
        let aq = DependencyBannerContent.make(from: status(aq: false))
        XCTAssertEqual(aq?.links, [.init(title: "AquesTalkPlayer を入手", url: "https://www.a-quest.com/products/aquestalkplayer.html")])
        let both = DependencyBannerContent.make(from: status(vv: false, aq: false))
        XCTAssertEqual(both?.links.count, 2)
        XCTAssertEqual(both?.messages.count, 2)
        // VOICEVOX が入っていなくても、別の場所で動いていれば案内しない
        XCTAssertNil(DependencyBannerContent.make(from: status(vv: false, running: true)))
        // ffmpeg の案内は無い
        XCTAssertFalse((both?.messages.joined() ?? "").lowercased().contains("ffmpeg"))
    }

    func testBannerShowsOnceAndStaysDismissed() async {
        var current = status(vv: false)
        let center = DependencyNoticeCenter(checker: { _ in current })
        XCTAssertNil(center.content)
        await center.refresh(project: .new())
        XCTAssertNotNil(center.content)
        XCTAssertEqual(center.checkCount, 1)
        center.dismiss()
        XCTAssertNil(center.content)
        XCTAssertTrue(center.dismissedThisSession)
        await center.refresh(project: .new())          // 別のウィンドウが開いても出さない
        XCTAssertNil(center.content)
        XCTAssertEqual(center.checkCount, 1, "閉じたあとは確認すらしない")
        current = status()
    }

    func testBannerClearsWhenDependencyAppears() async {
        var current = status(vv: false)
        let center = DependencyNoticeCenter(checker: { _ in current })
        await center.refresh(project: .new())
        XCTAssertNotNil(center.content)
        current = status()
        await center.refresh(project: .new())
        XCTAssertNil(center.content)
    }

    func testDebugCheckerFromEnvironmentOnlyWhenSet() async {
        // 環境変数が無ければ nil(本物のチェックを使う)
        if ProcessInfo.processInfo.environment["YE_DEBUG_DEPS"] == nil { XCTAssertNil(DependencyNoticeCenter.debugChecker()) }
    }

    // MARK: Kyoko の代用の知らせ

    private final class FakeKyokoProvider: VoiceProvider, VoiceFallbackReporting {
        let inner = ToneVoiceProvider()
        var didUseFallback = true
        func synthesize(character: YukkuriCore.Character, text: String, in directory: URL) async throws -> VoiceResult {
            try await inner.synthesize(character: character, text: text, in: directory)
        }
    }

    func testKyokoWarningIsShownOnlyOncePerSession() async {
        let m = makeModel()
        m.voiceProviderFactory = { _ in FakeKyokoProvider() }
        await m.generateVoices(from: "霊夢: こんにちは")
        XCTAssertEqual(m.errorMessage, "AquesTalkPlayer が見つからないので、macOS の Kyoko で代わりに読み上げます。")
        XCTAssertEqual(m.errorTitle, "ゆっくり音声について")
        m.errorMessage = nil
        await m.generateVoices(from: "霊夢: もう一度")
        XCTAssertNil(m.errorMessage, "2 回目は出さない")
        // 試し読み上げも同じ入れ物を使うので出ない
        m.playTestAudio = { _ in }
        let id = m.project.characters[0].id
        _ = await m.testSpeak(charId: id)
        XCTAssertNil(m.errorMessage)
    }

    func testKyokoWarningFromTestSpeakAndNotWhenNotUsed() async {
        let m = makeModel()
        m.playTestAudio = { _ in }
        let id = m.project.characters[0].id
        _ = await m.testSpeak(charId: id)
        XCTAssertNil(m.errorMessage, "代用していなければ出さない")
        let p = FakeKyokoProvider()
        m.voiceProviderFactory = { _ in p }
        _ = await m.testSpeak(charId: id)
        XCTAssertEqual(m.errorMessage, ProjectModel.kyokoWarning)
    }

    // MARK: Dock

    private final class FakeTile: DockTiling {
        var contentView: NSView?
        var size = NSSize(width: 128, height: 128)
        var displayCount = 0
        func display() { displayCount += 1 }
    }

    func testDockFractionMapping() {
        XCTAssertEqual(DockProgressController.clamp(-1), 0)
        XCTAssertEqual(DockProgressController.clamp(0.25), 0.25)
        XCTAssertEqual(DockProgressController.clamp(7), 1)
        XCTAssertEqual(DockProgressController.clamp(.nan), 0)
        XCTAssertEqual(DockProgressController.clamp(.infinity), 1)
    }

    func testDockShowsProgressAndResets() {
        let tile = FakeTile()
        let dock = DockProgressController(tile: tile)
        XCTAssertNil(dock.fraction)
        dock.update(0.4)
        XCTAssertEqual(dock.fraction, 0.4)
        let view = tile.contentView as? DockProgressView
        XCTAssertNotNil(view)
        XCTAssertEqual(view?.indicator.doubleValue ?? -1, 0.4, accuracy: 1e-9)
        dock.update(2)
        XCTAssertEqual(dock.fraction, 1)
        XCTAssertTrue(tile.contentView === view, "同じ表示を使い回す")
        XCTAssertEqual(view?.indicator.doubleValue, 1)
        dock.reset()
        XCTAssertNil(dock.fraction)
        XCTAssertNil(tile.contentView)
        XCTAssertGreaterThanOrEqual(tile.displayCount, 3)
        dock.update(0.1)                    // 次の書き出しでまた出る
        XCTAssertNotNil(tile.contentView)
    }

    func testDockFinishBouncesOnlyWhenInactive() {
        let tile = FakeTile()
        let dock = DockProgressController(tile: tile)
        var bounces = 0
        dock.requestAttention = { bounces += 1 }
        dock.isAppActive = { true }
        dock.update(0.5); dock.finish(notify: true)
        XCTAssertEqual(bounces, 0); XCTAssertNil(tile.contentView)
        dock.isAppActive = { false }
        dock.update(0.5); dock.finish(notify: true)
        XCTAssertEqual(bounces, 1)
        dock.update(0.5); dock.finish(notify: false)    // キャンセルでは鳴らさない
        XCTAssertEqual(bounces, 1)
        XCTAssertNil(dock.fraction)
    }

    func testExportDrivesDockProgressAndBounce() async {
        let m = makeModel()
        let tile = FakeTile()
        let dock = DockProgressController(tile: tile)
        var bounces = 0
        var seen: [Double] = []
        dock.isAppActive = { false }
        dock.requestAttention = { bounces += 1 }
        m.dockOverride = dock
        m.applyVideoSize(320, 180)
        await m.generateVoices(from: "霊夢: こんにちは")
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("ye-dock-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: out) }
        let t = Task { @MainActor in
            while m.isExporting == false && !Task.isCancelled { try? await Task.sleep(nanoseconds: 1_000_000) }
            while m.isExporting && !Task.isCancelled {
                if let f = dock.fraction { seen.append(f) }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        let outcome = await m.runExport(to: out)
        t.cancel()
        guard case .success = outcome else { return XCTFail("export failed: \(outcome)") }
        XCTAssertNil(dock.fraction, "終わったら進行バーを消す")
        XCTAssertNil(tile.contentView)
        XCTAssertEqual(bounces, 1)
        XCTAssertTrue(seen.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    func testDockMenuHasNewAndOpen() {
        let delegate = AppDelegate()   // メニューの target は弱参照なので、持っておく
        let menu = delegate.makeDockMenu()
        XCTAssertEqual(menu.items.map(\.title), ["新規", "開く…"])
        XCTAssertTrue(menu.items.allSatisfy { $0.action != nil && $0.target === delegate })
        withExtendedLifetime(delegate) {}
    }

    // MARK: ヘルプ文書・About

    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("ye-help-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        return d
    }

    func testHelpDocPrefersBundleResources() throws {
        let res = try tempDir()
        let repo = try tempDir()
        try Data("a".utf8).write(to: res.appendingPathComponent("LICENSE.ja.md"))
        try Data("b".utf8).write(to: res.appendingPathComponent("第三者の規約.md"))
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("docs"), withIntermediateDirectories: true)
        try Data("c".utf8).write(to: repo.appendingPathComponent("LICENSE.ja.md"))
        try Data("d".utf8).write(to: repo.appendingPathComponent("docs/第三者の規約.md"))
        XCTAssertEqual(HelpDocs.resolve(.license, resourceDir: res, searchRoots: [repo])?.path, res.appendingPathComponent("LICENSE.ja.md").path)
        XCTAssertEqual(HelpDocs.resolve(.thirdParty, resourceDir: res, searchRoots: [repo])?.path, res.appendingPathComponent("第三者の規約.md").path)
    }

    func testHelpDocFallsBackToRepoWalkingUp() throws {
        let repo = try tempDir()
        let deep = repo.appendingPathComponent("YukkuriEditor/Sources/YukkuriEditor")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("docs"), withIntermediateDirectories: true)
        try Data("c".utf8).write(to: repo.appendingPathComponent("LICENSE.ja.md"))
        try Data("d".utf8).write(to: repo.appendingPathComponent("docs/第三者の規約.md"))
        let emptyRes = try tempDir()
        XCTAssertEqual(HelpDocs.resolve(.license, resourceDir: emptyRes, searchRoots: [deep])?.path, repo.appendingPathComponent("LICENSE.ja.md").path)
        XCTAssertEqual(HelpDocs.resolve(.thirdParty, resourceDir: nil, searchRoots: [deep])?.path, repo.appendingPathComponent("docs/第三者の規約.md").path)
    }

    func testHelpDocMissingReturnsNil() throws {
        let empty = try tempDir()
        XCTAssertNil(HelpDocs.resolve(.license, resourceDir: empty, searchRoots: [empty]))
        XCTAssertNil(HelpDocs.resolve(.thirdParty, resourceDir: nil, searchRoots: [empty], fileExists: { _ in false }))
    }

    func testHelpDocResolvesRealRepoFiles() {
        // SwiftPM から動かしたときの既定の探し方で、本物のリポジトリのファイルが見つかる
        for d in HelpDoc.allCases {
            let u = HelpDocs.resolve(d, resourceDir: nil)
            XCTAssertNotNil(u, d.fileName)
            XCTAssertTrue(u.map { FileManager.default.fileExists(atPath: $0.path) } ?? false)
        }
    }

    func testAboutInfo() {
        XCTAssertEqual(AppInfo.version(info: nil), "0.2.0")
        XCTAssertEqual(AppInfo.version(info: ["CFBundleShortVersionString": "1.2.3"]), "1.2.3")
        let url = URL(fileURLWithPath: "/tmp/LICENSE.ja.md")
        let credits = AppInfo.credits(licenseURL: url)
        XCTAssertTrue(credits.string.contains("VOICEVOX と AquesTalk は同梱していません。利用者がインストールしたものを呼び出します。"))
        var linked = ""
        credits.enumerateAttribute(.link, in: NSRange(location: 0, length: credits.length)) { v, r, _ in
            if v != nil { linked = (credits.string as NSString).substring(with: r) }
        }
        XCTAssertEqual(linked, "ライセンス")
        XCTAssertNil({ () -> Any? in
            var found: Any?
            let c = AppInfo.credits(licenseURL: nil)
            c.enumerateAttribute(.link, in: NSRange(location: 0, length: c.length)) { v, _, _ in if v != nil { found = v } }
            return found
        }())
    }

    func testMakeAppScriptBundlesTheDocsAndDeclaresTheDocumentType() throws {
        // Scripts/make-app.sh が文書を Resources に入れ、.ymproj を関連づけている
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<2 { dir.deleteLastPathComponent() }
        let script = try String(contentsOf: dir.appendingPathComponent("Scripts/make-app.sh"), encoding: .utf8)
        XCTAssertTrue(script.contains("LICENSE.ja.md"))
        XCTAssertTrue(script.contains("第三者の規約.md"))
        XCTAssertTrue(script.contains("CFBundleDocumentTypes"))
        XCTAssertTrue(script.contains("jp.local.yukkuri-editor.project"))
        XCTAssertTrue(script.contains("<string>Editor</string>"))
    }
}
