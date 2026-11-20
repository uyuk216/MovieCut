import XCTest
import AppKit
import MovieCutCore
@testable import MovieCut

/// 表示 ▸ スナップと、プレビューのドラッグでの吸着: 設定の保存、メニュー項目、移動・拡縮の吸着、OFF と ⌘ 一時無効。
/// 保存先は UserDefaults なので、前の値を戻して本人の設定を汚さない(PreviewTierAppTests と同じ流儀)。
@MainActor
final class PreviewSnapAppTests: XCTestCase {
    private var saved: Bool?
    private var savedExists = false

    override func setUp() {
        super.setUp()
        savedExists = UserDefaults.standard.object(forKey: PreviewSnapStore.defaultsKey) != nil
        saved = UserDefaults.standard.bool(forKey: PreviewSnapStore.defaultsKey)
        UserDefaults.standard.removeObject(forKey: PreviewSnapStore.defaultsKey)
    }

    override func tearDown() {
        if savedExists { UserDefaults.standard.set(saved ?? true, forKey: PreviewSnapStore.defaultsKey) } else { UserDefaults.standard.removeObject(forKey: PreviewSnapStore.defaultsKey) }
        super.tearDown()
    }

    // MARK: 設定とメニュー

    func testDefaultIsOnAndSetStoresAndNotifies() {
        XCTAssertTrue(PreviewSnapStore.current, "保存が無ければ ON")
        var notified = 0
        let token = NotificationCenter.default.addObserver(forName: PreviewSnapStore.didChange, object: nil, queue: nil) { _ in notified += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        PreviewSnapStore.set(false)
        XCTAssertFalse(PreviewSnapStore.current)
        XCTAssertEqual(notified, 1)
        PreviewSnapStore.toggle()
        XCTAssertTrue(PreviewSnapStore.current)
        XCTAssertEqual(notified, 2)
    }

    func testMenuItemIsACheckWithoutShortcutAndPerformTogglesWithoutTouchingTheProject() {
        var s = MenuState(); s.hasDocument = true
        s.previewSnapEnabled = true
        let item = AppMenuSpec.previewSnapItem(s)
        XCTAssertEqual(item.title, "スナップ")
        XCTAssertNil(item.shortcut)
        XCTAssertTrue(item.enabled)
        XCTAssertEqual(item.checked, true)
        s.previewSnapEnabled = false
        XCTAssertEqual(AppMenuSpec.previewSnapItem(s).checked, false)
        XCTAssertTrue(AppMenuSpec.all(s).contains { $0.command == .previewSnapToggle }, "項目表の全一覧にも入る")

        let m = ProjectModel(project: .new())
        let before = m.project
        PreviewSnapStore.set(true)
        AppMenu.perform(.previewSnapToggle, model: m)
        XCTAssertFalse(PreviewSnapStore.current)
        XCTAssertEqual(m.project, before, "書類は変えない")
        XCTAssertFalse(m.effectiveUndoManager.canUndo)
        XCTAssertFalse(MenuState(model: m).previewSnapEnabled, "メニューの状態も追随する")
    }

    func testGridGuideToggleIsExclusiveThroughTheStore() {
        // ガイドの保存も前の値を戻す
        let key = PreviewGuide.defaultsKey
        let savedGuides = UserDefaults.standard.stringArray(forKey: key)
        defer {
            if let savedGuides { UserDefaults.standard.set(savedGuides, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
            NotificationCenter.default.post(name: PreviewGuideStore.didChange, object: nil)
        }
        UserDefaults.standard.removeObject(forKey: key)
        NotificationCenter.default.post(name: PreviewGuideStore.didChange, object: nil)
        PreviewGuideStore.toggle(.thirds)
        XCTAssertEqual(PreviewGuideStore.current, [.thirds])
        PreviewGuideStore.toggle(.grid4)
        XCTAssertEqual(PreviewGuideStore.current, [.grid4], "グリッドを ON にすると他のグリッドは外れる")
        PreviewGuideStore.toggle(.center)
        XCTAssertEqual(PreviewGuideStore.current, [.grid4, .center], "中心線はグリッドと独立")
        PreviewGuideStore.toggle(.grid2)
        XCTAssertEqual(PreviewGuideStore.current, [.grid2, .center])
        PreviewGuideStore.toggle(.grid2)
        XCTAssertEqual(PreviewGuideStore.current, [.center])
    }

    // MARK: ドラッグでの吸着

    private func writeSolid() throws -> String {
        let n = 64
        let c = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(CGColor(srgbRed: 0.9, green: 0.3, blue: 0.2, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: n, height: n))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("snap-\(UUID().uuidString).png")
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, c.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url.path
    }

    /// 1280×720。画像 1 つ(中央、枠 360×360 = 左 460・右 820・上 180・下 540)。
    private func model() throws -> ProjectModel {
        var p = Project.new()
        p.width = 1280; p.height = 720; p.characters = []
        var c = Clip(); c.id = "p"; c.type = .image; c.src = try writeSolid(); c.start = 0; c.duration = 4; c.x = 0.5; c.y = 0.5; c.scale = 0.5
        p.tracks[0].clips = [c]
        let m = ProjectModel(project: p)
        m.selectedClipId = "p"
        m.currentTime = 1
        return m
    }

    private func makePreview(_ m: ProjectModel) -> PreviewCanvasView {
        let v = PreviewCanvasView()
        v.frame = NSRect(x: 0, y: 0, width: 640, height: 400)
        v.model = m
        v.setPlaceholder(project: m.project)
        v.layoutSubtreeIfNeeded(); v.layout()
        v.updateOverlay(PreviewView.overlayTarget(model: m, project: m.project, time: 1, assets: m.assets))
        return v
    }

    private let canvas = CGSize(width: 1280, height: 720)

    func testDragMoveSnapsRightEdgeToCanvasCenter() throws {
        PreviewSnapStore.set(true)
        let m = try model()
        let v = makePreview(m)
        let o = try XCTUnwrap(v.overlay)
        let center = v.viewPoint(o.box.center, canvas: o.canvas)
        XCTAssertTrue(v.beginManipulation(atViewPoint: center))
        // 中心をキャンバス (466, 300) へ: 右端は 646 で、中心線 640 まで 6(閾値以内)なので吸着して中心 460 になる(y はどこにも届かない)
        v.dragManipulation(toViewPoint: v.viewPoint(CGPoint(x: 466, y: 300), canvas: canvas))
        XCTAssertEqual(v.snappedLinesForTest.vertical, 640)
        XCTAssertNil(v.snappedLinesForTest.horizontal)
        v.endManipulation()
        XCTAssertEqual(try XCTUnwrap(m.clip("p")?.x), 460.0 / 1280, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(m.clip("p")?.y), 300.0 / 720, accuracy: 1e-9)
        XCTAssertNil(v.snappedLinesForTest.vertical, "ドラッグ終了で吸着の線は消える")
    }

    func testDragMoveDoesNotSnapWhenStoreIsOffOrCommandIsHeld() throws {
        let m = try model()
        // OFF: そのままの位置
        PreviewSnapStore.set(false)
        let v = makePreview(m)
        let o = try XCTUnwrap(v.overlay)
        XCTAssertTrue(v.beginManipulation(atViewPoint: v.viewPoint(o.box.center, canvas: o.canvas)))
        v.dragManipulation(toViewPoint: v.viewPoint(CGPoint(x: 466, y: 360), canvas: canvas))
        XCTAssertNil(v.snappedLinesForTest.vertical)
        v.endManipulation()
        XCTAssertEqual(try XCTUnwrap(m.clip("p")?.x), 466.0 / 1280, accuracy: 1e-9)
        m.effectiveUndoManager.undo()
        // ON でも ⌘ 押下中は一時無効
        PreviewSnapStore.set(true)
        let v2 = makePreview(m)
        let o2 = try XCTUnwrap(v2.overlay)
        XCTAssertTrue(v2.beginManipulation(atViewPoint: v2.viewPoint(o2.box.center, canvas: o2.canvas)))
        v2.dragManipulation(toViewPoint: v2.viewPoint(CGPoint(x: 466, y: 360), canvas: canvas), snapDisabled: true)
        XCTAssertNil(v2.snappedLinesForTest.vertical)
        v2.endManipulation()
        XCTAssertEqual(try XCTUnwrap(m.clip("p")?.x), 466.0 / 1280, accuracy: 1e-9)
    }

    func testDragCornerSnapsToCanvasCorner() throws {
        PreviewSnapStore.set(true)
        let m = try model()
        let v = makePreview(m)
        let o = try XCTUnwrap(v.overlay)
        let corner = v.viewPoint(o.box.corners[2], canvas: o.canvas)   // 右下 (820, 540)
        XCTAssertTrue(v.beginManipulation(atViewPoint: corner))
        // 角を (1275, 715) へ: 両軸とも端まで 5 なので (1280, 720) へ吸着する
        v.dragManipulation(toViewPoint: v.viewPoint(CGPoint(x: 1275, y: 715), canvas: canvas))
        XCTAssertEqual(v.snappedLinesForTest.vertical, 1280)
        XCTAssertEqual(v.snappedLinesForTest.horizontal, 720)
        v.endManipulation()
        // 拡大は中心からの距離の比: 吸着後の角で計算される
        let d0 = hypot(820.0 - 640, 540.0 - 360), d1 = hypot(1280.0 - 640, 720.0 - 360)
        XCTAssertEqual(try XCTUnwrap(m.clip("p")?.scale), 0.5 * d1 / d0, accuracy: 1e-6)
    }
}
