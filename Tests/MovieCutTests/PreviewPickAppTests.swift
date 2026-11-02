import XCTest
import AppKit
import MovieCutCore
@testable import MovieCut

/// プレビューの ⌥ クリックで、重なったクリップを手前から奥へ巡回して選ぶ。メニューの巡回選択も。
@MainActor
final class PreviewPickAppTests: XCTestCase {
    private func writeSolid(_ name: String) throws -> String {
        let n = 64
        let c = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(CGColor(srgbRed: 0.3, green: 0.5, blue: 0.9, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: n, height: n))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pick-\(UUID().uuidString)-\(name).png")
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, c.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url.path
    }

    /// 1280×720。大(720×720)の上に中(360×360)、その上に小(180×180)。すべて中央。
    private func model() throws -> ProjectModel {
        var p = Project.new()
        p.width = 1280; p.height = 720; p.characters = []
        func img(_ id: String, scale: Double) throws -> Clip {
            var c = Clip(); c.id = id; c.type = .image; c.src = try writeSolid(id); c.start = 0; c.duration = 4; c.x = 0.5; c.y = 0.5; c.scale = scale
            return c
        }
        p.tracks[0].clips = [try img("big", scale: 1)]
        p.tracks[1].clips = [try img("mid", scale: 0.5)]
        p.tracks[2].clips = [try img("small", scale: 0.25)]
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

    func testOptionClickCyclesFrontToBackAndWraps() throws {
        let m = try model()
        let v = makePreview(m)
        let center = v.viewPoint(CGPoint(x: 640, y: 360), canvas: CGSize(width: 1280, height: 720))
        let u = m.effectiveUndoManager
        XCTAssertNil(m.selectedClipId)
        XCTAssertTrue(v.pickOverlapping(atViewPoint: center)); XCTAssertEqual(m.selectedClipId, "small", "最初は最前面")
        XCTAssertTrue(v.pickOverlapping(atViewPoint: center)); XCTAssertEqual(m.selectedClipId, "mid")
        XCTAssertTrue(m.statusText.contains("2/3"))
        XCTAssertTrue(v.pickOverlapping(atViewPoint: center)); XCTAssertEqual(m.selectedClipId, "big")
        XCTAssertTrue(v.pickOverlapping(atViewPoint: center)); XCTAssertEqual(m.selectedClipId, "small", "最後の次は最前面へ")
        XCTAssertEqual(m.selectedClipIDs, ["small"], "単一選択")
        XCTAssertFalse(u.canUndo, "選択は Undo に載らない")
    }

    func testOptionClickOnlyCyclesWhatIsUnderThePointer() throws {
        let m = try model()
        let v = makePreview(m)
        // 中の枠の外・大の枠の中: 右へ 270 キャンバス画素(= 640+270)。中は ±180 まで、大は ±360
        let p = v.viewPoint(CGPoint(x: 640 + 270, y: 360), canvas: CGSize(width: 1280, height: 720))
        XCTAssertTrue(v.pickOverlapping(atViewPoint: p)); XCTAssertEqual(m.selectedClipId, "big")
        XCTAssertTrue(v.pickOverlapping(atViewPoint: p)); XCTAssertEqual(m.selectedClipId, "big", "重なりが 1 つならそのまま")
        // 何も無い所(大の外・フレームの内側): 選択は変えず false
        let none = v.viewPoint(CGPoint(x: 1270, y: 10), canvas: CGSize(width: 1280, height: 720))
        XCTAssertFalse(v.pickOverlapping(atViewPoint: none)); XCTAssertEqual(m.selectedClipId, "big")
        // 映像の外(余白)
        XCTAssertFalse(v.pickOverlapping(atViewPoint: CGPoint(x: 1, y: 1)))
    }

    func testMouseDownWithOptionPicksAndWithoutOptionDoesNot() throws {
        let m = try model()
        let v = makePreview(m)
        let c = v.viewPoint(CGPoint(x: 640, y: 360), canvas: CGSize(width: 1280, height: 720))
        func down(_ flags: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.mouseEvent(with: .leftMouseDown, location: c, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        v.mouseDown(with: down([]))
        XCTAssertNil(m.selectedClipId, "⌥ なしでは、選択していないクリップは動かない")
        v.mouseDown(with: down([.option]))
        XCTAssertEqual(m.selectedClipId, "small")
        XCTAssertNil(v.manipulation, "⌥ クリックではドラッグを始めない")
        v.mouseDown(with: down([.option]))
        XCTAssertEqual(m.selectedClipId, "mid")
    }

    func testLockedModelDoesNotPick() throws {
        let m = try model()
        m.isExporting = true
        XCTAssertFalse(m.pickPreviewClip(atCanvasPoint: CGPoint(x: 640, y: 360)))
        XCTAssertFalse(m.cycleOverlappingAtPlayhead())
        XCTAssertNil(m.selectedClipId)
    }

    func testMenuCycleVisitsFrontToBackAndIsDisabledWithoutOverlap() throws {
        let m = try model()
        var s = MenuState(model: m)
        XCTAssertEqual(s.overlapCount, 3)
        let item = try XCTUnwrap(AppMenuSpec.clipNavigate(s).first { $0.command == .cycleOverlapping })
        XCTAssertTrue(item.enabled); XCTAssertNil(item.shortcut)
        var order: [String] = []
        for _ in 0..<4 { AppMenu.perform(.cycleOverlapping, model: m); order.append(m.selectedClipId ?? "-") }
        XCTAssertEqual(order, ["small", "mid", "big", "small"])
        XCTAssertFalse(m.effectiveUndoManager.canUndo)
        m.currentTime = 9
        s = MenuState(model: m)
        XCTAssertEqual(s.overlapCount, 0)
        let off = try XCTUnwrap(AppMenuSpec.clipNavigate(s).first { $0.command == .cycleOverlapping })
        XCTAssertFalse(off.enabled)
        XCTAssertEqual(AppMenuSpec.disabledReason(for: off, state: { var x = s; x.hasDocument = true; return x }()), "再生位置でクリップが 2 つ以上重なっていません")
        XCTAssertFalse(m.cycleOverlappingAtPlayhead())
    }
}
