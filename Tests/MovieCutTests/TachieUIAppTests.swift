import XCTest
import AppKit
import SwiftUI
import MovieCutCore
@testable import MovieCut

/// 立ち絵の UI(段階 5〜7): プレビューでの選択・ドラッグ・拡大・回転、タイムラインの展開、メニュー、パネル、台本の説明、レイアウト。
@MainActor
final class TachieUIAppTests: XCTestCase {
    private func undoSteps(_ m: ProjectModel) -> Int { let u = m.effectiveUndoManager; var n = 0; while u.canUndo { u.undo(); n += 1 }; for _ in 0..<n { u.redo() }; return n }

    private func writePNG() throws -> String {
        let n = 40
        let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0.9, green: 0.2, blue: 0.2, alpha: 1)); ctx.fill(CGRect(x: 10, y: 10, width: 20, height: 20))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tui-\(UUID().uuidString).png")
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url.path
    }

    /// 1280×720。立ち絵クリップ 1 つ(中央、高さ 432 の正方形。中央 216 角が不透明)。
    private func model(locked: Bool = false) throws -> ProjectModel {
        var p = Project.new()
        p.width = 1280; p.height = 720
        var t = Tachie(name: "霊夢"); t.id = "t"; t.imgClosed = try writePNG()
        p.tachies = [t]
        var c = TachieEditing.makeClip(p, tachieId: "t", start: 0, duration: 4)!
        c.id = "tc"; c.x = 0.5; c.y = 0.5
        p.tracks[0].clips = [c]
        p.tracks[0].locked = locked ? true : nil
        let m = ProjectModel(project: p)
        m.currentTime = 1
        return m
    }

    private func makePreview(_ m: ProjectModel) -> PreviewCanvasView {
        let v = PreviewCanvasView()
        v.frame = NSRect(x: 0, y: 0, width: 640, height: 400)
        v.model = m
        v.setPlaceholder(project: m.project)
        v.layoutSubtreeIfNeeded(); v.layout()
        return v
    }

    private let canvas = CGSize(width: 1280, height: 720)

    // MARK: プレビュー

    func testClickingTheCharacterSelectsItAndDraggingMovesItAsOneUndoStep() throws {
        let m = try model()
        let v = makePreview(m)
        let u = m.effectiveUndoManager
        XCTAssertNil(m.selectedClipId)
        let center = v.viewPoint(CGPoint(x: 640, y: 360), canvas: canvas)
        XCTAssertTrue(v.selectTopmost(atViewPoint: center), "絵のある所を押すと選ばれ、続けてドラッグできる")
        XCTAssertEqual(m.selectedClipId, "tc")
        XCTAssertFalse(u.canUndo, "選ぶだけでは Undo に載らない")
        XCTAssertNotNil(v.manipulation)
        for i in 1...5 { v.dragManipulation(toViewPoint: CGPoint(x: center.x + 10 * CGFloat(i), y: center.y - 4 * CGFloat(i))) }
        XCTAssertFalse(u.canUndo, "ドラッグ中は載せない")
        v.endManipulation()
        let moved = try XCTUnwrap(m.clip("tc"))
        XCTAssertGreaterThan(moved.x ?? 0.5, 0.5); XCTAssertGreaterThan(moved.y ?? 0.5, 0.5)
        XCTAssertEqual(undoSteps(m), 1, "1 ドラッグ = Undo 1 回")
        u.undo()
        XCTAssertEqual(m.clip("tc")?.x, 0.5)
    }

    func testTransparentPixelInsideTheBoxDoesNotSelect() throws {
        let m = try model()
        let v = makePreview(m)
        let edge = v.viewPoint(CGPoint(x: 640 - 200, y: 360), canvas: canvas)     // 枠の中だが透明
        XCTAssertFalse(v.selectTopmost(atViewPoint: edge))
        XCTAssertNil(m.selectedClipId)
    }

    func testCornerScaleAndRotationHandleAndFlip() throws {
        let m = try model()
        m.selectOnly("tc")
        let v = makePreview(m)
        v.updateOverlay(PreviewView.overlayTarget(model: m, project: m.project, time: 1, assets: m.assets))
        let o = try XCTUnwrap(v.overlay, "立ち絵を選ぶと枠が出る")
        let c = v.viewPoint(o.box.center, canvas: o.canvas)
        let corner = v.viewPoint(o.box.corners[2], canvas: o.canvas)
        XCTAssertTrue(v.beginManipulation(atViewPoint: corner))
        v.dragManipulation(toViewPoint: CGPoint(x: c.x + (corner.x - c.x) * 2, y: c.y + (corner.y - c.y) * 2))
        v.endManipulation()
        XCTAssertEqual(try XCTUnwrap(m.clip("tc")?.scale), 2, accuracy: 0.05)
        XCTAssertEqual(undoSteps(m), 1)
        // 回転の取っ手
        v.updateOverlay(PreviewView.overlayTarget(model: m, project: m.project, time: 1, assets: m.assets))
        let o2 = try XCTUnwrap(v.overlay)
        let handle = v.viewPoint(o2.box.rotationHandle, canvas: o2.canvas)
        let c2 = v.viewPoint(o2.box.center, canvas: o2.canvas)
        XCTAssertTrue(v.beginManipulation(atViewPoint: handle))
        v.dragManipulation(toViewPoint: CGPoint(x: c2.x + hypot(handle.x - c2.x, handle.y - c2.y), y: c2.y))     // 真上 → 右(90°)
        v.endManipulation()
        XCTAssertEqual(try XCTUnwrap(m.clip("tc")?.rotation), 90, accuracy: 1.5)
        XCTAssertEqual(undoSteps(m), 2)
        // 左右反転(インスペクタの切り替え): 1 回、同じ値は載せない
        m.setFlip(horizontal: true, true, clipId: "tc")
        XCTAssertEqual(m.clip("tc")?.flipH, true); XCTAssertEqual(undoSteps(m), 3)
        m.setFlip(horizontal: true, true, clipId: "tc")
        XCTAssertEqual(undoSteps(m), 3)
    }

    func testLockedLayerRefusesDirectManipulation() throws {
        let m = try model(locked: true)
        let v = makePreview(m)
        let before = m.project
        let center = v.viewPoint(CGPoint(x: 640, y: 360), canvas: canvas)
        _ = v.selectTopmost(atViewPoint: center)
        for i in 1...3 { v.dragManipulation(toViewPoint: CGPoint(x: center.x + 20 * CGFloat(i), y: center.y)) }
        v.endManipulation()
        XCTAssertEqual(m.project, before, "ロックされたレイヤーのクリップは動かない")
        XCTAssertEqual(undoSteps(m), 0)
    }

    // MARK: メニュー

    func testAddTachieAndFitItemsAreInTheMenuWithReasons() throws {
        let m = try model()
        var s = MenuState(); s.hasDocument = true
        let add = AppMenuSpec.addTachie(s)
        XCTAssertEqual(add.title, "立ち絵を追加…"); XCTAssertNil(add.shortcut)
        XCTAssertTrue(AppMenuSpec.clipAdd(s).contains { $0.command == .addTachie })
        let fit = AppMenuSpec.fitTachie(s)
        XCTAssertFalse(fit.enabled)
        XCTAssertNotNil(AppMenuSpec.disabledReason(for: fit, state: s))
        XCTAssertTrue(AppMenuSpec.clipMenu(s).flatMap { $0 }.contains { $0.command == .fitTachieToVoice })
        // 声の無い立ち絵クリップ → 何も起きず履歴にも載らない
        m.selectOnly("tc")
        AppMenu.perform(.fitTachieToVoice, model: m)
        XCTAssertEqual(undoSteps(m), 0)
        // 声を足す → 合わせられる(1 回の Undo)
        var v = Clip(); v.id = "v"; v.type = .voice; v.charId = m.project.characters[0].id; v.start = 1; v.duration = 2; v.text = "やあ"
        var p = m.project; p.tracks.append({ var t = Track(name: "声"); t.clips = [v]; return t }()); m.project = p
        var s2 = MenuState(); s2.hasDocument = true; s2.canFitTachie = true
        XCTAssertTrue(AppMenuSpec.fitTachie(s2).enabled)
        XCTAssertTrue(m.canFitTachieToVoice)
        AppMenu.perform(.fitTachieToVoice, model: m)
        XCTAssertEqual(m.clip("tc")?.start, 1); XCTAssertEqual(m.clip("tc")?.duration, 2)
        XCTAssertEqual(undoSteps(m), 1)
        AppMenu.perform(.fitTachieToVoice, model: m)
        XCTAssertEqual(undoSteps(m), 1, "もう合っていれば載せない")
        // 立ち絵を追加…: シートが開く
        AppMenu.perform(.addTachie, model: m)
        XCTAssertTrue(m.showTachieSheet)
        m.placeTachie("t")
        XCTAssertFalse(m.showTachieSheet)
        XCTAssertEqual(m.project.allClips.filter { $0.type == .tachie }.count, 2)
    }

    // MARK: パネル

    func testSelectingTachieAssetShowsItsInspectorAndCharacterSelectionClearsIt() throws {
        let m = try model()
        m.selectTachie("t")
        XCTAssertEqual(m.inspectorMode, .tachie("t"))
        m.selectCharacter(m.project.characters[0].id)
        XCTAssertEqual(m.inspectorMode, .character(m.project.characters[0].id), "キャラ(声・字幕)を選ぶと立ち絵の表示は外れる")
        m.selectTachie("t")
        m.selectOnly("tc")
        XCTAssertEqual(m.inspectorMode, .clip("tc"))
        // 素材の名前変更・削除は 1 回の Undo
        m.renameTachie(id: "t", to: "れいむ"); XCTAssertEqual(undoSteps(m), 1)
        m.renameTachie(id: "t", to: "れいむ"); XCTAssertEqual(undoSteps(m), 1)
        m.setTachieBounce(tachieId: "t", true); XCTAssertEqual(undoSteps(m), 2)
        m.setTachieBounce(tachieId: "t", true); XCTAssertEqual(undoSteps(m), 2)
    }

    func testCharacterInspectorHoldsNoPortraitFieldsAnymore() throws {
        let src = try String(contentsOf: Self.sourceURL("InspectorView.swift"), encoding: .utf8)
        let a = try XCTUnwrap(src.range(of: "struct CharacterInspector"))
        let b = try XCTUnwrap(src.range(of: "struct NameField"))
        let body = String(src[a.lowerBound..<b.lowerBound])
        for gone in ["portraitRow", "vowelSection", "blinkRow", "expressionSection", "RigInspectorSection", "バウンス", "左右反転", "いつも表示", "横位置"] {
            XCTAssertFalse(body.contains(gone), "キャラクターの欄に \(gone) が残っている")
        }
        for kept in ["音声エンジン", "字幕の文字色", "字幕の縁の色", "話す速さ", "試しに読み上げる"] { XCTAssertTrue(body.contains(kept), kept) }
    }

    static func sourceURL(_ file: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/MovieCut/\(file)")
    }

    // MARK: 台本とボイスのインスペクタ

    func testScriptHelpExplainsTheSubtitleSeparator() {
        XCTAssertTrue(ScriptHelp.caption.contains("キャラ名: 読み上げ文 | 字幕文"))
        XCTAssertTrue(ScriptHelp.caption.contains("字幕なし"))
        XCTAssertTrue(ScriptHelp.placeholder.contains("|"))
    }

    func testVoiceSubtitleTextAndNoSubtitleToggleAreOneUndoEach() throws {
        var p = Project.new()
        var v = Clip(); v.id = "v"; v.type = .voice; v.charId = p.characters[0].id; v.start = 0; v.duration = 2; v.text = "こんにちは"
        p.tracks[0].clips = [v]
        let m = ProjectModel(project: p)
        m.setVoiceSubtitleText(clipId: "v", text: "こんにちは!"); XCTAssertEqual(m.clip("v")?.subtitleText, "こんにちは!"); XCTAssertEqual(undoSteps(m), 1)
        m.setVoiceSubtitleText(clipId: "v", text: ""); XCTAssertEqual(m.clip("v")?.subtitleText, ""); XCTAssertEqual(undoSteps(m), 2)
        m.setVoiceSubtitleText(clipId: "v", text: ""); XCTAssertEqual(undoSteps(m), 2)
        m.setVoiceSubtitleText(clipId: "v", text: nil); XCTAssertNil(m.clip("v")?.subtitleText); XCTAssertEqual(undoSteps(m), 3)
        let src = try String(contentsOf: Self.sourceURL("InspectorView.swift"), encoding: .utf8)
        XCTAssertTrue(src.contains("\"読み上げ文\"") && src.contains("字幕文（空なら読み上げ文と同じ）") && src.contains("\"字幕なし\""))
    }

    // MARK: タイムライン

    func testTimelineExpandsTachieClipByDoubleClickAndDrawsIt() throws {
        let m = try model()
        var q = m.project; q.tracks[0].clips[0].start = 1; q.tracks[0].clips[0].duration = 3; m.project = q     // 見出し(左の列)の右に出るように 1 秒から
        // 声(表情タグ入り)を足す
        var v = Clip(); v.id = "v"; v.type = .voice; v.charId = m.project.characters[0].id; v.start = 2; v.duration = 1; v.text = "[笑顔]やあ"
        var p = m.project; var t = Track(name: "声"); t.clips = [v]; p.tracks.append(t); m.project = p
        m.pps = 120
        let canvas = TimelineCanvas(frame: NSRect(x: 0, y: 0, width: 1000, height: 320))
        let w = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = canvas
        canvas.model = m
        canvas.syncFromModel()
        let y = canvas.geometry.rowTop(0) + canvas.geometry.rowHeight(0) / 2
        let mid = NSPoint(x: canvas.geometry.x(forTime: 2.5), y: y)
        func pixels() throws -> Data {
            let rep = try XCTUnwrap(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
            canvas.cacheDisplay(in: canvas.bounds, to: rep)
            return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        }
        let collapsed = try pixels()
        XCTAssertFalse(m.expandedTachieClipIds.contains("tc"))
        canvas.mouseDown(at: mid, clickCount: 1); canvas.mouseUp()
        XCTAssertFalse(m.expandedTachieClipIds.contains("tc"), "1 回押しただけでは開かない")
        canvas.mouseDown(at: mid, clickCount: 2); canvas.mouseUp()
        XCTAssertTrue(m.expandedTachieClipIds.contains("tc"), "ダブルクリックで中身を開く")
        XCTAssertNotEqual(try pixels(), collapsed, "開くと表情の切り替わりが描かれる")
        // ▸ でも閉じられる
        let r = canvas.geometry.clipRect(start: 1, duration: 3, track: 0)
        let g = TimelineCanvas.tachieDisclosureRect(r)
        canvas.mouseDown(at: NSPoint(x: g.midX, y: g.midY), clickCount: 1); canvas.mouseUp()
        XCTAssertFalse(m.expandedTachieClipIds.contains("tc"))
        XCTAssertEqual(undoSteps(m), 0, "開閉は Undo に載らない")
        XCTAssertEqual(TimelineCanvas.thumbnailPath(of: try XCTUnwrap(m.tachie("t"))), try XCTUnwrap(m.tachie("t")).imgClosed)
        m.shutdown()
    }

    // MARK: レイアウト(幅 1100 / 1456)

    func testTransportRowMovedIntoToolbar() throws {
        let src = try String(contentsOf: Self.sourceURL("ContentView.swift"), encoding: .utf8)
        let a = try XCTUnwrap(src.range(of: "struct CenterPanel")), b = try XCTUnwrap(src.range(of: "struct TransportBar"))
        XCTAssertFalse(src[a.lowerBound..<b.lowerBound].contains("TransportBar("), "プレビューの下の再生行は廃止")
        let t = try XCTUnwrap(src.range(of: "struct ToolbarBar")), l = try XCTUnwrap(src.range(of: "struct LeftPanel"))
        XCTAssertTrue(src[t.lowerBound..<l.lowerBound].contains("TransportBar(model: model"), "ツールバー行に再生コントロール")
        XCTAssertFalse(ToolbarBar.showsResolution(forWidth: 1100), "狭い幅では解像度・fps を省く")
        XCTAssertTrue(ToolbarBar.showsResolution(forWidth: 1456))
        XCTAssertLessThan(DockGroupView.tabBarHeight, 26, "見出し行を詰めた")
    }

    private func descendants<T: NSView>(_ v: NSView, of type: T.Type) -> [T] {
        var out: [T] = []
        for s in v.subviews { if let t = s as? T { out.append(t) }; out += descendants(s, of: type) }
        return out
    }

    private func layout(width: CGFloat, height: CGFloat) throws {
        let m = ProjectModel(project: .new())
        m.notices = OneTimeNotices()
        m.statusText = ""
        let host = NSHostingView(rootView: ContentView(model: m, fileURL: nil, dock: DockStore(defaults: UserDefaults(suiteName: "tachie-ui-\(UUID().uuidString)")!), presentsDockWindows: false))
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        host.layoutSubtreeIfNeeded()
        let bounds = host.bounds
        let previews = descendants(host, of: PreviewCanvasView.self), timelines = descendants(host, of: TimelineCanvas.self)
        let pv = try XCTUnwrap(previews.first), tl = try XCTUnwrap(timelines.first)
        let pr = host.convert(pv.bounds, from: pv), tr = host.convert(tl.bounds, from: tl)
        XCTAssertTrue(bounds.insetBy(dx: -0.5, dy: -0.5).contains(pr), "プレビューが画面からはみ出している \(pr)")
        XCTAssertTrue(bounds.insetBy(dx: -0.5, dy: -0.5).contains(tr), "タイムラインが画面からはみ出している \(tr)")
        XCTAssertFalse(pr.insetBy(dx: 1, dy: 1).intersects(tr.insetBy(dx: 1, dy: 1)), "プレビューとタイムラインが重なっている")
        XCTAssertGreaterThan(pr.width, 320); XCTAssertGreaterThan(pr.height, 200)
        // 右パネル(プロパティ/キャラクター)は 300pt 以上: 左の列の右端から窓の右端まで
        let leftRight = max(pr.maxX, tr.maxX)
        XCTAssertGreaterThanOrEqual(bounds.width - leftRight, 300, "右パネルが 300pt を割っている(\(bounds.width - leftRight))")
        // ツールバー: 理想の幅(解像度・fps を含む)が収まるか、狭い幅では省かれて収まる
        let compactFit = NSHostingView(rootView: HStack(spacing: 8) { TransportBar(model: m, showsResolution: ToolbarBar.showsResolution(forWidth: width)) }.fixedSize())
        XCTAssertLessThan(compactFit.fittingSize.width + 450, width, "ツールバーの再生コントロールが収まらない")   // 450 = 左のボタン群の余裕
        // 画像を残す(目視用)
        let dir = ProcessInfo.processInfo.environment["MC_SNAPSHOT_OUT_DIR"] ?? "/private/tmp/claude-501/-Users-USER------------/07529bfa-5715-4444-bf9c-c37229b6ab4d/scratchpad/qa-ui"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: dir).appendingPathComponent("tachie-ui-layout-\(Int(width))x\(Int(height)).png"))
        m.shutdown()
    }

    func testLayoutAt1100x700HasNoClippingOrOverlap() throws { try layout(width: 1100, height: 700) }
    func testLayoutAt1456x840HasNoClippingOrOverlap() throws { try layout(width: 1456, height: 840) }
}
