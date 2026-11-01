import XCTest
import MovieCutCore
@testable import MovieCut

/// 縦動画に自動リフレーム(メニュー・モデル)。検出は実機の Vision を使うので、ここではモデルの適用だけを見る。
@MainActor
final class AutoReframeAppTests: XCTestCase {

    private func video(_ id: String) -> Clip {
        var c = Clip(); c.id = id; c.type = .video; c.start = 0; c.duration = 2; c.src = "/tmp/none.mov"; c.srcDuration = 2
        return c
    }

    private func makeModel(_ clips: [Clip]) -> ProjectModel {
        var p = Project.new()
        p.tracks[0].clips = clips
        let m = ProjectModel(project: p)
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

    func testMenuItemIsInClipEditWithoutShortcut() throws {
        let items = AppMenuSpec.clipEdit(state { $0.canAutoReframe = true; $0.hasSelection = true })
        let item = try XCTUnwrap(items.first(where: { $0.command == MenuCommand.autoReframe }))
        XCTAssertEqual(item.title, "縦動画に自動リフレーム")
        XCTAssertNil(item.shortcut)
        XCTAssertTrue(item.enabled)
        let off = AppMenuSpec.clipEdit(state())
        XCTAssertFalse(try XCTUnwrap(off.first(where: { $0.command == MenuCommand.autoReframe })).enabled)
    }

    func testApplyMakesPortraitAndWritesKeysAsOneUndoStep() throws {
        let m = makeModel([video("v1")])
        m.selectedClipId = "v1"
        // 横長の素材で作った計画(中央に固定された被写体)
        let samples = (0...10).map { SubjectSample(t: Double($0) / 5, rects: [CGRect(x: 0.6, y: 0.4, width: 0.1, height: 0.2)]) }
        let plan = try XCTUnwrap(AutoReframe.plan(samples: samples, sourceWidth: 1920, sourceHeight: 1080))
        m.applyAutoReframe(plan, clipId: "v1")
        XCTAssertEqual(m.project.width, 1080)
        XCTAssertEqual(m.project.height, 1920)
        XCTAssertEqual(m.selectedClip?.keyframes["x"]?.count, samples.count)
        XCTAssertEqual(m.selectedClip?.scale ?? 1, plan.scale, accuracy: 1e-9)
        let u = m.effectiveUndoManager
        u.undo()
        XCTAssertEqual(m.project.width, 1920, "1 回の Undo で解像度も元に戻る")
        XCTAssertNil(m.selectedClip?.keyframes["x"])
        XCTAssertFalse(u.canUndo, "Undo は 1 回ぶんだけ")
    }

    func testCanAutoReframeRejectsAudioAndCropped() {
        let m = makeModel([video("v1")])
        XCTAssertTrue(m.canAutoReframe(video("a")))
        var audio = video("a2"); audio.type = .audio
        XCTAssertFalse(m.canAutoReframe(audio))
        var cropped = video("c"); cropped.crop = Crop(l: 0.1, t: 0, r: 0, b: 0)
        XCTAssertFalse(m.canAutoReframe(cropped))
    }
}
