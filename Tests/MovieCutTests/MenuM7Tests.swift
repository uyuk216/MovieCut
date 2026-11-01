import XCTest
import SwiftUI
import AVFoundation
import MovieCutCore
@testable import MovieCut

/// M7: クリップメニュー・移動メニュー・マーカー・書き出しプリセット(メニューの項目表 → モデルの操作)。
@MainActor
final class MenuM7Tests: XCTestCase {
    private func clip(_ id: String, _ type: ClipType, start: Double, dur: Double, offset: Double = 0, srcDur: Double? = nil) -> Clip {
        var c = Clip()
        c.id = id; c.type = type; c.start = start; c.duration = dur; c.offset = offset; c.srcDuration = srcDur
        return c
    }

    /// T0: a(2〜4 動画 offset 1) b(4〜6 画像) c(8〜10 文字) / T1: d(5〜6 音声) v(0〜1.5 ボイス) / T2〜T4: 空
    private func makeModel() -> ProjectModel {
        var p = Project.new()
        p.tracks[0].clips = [clip("a", .video, start: 2, dur: 2, offset: 1, srcDur: 10), clip("b", .image, start: 4, dur: 2), clip("c", .text, start: 8, dur: 2)]
        var v = clip("v", .voice, start: 0, dur: 1.5, srcDur: 3); v.charId = p.characters[0].id; v.text = "こんにちは"
        p.tracks[1].clips = [v, clip("d", .audio, start: 5, dur: 1, srcDur: 3)]
        let m = ProjectModel(project: p)
        m.voiceProviderFactory = { _ in ToneVoiceProvider() }
        m.notices = OneTimeNotices()
        return m
    }

    private func state(_ configure: (inout MenuState) -> Void = { _ in }) -> MenuState {
        var s = MenuState()
        s.hasDocument = true; s.canExport = true
        s.resolutionKey = "1920x1080"; s.codec = "h264"; s.bg = "#000000"
        configure(&s)
        return s
    }

    private func sc(_ k: KeyEquivalent, _ m: EventModifiers) -> MenuShortcut { MenuShortcut(key: k, modifiers: m) }
    private func item(_ list: [MenuItemSpec], _ c: MenuCommand) -> MenuItemSpec { list.first { $0.command == c }! }

    // MARK: 構成

    func testClipMenuLayoutAndAccelerators() {
        let s = state()
        let groups = AppMenuSpec.clipMenu(s)
        XCTAssertEqual(groups.map { $0.map(\.title) }, [
            ["テキストを追加", "ぼかし範囲を追加", "調整レイヤーを追加", "音声ビジュアライザを追加", "QRコードを追加…"],
            ["クリップを分割", "クリップを複製", "クリップを削除", "すき間を詰めて削除"],
            ["再生位置より前を切り落とす", "再生位置より後ろを切り落とす"],
            ["前のクリップを選択", "次のクリップを選択", "選択クリップを上のレイヤーへ", "選択クリップを下のレイヤーへ"],
            ["レイヤーを追加", "選択クリップの音声を作り直す", "AIでセリフを直す…"],
        ])
        XCTAssertEqual(groups.map { $0.map(\.shortcut) }, [
            [sc("t", [.command, .shift]), sc("b", [.command, .shift]), nil, nil, nil],
            [nil, sc("d", .command), nil, sc(.delete, [.option, .command])],
            [sc("[", [.option, .command]), sc("]", [.option, .command])],
            [sc("[", .command), sc("]", .command), sc("[", [.shift, .command]), sc("]", [.shift, .command])],
            [sc("l", [.command, .shift]), sc("r", [.command, .option]), nil],
        ])
        XCTAssertEqual(groups[1].map(\.hint), ["S", nil, "⌫", nil], "分割・削除は通常キー(KeyRouter)なのでヒントだけ")
    }

    func testMoveMenuLayoutAndAccelerators() {
        let s = state()
        XCTAssertEqual(AppMenuSpec.gotoEnds(s).map(\.title), ["先頭へ", "末尾へ"])
        XCTAssertEqual(AppMenuSpec.gotoEnds(s).map(\.hint), ["Home", "End"])
        XCTAssertEqual(AppMenuSpec.gotoEnds(s).map(\.shortcut), [nil, nil])
        XCTAssertEqual(AppMenuSpec.gotoNeighbours(s).map(\.title), ["前のクリップの境目へ", "次のクリップの境目へ", "前のセリフへ", "次のセリフへ"])
        XCTAssertEqual(AppMenuSpec.gotoNeighbours(s).map(\.shortcut), [sc(.leftArrow, [.option, .command]), sc(.rightArrow, [.option, .command]), sc(.leftArrow, [.control, .command]), sc(.rightArrow, [.control, .command])])
        XCTAssertEqual(AppMenuSpec.gotoTime(s).title, "時間を指定して移動…")
        XCTAssertEqual(AppMenuSpec.gotoTime(s).shortcut, sc("j", .command))
        XCTAssertEqual(AppMenuSpec.markerItems(s).map(\.title), ["マーカーを追加", "マーカーを名前変更…", "前のマーカーへ", "次のマーカーへ", "マーカーを削除", "すべてのマーカーを消去"])
        XCTAssertEqual(AppMenuSpec.markerItems(s).map(\.shortcut), [sc("m", [.control, .command]), nil, sc(.upArrow, [.option, .command]), sc(.downArrow, [.option, .command]), nil, nil])
    }

    func testExportMenuSpec() {
        let s = state()
        XCTAssertEqual(AppMenuSpec.exportCurrent(s).title, "MP4 を書き出す…")
        XCTAssertEqual(AppMenuSpec.exportCurrent(s).shortcut, sc("e", .command))
        XCTAssertEqual(AppMenuSpec.exportPresets(s).map(\.title), ["YouTube 1080p", "YouTube 4K", "ショート縦", "軽量 720p", "音声のみ"])
        XCTAssertTrue(AppMenuSpec.exportPresets(s).allSatisfy { $0.shortcut == nil && $0.enabled })
        XCTAssertEqual(AppMenuSpec.exportPresets(s).first?.displayTitle, "YouTube 1080p  (1920×1080 · H.264)")
    }

    func testPreviewBackgroundMenuSpec() {
        let items = AppMenuSpec.previewBackgroundItems(state())
        XCTAssertEqual(items.map(\.title), ["暗い灰色", "黒", "白", "中間グレー", "緑(クロマキー)", "青"])
        XCTAssertEqual(items.map(\.checked), [true, false, false, false, false, false], "既定は暗い灰色")
        XCTAssertEqual(AppMenuSpec.previewBackgroundItems(state { $0.previewBackground = .green }).map(\.checked), [false, false, false, false, true, false])
        XCTAssertTrue(items.allSatisfy { $0.shortcut == nil })
        // 書類が無くても・書き出し中でも切り替えられる(アプリ全体の見た目)
        XCTAssertTrue(AppMenuSpec.previewBackgroundItems(MenuState()).allSatisfy(\.enabled))
        XCTAssertTrue(AppMenuSpec.previewBackgroundItems(state { $0.isLocked = true }).allSatisfy(\.enabled))
        XCTAssertEqual(items.map(\.command), PreviewBackground.allCases.map { MenuCommand.previewBackground($0) })
    }

    func testShortcutDisplayOfArrowsAndDelete() {
        XCTAssertEqual(sc(.leftArrow, [.option, .command]).display, "⌥⌘←")
        XCTAssertEqual(sc(.upArrow, .option).display, "⌥↑")
        XCTAssertEqual(sc(.delete, .shift).display, "⇧⌫")
        XCTAssertEqual(sc("[", .option).display, "⌥[")
        XCTAssertEqual(sc(.rightArrow, .control).display, "⌃→")
    }

    func testNoDuplicateAcceleratorsAcrossAllMenus() {
        let s = state { $0.markers = [MenuState.MarkerItem(id: "1", time: 1, name: "a")] }
        let used = AppMenuSpec.all(s).compactMap(\.shortcut)
        XCTAssertEqual(used.count, Set(used).count)
        XCTAssertTrue(used.allSatisfy { !$0.modifiers.isEmpty }, "修飾キー無しのショートカットは KeyRouter の担当")
        // 標準メニュー(NSDocument / Window)のキーとぶつけない。⌘D は NSDocument の「複製」ではなくクリップの複製として使う
        let system: [MenuShortcut] = [sc("n", .command), sc("o", .command), sc("w", .command), sc("s", .command), sc("s", [.command, .shift]), sc("m", .command),
                                      sc("q", .command), sc("h", .command), sc("z", .command), sc("z", [.command, .shift])]
        XCTAssertTrue(Set(used).isDisjoint(with: Set(system)))
    }

    // MARK: 有効 / 無効

    func testClipItemEnablement() {
        // 選択なし
        var s = state()
        for c in [MenuCommand.duplicate, .delete, .rippleDelete, .trimBefore, .trimAfter, .moveLayerUp, .moveLayerDown, .regenerateVoice, .split] {
            XCTAssertFalse(AppMenuSpec.clipMenu(s).flatMap { $0 }.first { $0.command == c }!.enabled, "\(c)")
        }
        XCTAssertTrue(item(AppMenuSpec.clipLayerAndVoice(s), .addLayer).enabled)
        // 選択あり・再生位置がクリップの中・真ん中の行
        s = state { $0.hasSelection = true; $0.canTrim = true; $0.canSplit = true; $0.canMoveUp = true; $0.canMoveDown = true; $0.hasPrevClip = true; $0.hasNextClip = true }
        XCTAssertTrue(AppMenuSpec.clipMenu(s).flatMap { $0 }.filter { $0.command != .regenerateVoice && $0.command != .aiRewrite }.allSatisfy(\.enabled))
        XCTAssertFalse(item(AppMenuSpec.clipLayerAndVoice(s), .regenerateVoice).enabled, "ボイス以外では押せない")
        s.isVoiceSelected = true
        XCTAssertTrue(item(AppMenuSpec.clipLayerAndVoice(s), .regenerateVoice).enabled)
        // 端
        s.canMoveUp = false; s.hasNextClip = false
        XCTAssertFalse(item(AppMenuSpec.clipNavigate(s), .moveLayerUp).enabled)
        XCTAssertTrue(item(AppMenuSpec.clipNavigate(s), .moveLayerDown).enabled)
        XCTAssertFalse(item(AppMenuSpec.clipNavigate(s), .nextClip).enabled)
    }

    func testMoveItemEnablementAndMarkerList() {
        var s = state()
        XCTAssertFalse(item(AppMenuSpec.gotoNeighbours(s), .prevEdit).enabled)
        XCTAssertFalse(item(AppMenuSpec.gotoNeighbours(s), .nextLine).enabled)
        XCTAssertTrue(item(AppMenuSpec.markerItems(s), .addMarker).enabled)
        XCTAssertFalse(item(AppMenuSpec.markerItems(s), .renameMarker).enabled)
        XCTAssertFalse(item(AppMenuSpec.markerItems(s), .deleteMarker).enabled)
        XCTAssertFalse(item(AppMenuSpec.markerItems(s), .clearMarkers).enabled)
        XCTAssertTrue(AppMenuSpec.markerList(s).isEmpty)
        s = state { $0.hasPrevEdit = true; $0.hasNextLine = true; $0.markerAtPlayhead = true; $0.hasNextMarker = true
            $0.markers = [MenuState.MarkerItem(id: "m1", time: 83.5, name: "サビ"), MenuState.MarkerItem(id: "m2", time: 2, name: "マーカー2")] }
        XCTAssertTrue(item(AppMenuSpec.gotoNeighbours(s), .prevEdit).enabled)
        XCTAssertFalse(item(AppMenuSpec.markerItems(s), .addMarker).enabled, "同じ場所には足さない")
        XCTAssertTrue(item(AppMenuSpec.markerItems(s), .renameMarker).enabled)
        XCTAssertTrue(item(AppMenuSpec.markerItems(s), .deleteMarker).enabled)
        XCTAssertTrue(item(AppMenuSpec.markerItems(s), .nextMarker).enabled)
        XCTAssertFalse(item(AppMenuSpec.markerItems(s), .prevMarker).enabled)
        XCTAssertEqual(AppMenuSpec.markerList(s).map(\.title), ["01:23.50  サビ", "00:02.00  マーカー2"], "一覧は時刻と名前")
        XCTAssertEqual(AppMenuSpec.markerList(s).map(\.command), [.jumpToMarker("m1"), .jumpToMarker("m2")])
    }

    func testEverythingNewIsDisabledWithoutDocumentOrWhileLocked() {
        let marker = [MenuState.MarkerItem(id: "m", time: 1, name: "x")]
        let none = MenuState()
        var locked = state { $0.isLocked = true; $0.hasSelection = true; $0.canTrim = true; $0.hasNextMarker = true; $0.markerAtPlayhead = true; $0.markers = marker }
        locked.canMoveUp = true; locked.hasNextEdit = true
        for spec in AppMenuSpec.clipMenu(none).flatMap({ $0 }) + AppMenuSpec.gotoEnds(none) + AppMenuSpec.gotoNeighbours(none) + [AppMenuSpec.gotoTime(none)] + AppMenuSpec.markerItems(none) + AppMenuSpec.exportPresets(none) {
            XCTAssertFalse(spec.enabled, "書類なし: \(spec.title)")
        }
        for spec in AppMenuSpec.clipMenu(locked).flatMap({ $0 }) + AppMenuSpec.gotoEnds(locked) + AppMenuSpec.gotoNeighbours(locked) + [AppMenuSpec.gotoTime(locked)]
            + AppMenuSpec.markerItems(locked) + AppMenuSpec.markerList(locked) + AppMenuSpec.exportPresets(locked) {
            XCTAssertFalse(spec.enabled, "書き出し中: \(spec.title)")
        }
    }

    func testMenuStateFromModelFollowsSelectionPlayheadAndMarkers() {
        let m = makeModel()
        m.selectedClipId = "b"            // T0 の画像(4〜6)
        m.currentTime = 5
        var s = MenuState(model: m)
        XCTAssertTrue(s.canTrim); XCTAssertFalse(s.isVoiceSelected)
        XCTAssertFalse(s.canMoveUp, "一番上の行"); XCTAssertTrue(s.canMoveDown)
        XCTAssertTrue(s.hasPrevClip); XCTAssertTrue(s.hasNextClip)
        XCTAssertTrue(s.hasPrevEdit); XCTAssertTrue(s.hasNextEdit)
        XCTAssertTrue(s.hasPrevLine, "ボイスの頭は 0 だけ → 5 より前に在る")
        XCTAssertFalse(s.hasNextLine)
        m.currentTime = 4                  // b の頭: 端なので切り落とせない
        XCTAssertFalse(MenuState(model: m).canTrim)
        m.selectedClipId = "v"
        s = MenuState(model: m)
        XCTAssertTrue(s.isVoiceSelected)
        XCTAssertTrue(s.canMoveUp); XCTAssertTrue(s.canMoveDown)
        m.currentTime = 0
        s = MenuState(model: m)
        XCTAssertFalse(s.hasPrevEdit); XCTAssertTrue(s.hasNextEdit)
        XCTAssertFalse(s.hasPrevLine); XCTAssertFalse(s.hasNextLine)
        m.currentTime = 3
        m.addMarkerAtPlayhead()
        s = MenuState(model: m)
        XCTAssertTrue(s.markerAtPlayhead); XCTAssertEqual(s.markers.map(\.name), ["マーカー1"])
        XCTAssertFalse(s.hasPrevMarker); XCTAssertFalse(s.hasNextMarker)
        m.currentTime = 3 + 0.5 / 60       // 1 コマの半分ずれていても「そこ」
        XCTAssertTrue(MenuState(model: m).markerAtPlayhead)
        m.currentTime = 3.2
        s = MenuState(model: m)
        XCTAssertFalse(s.markerAtPlayhead); XCTAssertTrue(s.hasPrevMarker)
    }

    func testPlainKeysEndStaysInKeyRouter() {
        XCTAssertEqual(KeyRouter.keyMap[119], .toEnd)
        XCTAssertEqual(KeyRouter.keyMap[115], .toStart)
        let m = makeModel()
        m.installKeyboard()
        defer { m.shutdown() }
        m.currentTime = 1
        XCTAssertTrue(m.keyRouter.dispatch(keyCode: 119, modifiers: [], firstResponder: nil))
        XCTAssertEqual(m.currentTime, m.project.endTime)
        XCTAssertFalse(m.keyRouter.dispatch(keyCode: 119, modifiers: [], firstResponder: NSTextView()), "入力欄では End を奪わない")
        XCTAssertFalse(m.keyRouter.dispatch(keyCode: 119, modifiers: .option, firstResponder: nil))
    }

    // MARK: クリップの操作(それぞれ 1 回の Undo)

    func testDuplicateThroughMenuIsOneUndoStepAndSelectsTheCopy() {
        let m = makeModel()
        let um = m.effectiveUndoManager
        m.selectedClipId = "c"
        let n = m.project.allClips.count
        AppMenu.perform(.duplicate, model: m)
        XCTAssertEqual(m.project.allClips.count, n + 1)
        XCTAssertNotEqual(m.selectedClipId, "c"); XCTAssertNotNil(m.selectedClip)
        XCTAssertEqual(m.selectedClip?.start ?? 0, 10, accuracy: 1e-9)
        XCTAssertEqual(um.undoActionName, "クリップの複製")
        um.undo()
        XCTAssertEqual(m.project.allClips.count, n)
        XCTAssertNil(m.selectedClip, "Undo でコピーが消えたら選択も外れる")
        XCTAssertFalse(um.canUndo, "複製は 1 回の Undo")
        um.redo()
        XCTAssertEqual(m.project.allClips.count, n + 1)
    }

    func testTrimBeforeAndAfterThroughMenu() {
        let m = makeModel()
        let um = m.effectiveUndoManager
        m.selectedClipId = "a"
        m.currentTime = 3
        AppMenu.perform(.trimBefore, model: m)
        XCTAssertEqual(m.selectedClip?.start, 3); XCTAssertEqual(m.selectedClip?.duration, 1); XCTAssertEqual(m.selectedClip?.offset, 2)
        XCTAssertEqual(um.undoActionName, "再生位置より前を切り落とす")
        um.undo()
        XCTAssertEqual(m.selectedClip?.start, 2); XCTAssertEqual(m.selectedClip?.offset, 1)
        AppMenu.perform(.trimAfter, model: m)
        XCTAssertEqual(m.selectedClip?.duration, 1); XCTAssertEqual(m.selectedClip?.start, 2)
        um.undo()
        XCTAssertFalse(um.canUndo)
        m.currentTime = 2            // 端 → 何もしない
        AppMenu.perform(.trimBefore, model: m); AppMenu.perform(.trimAfter, model: m)
        XCTAssertFalse(um.canUndo)
        m.currentTime = 3
        m.isExporting = true
        AppMenu.perform(.trimBefore, model: m)
        XCTAssertEqual(m.selectedClip?.start, 2, "書き出し中は動かない")
    }

    func testRippleDeleteThroughMenu() {
        let m = makeModel()
        let um = m.effectiveUndoManager
        m.selectedClipId = "b"
        AppMenu.perform(.rippleDelete, model: m)
        XCTAssertNil(m.selectedClipId)
        XCTAssertEqual(m.project.allClips.first { $0.id == "c" }?.start, 6)
        XCTAssertEqual(m.project.allClips.first { $0.id == "d" }?.start, 5, "ほかのレイヤーは詰めない")
        XCTAssertEqual(um.undoActionName, "すき間を詰めて削除")
        um.undo()
        XCTAssertEqual(m.project.allClips.first { $0.id == "c" }?.start, 8)
        XCTAssertNotNil(m.project.allClips.first { $0.id == "b" })
        XCTAssertFalse(um.canUndo)
    }

    func testSelectPreviousAndNextClipByStartTime() {
        let m = makeModel()     // 開始順: v(0) a(2) b(4) d(5) c(8)
        m.selectedClipId = "b"
        AppMenu.perform(.nextClip, model: m);  XCTAssertEqual(m.selectedClipId, "d")
        AppMenu.perform(.nextClip, model: m);  XCTAssertEqual(m.selectedClipId, "c")
        AppMenu.perform(.nextClip, model: m);  XCTAssertEqual(m.selectedClipId, "c", "最後で止まる")
        AppMenu.perform(.prevClip, model: m);  XCTAssertEqual(m.selectedClipId, "d")
        m.selectedClipId = "v"
        AppMenu.perform(.prevClip, model: m);  XCTAssertEqual(m.selectedClipId, "v")
        XCTAssertFalse(m.effectiveUndoManager.canUndo, "選択は Undo に積まない")
    }

    func testMoveLayerThroughMenu() {
        let m = makeModel()
        let um = m.effectiveUndoManager
        m.selectedClipId = "b"
        AppMenu.perform(.moveLayerUp, model: m)
        XCTAssertEqual(ClipEditing.locate("b", in: m.project)?.track, 0, "一番上の行では動かない")
        XCTAssertFalse(um.canUndo)
        AppMenu.perform(.moveLayerDown, model: m)
        XCTAssertEqual(ClipEditing.locate("b", in: m.project)?.track, 1)
        XCTAssertEqual(m.selectedClip?.start, 4)
        XCTAssertEqual(m.project.tracks.count, 5, "レイヤーは増えない")
        AppMenu.perform(.moveLayerUp, model: m)
        XCTAssertEqual(ClipEditing.locate("b", in: m.project)?.track, 0)
        for _ in 0..<2 { um.undo() }
        XCTAssertFalse(um.canUndo)
        m.selectedClipId = "c"
        for _ in 0..<9 { AppMenu.perform(.moveLayerDown, model: m) }
        XCTAssertEqual(ClipEditing.locate("c", in: m.project)?.track, 4, "一番下の行で止まる")
    }

    func testAddLayerAndRegenerateVoiceThroughMenu() async throws {
        let m = makeModel()
        let n = m.project.tracks.count
        AppMenu.perform(.addLayer, model: m)
        XCTAssertEqual(m.project.tracks.count, n + 1)
        m.selectedClipId = "b"
        let before = m.project
        await m.regenerateSelectedVoice()
        XCTAssertEqual(m.project, before, "ボイスでなければ何もしない")
        m.selectedClipId = "v"
        let src0 = m.selectedClip?.src
        await m.regenerateSelectedVoice()
        XCTAssertNotEqual(m.selectedClip?.src, src0, "音声を作り直した")
        XCTAssertEqual(m.effectiveUndoManager.undoActionName, "音声の作り直し")
    }

    // MARK: 移動

    func testGotoMenuItems() {
        let m = makeModel()
        m.currentTime = 4.5
        AppMenu.perform(.goEnd, model: m);   XCTAssertEqual(m.currentTime, 10)
        AppMenu.perform(.goStart, model: m); XCTAssertEqual(m.currentTime, 0)
        // 境目: 0, 1.5, 2, 4, 5, 6, 8, 10
        m.currentTime = 4.5
        AppMenu.perform(.nextEdit, model: m);  XCTAssertEqual(m.currentTime, 5)
        AppMenu.perform(.nextEdit, model: m);  XCTAssertEqual(m.currentTime, 6)
        AppMenu.perform(.prevEdit, model: m);  XCTAssertEqual(m.currentTime, 5)
        m.currentTime = 10
        AppMenu.perform(.nextEdit, model: m);  XCTAssertEqual(m.currentTime, 10, "終わりでは動かない")
        m.currentTime = 0
        AppMenu.perform(.prevEdit, model: m);  XCTAssertEqual(m.currentTime, 0)
        XCTAssertFalse(m.effectiveUndoManager.canUndo, "移動は Undo に積まない")
    }

    func testVoiceLineJump() {
        let m = makeModel()
        var v2 = ClipEditing.makeTextClip(at: 0, project: m.project); v2.type = .voice; v2.id = "v2"; v2.start = 6; v2.duration = 1
        m.edit("x") { $0.tracks[2].clips.append(v2) }
        m.currentTime = 3
        AppMenu.perform(.nextLine, model: m); XCTAssertEqual(m.currentTime, 6)
        AppMenu.perform(.nextLine, model: m); XCTAssertEqual(m.currentTime, 6, "最後のセリフの先では動かない")
        AppMenu.perform(.prevLine, model: m); XCTAssertEqual(m.currentTime, 0)
        AppMenu.perform(.prevLine, model: m); XCTAssertEqual(m.currentTime, 0)
    }

    func testJumpToTimeSheetFlow() {
        let m = makeModel()      // 終わり 10 秒
        AppMenu.perform(.jumpToTime, model: m)
        XCTAssertTrue(m.showJumpSheet)
        XCTAssertFalse(m.commitJump("あいう"), "読めなければ決定しない")
        XCTAssertTrue(m.showJumpSheet, "シートは開いたまま")
        XCTAssertEqual(m.currentTime, 0)
        XCTAssertTrue(m.commitJump("1:23.5"))     // 83.5 → 末尾 10 に収まる
        XCTAssertEqual(m.currentTime, 10)
        XCTAssertFalse(m.showJumpSheet)
        for (text, want) in [("7.25", 7.25), ("0:03", 3), ("00:00:04.50", 4.5), ("9999", 10), ("0", 0)] {
            m.showJumpSheet = true
            XCTAssertTrue(m.commitJump(text), text)
            XCTAssertEqual(m.currentTime, want, accuracy: 1e-9, text)
        }
        m.isExporting = true
        m.showJumpSheet = false
        AppMenu.perform(.jumpToTime, model: m)
        XCTAssertFalse(m.showJumpSheet, "書き出し中は開かない")
    }

    // MARK: マーカー

    func testMarkerMenuFlowAndUndo() {
        let m = makeModel()
        let um = m.effectiveUndoManager
        m.currentTime = 2
        AppMenu.perform(.addMarker, model: m)
        m.currentTime = 6
        AppMenu.perform(.addMarker, model: m)
        AppMenu.perform(.addMarker, model: m)      // 同じ場所には足さない
        XCTAssertEqual(m.project.markers.map(\.name), ["マーカー1", "マーカー2"])
        XCTAssertEqual(m.project.markers.map(\.time), [2, 6])
        XCTAssertEqual(um.undoActionName, "マーカーの追加")
        // 前後へ
        AppMenu.perform(.prevMarker, model: m); XCTAssertEqual(m.currentTime, 2)
        AppMenu.perform(.nextMarker, model: m); XCTAssertEqual(m.currentTime, 6)
        AppMenu.perform(.nextMarker, model: m); XCTAssertEqual(m.currentTime, 6, "最後で止まる")
        // 名前変更
        AppMenu.perform(.renameMarker, model: m)
        let id = try! XCTUnwrap(m.renamingMarkerId)
        XCTAssertTrue(m.renameMarker(id: id, to: "サビ"))
        m.renamingMarkerId = nil
        XCTAssertEqual(m.project.markers.map(\.name), ["マーカー1", "サビ"])
        // 一覧から移動
        m.currentTime = 0
        AppMenu.perform(.jumpToMarker(m.project.markers[1].id), model: m)
        XCTAssertEqual(m.currentTime, 6)
        // 削除は 1 コマ以内
        m.currentTime = 6 + 0.9 / 60
        AppMenu.perform(.deleteMarker, model: m)
        XCTAssertEqual(m.project.markers.map(\.name), ["マーカー1"])
        m.currentTime = 6 + 5.0 / 60
        AppMenu.perform(.deleteMarker, model: m)
        XCTAssertEqual(m.project.markers.count, 1, "遠いマーカーは消さない")
        AppMenu.perform(.clearMarkers, model: m)
        XCTAssertTrue(m.project.markers.isEmpty)
        XCTAssertEqual(um.undoActionName, "すべてのマーカーを消去")
        um.undo(); XCTAssertEqual(m.project.markers.count, 1)
        um.undo(); XCTAssertEqual(m.project.markers.count, 2, "削除の Undo")
        um.undo(); XCTAssertEqual(m.project.markers.map(\.name), ["マーカー1", "マーカー2"], "名前変更の Undo")
    }

    func testMarkersDoNotAffectDocumentLengthOrExportOnlyHistory() {
        let m = makeModel()
        let end = m.project.endTime
        m.currentTime = 99
        m.addMarkerAtPlayhead()
        XCTAssertEqual(m.project.endTime, end)
        XCTAssertTrue(m.canExport)
    }

    // MARK: タイムラインの旗(クリックで移動・ドラッグで動かす)

    func testRulerFlagClickJumpsAndDragMovesInOneUndoStep() {
        let m = makeModel()
        m.pps = 40
        m.edit("m") { $0.markers = [Marker(time: 3, name: "A"), Marker(time: 8, name: "B")] }
        let um = m.effectiveUndoManager
        let canvas = TimelineCanvas(frame: NSRect(x: 0, y: 0, width: 1000, height: 300))
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = canvas
        canvas.model = m
        canvas.syncFromModel()
        defer { m.shutdown(); window.contentView = nil }
        func x(_ t: Double) -> CGFloat { canvas.geometry.x(forTime: t) }
        let ry: CGFloat = 8
        XCTAssertEqual(canvas.markerHit(at: NSPoint(x: x(3) + 2, y: ry))?.name, "A")
        XCTAssertEqual(canvas.markerHit(at: NSPoint(x: x(8) + 6, y: ry))?.name, "B")
        XCTAssertNil(canvas.markerHit(at: NSPoint(x: x(5), y: ry)))
        XCTAssertNil(canvas.markerHit(at: NSPoint(x: x(3) + 2, y: 30)), "行の上では旗に反応しない")
        // クリック: その時刻へ
        m.currentTime = 0
        canvas.mouseDown(at: NSPoint(x: x(8) + 2, y: ry)); canvas.mouseUp()
        XCTAssertEqual(m.currentTime, 8)
        XCTAssertEqual(um.undoActionName, "m", "クリックは Undo に積まない(いちばん上は準備で入れた編集)")
        // ドラッグ: 3 → 5.5
        canvas.mouseDown(at: NSPoint(x: x(3) + 2, y: ry))
        for i in 1...5 { canvas.mouseDragged(to: NSPoint(x: x(3) + 2 + CGFloat(i) * 20, y: ry)) }
        canvas.mouseUp()
        XCTAssertEqual(m.project.markers.map(\.name), ["A", "B"])
        XCTAssertEqual(m.project.markers[0].time, 3 + 100.0 / 40, accuracy: 1e-6)
        XCTAssertEqual(um.undoActionName, "マーカーの移動")
        um.undo()
        XCTAssertEqual(m.project.markers[0].time, 3, "1 回の Undo で元の位置")
        XCTAssertEqual(um.undoActionName, "m")
        // 越えて動かすと時刻順に並べ直される(id は変わらない)
        let aId = m.project.markers[0].id
        um.redo()
        canvas.mouseDown(at: NSPoint(x: x(m.project.markers[0].time) + 2, y: ry))
        for i in 1...8 { canvas.mouseDragged(to: NSPoint(x: x(5.5) + 2 + CGFloat(i) * 25, y: ry)) }
        canvas.mouseUp()
        XCTAssertEqual(m.project.markers.last?.id, aId)
        // 名前の描画幅: 近すぎて入らないときは出さない
        XCTAssertNotNil(canvas.flagLabelWidth(Marker(time: 1, name: "ながい名前"), next: nil))
        XCTAssertNil(canvas.flagLabelWidth(Marker(time: 1, name: "ながい名前"), next: Marker(time: 1.1, name: "x")))
        XCTAssertNil(canvas.flagLabelWidth(Marker(time: 1, name: ""), next: nil))
    }

    // MARK: 書き出しプリセット

    private func exportableModel(_ tmp: URL) throws -> ProjectModel {
        let wav = tmp.appendingPathComponent("tone.wav")
        try ToneVoiceProvider.writeTone(to: wav, duration: 1.0, frequency: 330)
        var p = Project.new()
        p.width = 640; p.height = 360; p.fps = 24
        var t = Clip(); t.type = .text; t.text = "字幕"; t.start = 0; t.duration = 1.2; t.fontSize = 40
        var v = Clip(); v.type = .voice; v.src = wav.path; v.start = 0; v.duration = 1.2; v.charId = p.characters[0].id; v.text = "ぴー"
        p.tracks[4].clips = [t]; p.tracks[0].clips = [v]
        let m = ProjectModel(project: p)
        m.dockOverride = DockProgressController(tile: nil)
        return m
    }

    func testPresetExportThroughModelDoesNotTouchTheDocument() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("m7-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let m = try exportableModel(tmp)
        let before = m.project
        let out = tmp.appendingPathComponent("x-youtube1080.mp4")
        guard case .success = await m.runExport(to: out, preset: .youtube1080) else { return XCTFail("書き出せなかった: \(m.errorMessage ?? "")") }
        XCTAssertEqual(m.project, before, "ドキュメントは変わらない")
        XCTAssertFalse(m.effectiveUndoManager.canUndo)
        let asset = AVURLAsset(url: out)
        let vts = try await asset.loadTracks(withMediaType: .video)
        let vt = try XCTUnwrap(vts.first)
        let size = try await vt.load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 1920, height: 1080))
        let rate = try await vt.load(.nominalFrameRate)
        XCTAssertEqual(rate, 24, accuracy: 0.5, "youtube1080 は fps を変えない")
        XCTAssertEqual(m.exportSuggestedName(preset: .short), "無題-short.mp4")
        XCTAssertEqual(m.exportSuggestedName(preset: .audio), "無題-audio.m4a")
        XCTAssertEqual(m.exportSuggestedName(preset: nil), "無題.mp4")
        m.shutdown()
    }

    func testAudioOnlyPresetThroughModelWritesOnlyAnAudioTrack() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("m7-audio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let m = try exportableModel(tmp)
        let before = m.project
        let out = tmp.appendingPathComponent("a.m4a")
        guard case .success = await m.runExport(to: out, preset: .audio) else { return XCTFail("書き出せなかった: \(m.errorMessage ?? "")") }
        XCTAssertEqual(m.project, before)
        let asset = AVURLAsset(url: out)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let dur = try await asset.load(.duration).seconds
        XCTAssertTrue(videoTracks.isEmpty)
        XCTAssertEqual(audioTracks.count, 1)
        XCTAssertEqual(dur, 1.2, accuracy: 0.1)
        m.shutdown()
    }

    func testCancelExportCancelsTheRunningExport() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("m7-cancel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let m = try exportableModel(tmp)
        m.edit("long") { $0.tracks[4].clips[0].duration = 20 }     // 4K で 20 秒 = 時間がかかる
        let out = tmp.appendingPathComponent("c.mp4")
        let t = Task { @MainActor in await m.runExport(to: out, preset: .youtube4k) }
        while !m.isExporting { try await Task.sleep(nanoseconds: 5_000_000) }
        m.cancelExport()
        let r = await t.value
        guard case .cancelled = r else { return XCTFail("\(r)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
        m.shutdown()
    }

    func testPerformExportPresetOnLockedModelDoesNothing() {
        let m = makeModel()
        m.isExporting = true
        AppMenu.perform(.exportPreset(.short), model: m)     // 保存パネルを出さない(canExport が false)
        XCTAssertNil(m.window)
    }

    // MARK: シートの見た目(オフスクリーン。`MC_SNAPSHOT_DIR` があれば PNG も書く)

    private func render<V: View>(_ v: V, size: NSSize, name: String) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: v.background(Color(nsColor: .windowBackgroundColor)).preferredColorScheme(.dark))
        host.frame = NSRect(origin: .zero, size: size)
        let w = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: .darkAqua)
        w.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        if let dir = ProcessInfo.processInfo.environment["MC_SNAPSHOT_DIR"] {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
        }
        w.contentView = nil
        return rep
    }

    func testJumpAndRenameSheetsRender() throws {
        let m = makeModel()
        m.currentTime = 4.68
        let rep = try render(JumpToTimeSheet(model: m), size: NSSize(width: 400, height: 170), name: "jump-sheet.png")
        XCTAssertEqual(Int(rep.size.width), 400)
        // 暗い下地に文字が描かれている(全面が一色ではない)
        var colors = Set<UInt32>()
        for x in stride(from: 0, to: 400, by: 7) { for y in stride(from: 0, to: 170, by: 5) {
            if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) { colors.insert(UInt32(c.redComponent * 255) << 16 | UInt32(c.greenComponent * 255) << 8 | UInt32(c.blueComponent * 255)) }
        } }
        XCTAssertGreaterThan(colors.count, 4)
        m.edit("m") { $0.markers = [Marker(time: 1, name: "サビ")] }
        m.renamingMarkerId = m.project.markers[0].id
        _ = try render(RenameMarkerSheet(model: m), size: NSSize(width: 360, height: 130), name: "rename-marker-sheet.png")
        m.shutdown()
    }

    func testSelectingAnOffscreenClipFromTheMenuScrollsItIntoView() {
        var p = Project.new()
        p.tracks[0].clips = [clip("near", .text, start: 1, dur: 2), clip("far", .text, start: 60, dur: 3), clip("far2", .text, start: 200, dur: 400)]
        let m = ProjectModel(project: p)
        m.pps = 40
        let canvas = TimelineCanvas(frame: NSRect(x: 0, y: 0, width: 1000, height: 300))
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = canvas
        canvas.model = m
        canvas.syncFromModel()
        defer { m.shutdown(); window.contentView = nil }
        func visibleRange() -> ClosedRange<Double> {
            let g = canvas.geometry
            return g.time(forX: TimelineLayout.headerWidth)...g.time(forX: canvas.bounds.width)
        }
        m.selectedClipId = "near"; canvas.syncFromModel()
        XCTAssertEqual(canvas.geometry.scrollX, 0)
        m.selectedClipId = nil; canvas.syncFromModel()
        AppMenu.perform(.nextClip, model: m)             // near は選択なし → 再生位置(0)より後ろの最初 = near
        canvas.syncFromModel()
        AppMenu.perform(.nextClip, model: m)             // far(60 秒)
        canvas.syncFromModel()
        XCTAssertEqual(m.selectedClipId, "far")
        XCTAssertTrue(visibleRange().contains(60) && visibleRange().contains(63), "選んだクリップが見える所までスクロール")
        AppMenu.perform(.prevClip, model: m)
        canvas.syncFromModel()
        XCTAssertTrue(visibleRange().contains(1) && visibleRange().contains(3), "戻ったときも")
        AppMenu.perform(.nextClip, model: m); canvas.syncFromModel()
        AppMenu.perform(.nextClip, model: m); canvas.syncFromModel()
        XCTAssertEqual(m.selectedClipId, "far2")
        XCTAssertTrue(visibleRange().contains(200), "長いクリップは頭が見える")
        let before = canvas.geometry.scrollX
        canvas.revealClipHorizontally(m.selectedClip!)
        XCTAssertEqual(canvas.geometry.scrollX, before, "すでに見えていれば動かさない")
    }
}
