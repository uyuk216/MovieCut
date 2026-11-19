import XCTest
import AppKit
import MovieCutCore
@testable import MovieCut

/// メッシュ/パペット変形 R2-5(アプリ側): 任意位置へのピン追加、モデル経由のキーフレーム、
/// プレビュー上の実ドラッグ(PreviewCanvasView)が Undo 1 回にまとまること。
@MainActor
final class WarpDragKeyframeAppTests: XCTestCase {

    private func writeSolid(_ name: String) throws -> String {
        let n = 64
        let c = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(CGColor(srgbRed: 0.3, green: 0.5, blue: 0.9, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: n, height: n))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("warp-\(UUID().uuidString)-\(name).png")
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, c.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url.path
    }

    private func makeModel(src: String) -> ProjectModel {
        var p = Project.new()
        p.width = 1280; p.height = 720
        var c = Clip(); c.id = "i"; c.type = .image; c.start = 0; c.duration = 4; c.src = src
        p.tracks[0].clips = [c]
        let m = ProjectModel(project: p)
        m.notices = OneTimeNotices()
        m.selectedClipId = "i"
        return m
    }

    func testAddPuppetPinAtArbitraryPositionIsOneUndo() throws {
        let m = makeModel(src: try writeSolid("a"))
        m.addPuppetPin(fixed: false, atX: 0.25, atY: 0.75, clipId: "i")
        let pin = try XCTUnwrap(m.selectedClip?.puppetWarp?.pins.first)
        XCTAssertEqual(pin.hx, 0.25, accuracy: 1e-9)
        XCTAssertEqual(pin.hy, 0.75, accuracy: 1e-9)
        XCTAssertEqual(m.selectedClip?.puppetWarp?.pins.count, 1)
        m.effectiveUndoManager.undo()
        XCTAssertNil(m.selectedClip?.puppetWarp, "用意+追加が 1 回の Undo で戻る")
    }

    func testWarpKeyframeToggleAndKeyedLiveEditThroughModel() throws {
        let m = makeModel(src: try writeSolid("b"))
        m.ensureMeshWarp(clipId: "i")
        m.currentTime = 0
        XCTAssertTrue(m.toggleKeyframe("mesh.4.x", clipId: "i"))
        m.currentTime = 2
        XCTAssertTrue(m.toggleKeyframe("mesh.4.x", clipId: "i"))
        XCTAssertEqual(m.selectedClip?.keyframes["mesh.4.x"]?.count, 2)
        // 再生ヘッド(t=2)でスライダーを動かすと、ここのキーが書かれて静的な値は動かない
        m.beginGesture()
        m.liveMeshAxis(clipId: "i", index: 4, axis: .x, 0.9)
        m.commitGesture(ProjectModel.warpUndoName)
        XCTAssertEqual(m.selectedClip?.meshWarp?.points[4].x ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertEqual(m.animatedValue("mesh.4.x", of: m.selectedClip!), 0.9, accuracy: 1e-9)
        m.currentTime = 1
        XCTAssertEqual(m.animatedValue("mesh.4.x", of: m.selectedClip!), 0.7, accuracy: 1e-9, "中間は補間")
        m.effectiveUndoManager.undo()
        XCTAssertEqual(m.selectedClip?.keyframes["mesh.4.x"]?.last?.v ?? -1, 0.5, accuracy: 1e-9, "ドラッグは 1 回の Undo")
    }

    // MARK: プレビューの実ドラッグ

    private func makePreview(_ m: ProjectModel) -> PreviewCanvasView {
        let v = PreviewCanvasView()
        v.frame = NSRect(x: 0, y: 0, width: 640, height: 400)
        v.model = m
        v.setPlaceholder(project: m.project)
        v.layoutSubtreeIfNeeded(); v.layout()
        return v
    }

    func testPreviewWarpDragMovesMeshPointAsOneUndo() throws {
        let m = makeModel(src: try writeSolid("c"))
        m.ensureMeshWarp(clipId: "i")
        m.currentTime = 1
        let target = try XCTUnwrap(PreviewView.overlayTarget(model: m, project: m.project, time: m.currentTime, assets: m.assets))
        XCTAssertEqual(target.warpHandles.count, 9)
        let v = makePreview(m)
        v.updateOverlay(target)
        let canvas = CGSize(width: 1280, height: 720)
        func viewPt(_ wp: WarpPoint) -> CGPoint { v.viewPoint(WarpDrag.canvasPoint(wp, box: target.box), canvas: canvas) }
        XCTAssertTrue(v.beginManipulation(atViewPoint: viewPt(WarpPoint(x: 0.5, y: 0.5))), "中央の制御点が掴める")
        XCTAssertEqual(v.manipulation?.warp, .mesh(4))
        v.dragManipulation(toViewPoint: viewPt(WarpPoint(x: 0.75, y: 0.5)))
        v.endManipulation()
        XCTAssertEqual(m.selectedClip?.meshWarp?.points[4].x ?? -1, 0.75, accuracy: 1e-6)
        XCTAssertEqual(m.selectedClip?.meshWarp?.points[4].y ?? -1, 0.5, accuracy: 1e-6)
        m.effectiveUndoManager.undo()
        XCTAssertEqual(m.selectedClip?.meshWarp?.points[4].x ?? -1, 0.5, accuracy: 1e-9, "プレビューのドラッグ全体が 1 回の Undo")
    }

    func testPreviewDoubleClickAddsPinAtThatPlace() throws {
        let m = makeModel(src: try writeSolid("d"))
        m.ensurePuppetWarp(clipId: "i")
        m.currentTime = 1
        let target = try XCTUnwrap(PreviewView.overlayTarget(model: m, project: m.project, time: m.currentTime, assets: m.assets))
        let v = makePreview(m)
        v.updateOverlay(target)
        let canvas = CGSize(width: 1280, height: 720)
        let at = v.viewPoint(WarpDrag.canvasPoint(WarpPoint(x: 0.25, y: 0.25), box: target.box), canvas: canvas)
        XCTAssertTrue(v.addPuppetPinAt(atViewPoint: at))
        let pin = try XCTUnwrap(m.selectedClip?.puppetWarp?.pins.first)
        XCTAssertEqual(pin.hx, 0.25, accuracy: 1e-6)
        XCTAssertEqual(pin.hy, 0.25, accuracy: 1e-6)
        // クリップの外では打てない
        let outside = v.viewPoint(CGPoint(x: 10, y: 10), canvas: canvas)
        XCTAssertFalse(v.addPuppetPinAt(atViewPoint: outside))
        XCTAssertEqual(m.selectedClip?.puppetWarp?.pins.count, 1)
    }
}
