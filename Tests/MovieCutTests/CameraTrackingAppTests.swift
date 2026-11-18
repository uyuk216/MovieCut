import XCTest
import MovieCutCore
@testable import MovieCut

/// カメラ(W3-02)とトラッキング(W3-03)のアプリ層: モデルの編集・Undo・追従可否と解除。
@MainActor
final class CameraTrackingAppTests: XCTestCase {

    private func makeModel() -> ProjectModel {
        var p = Project.new()
        p.fps = 60
        var src = Clip(); src.id = "src"; src.type = .video; src.src = "/tmp/none.mp4"; src.start = 0; src.duration = 10; src.srcDuration = 10
        var text = Clip(); text.id = "fol"; text.type = .text; text.text = "字幕"; text.start = 1; text.duration = 3
        var bottom = Track(); bottom.clips = [src]
        var top = Track(); top.clips = [text]
        p.tracks = [bottom, top]
        let m = ProjectModel(project: p)
        m.notices = OneTimeNotices()
        return m
    }

    // MARK: カメラ

    func testSetCameraValueAndUndo() {
        let m = makeModel()
        XCTAssertNil(m.project.camera)
        m.setCameraValue("x", 0.7)
        XCTAssertEqual(m.project.camera?.x, 0.7)
        XCTAssertEqual(m.cameraValue("x"), 0.7)
        m.effectiveUndoManager.undo()
        XCTAssertNil(m.project.camera, "Undo で未設定に戻る")
        // 既定値に戻すとカメラ自体が消える(ファイルに残らない)
        m.setCameraValue("orbit", 30)
        XCTAssertNotNil(m.project.camera)
        m.setCameraValue("orbit", 0)
        XCTAssertNil(m.project.camera)
    }

    func testCameraKeyframeToggleAndEdit() {
        let m = makeModel()
        m.currentTime = 1
        XCTAssertEqual(m.cameraKeyState("fov"), .none)
        XCTAssertTrue(m.toggleCameraKeyframe("fov"))
        XCTAssertEqual(m.cameraKeyState("fov"), .onKey)
        XCTAssertEqual(m.project.camera?.keyframes["fov"]?.count, 1)
        XCTAssertEqual(m.project.camera?.keyframes["fov"]?.first?.t, 1)
        // キーがある状態で値を変えると、静的な値ではなくキーが更新される
        m.setCameraValue("fov", 40)
        XCTAssertEqual(m.project.camera?.keyframes["fov"]?.first?.v, 40)
        XCTAssertEqual(m.project.camera?.fov, CameraSettings.defaultFov, "静的な値は既定のまま")
        XCTAssertEqual(m.cameraValue("fov"), 40, "再生ヘッドではキーの値")
        // もう一度 ◇ でキーが消え、値は静的な値として残る
        XCTAssertTrue(m.toggleCameraKeyframe("fov"))
        XCTAssertNil(m.project.camera?.keyframes["fov"])
        XCTAssertEqual(m.project.camera?.fov, 40)
    }

    func testCameraSeekAndReset() {
        let m = makeModel()
        m.currentTime = 0
        _ = m.toggleCameraKeyframe("x")
        m.currentTime = 3
        _ = m.toggleCameraKeyframe("x")
        m.currentTime = 0
        XCTAssertTrue(m.seekCameraKeyframe("x", forward: true))
        XCTAssertEqual(m.currentTime, 3, accuracy: 0.05)
        XCTAssertTrue(m.resetCamera())
        XCTAssertNil(m.project.camera)
        XCTAssertFalse(m.resetCamera(), "未設定なら何もしない")
    }

    // MARK: トラッキング(モデル層)

    func testCanObjectTrack() {
        let m = makeModel()
        let text = m.project.allClips.first { $0.id == "fol" }!
        XCTAssertTrue(m.canObjectTrack(text), "映像の上の文字は追従できる")
        let src = m.project.allClips.first { $0.id == "src" }!
        XCTAssertFalse(m.canObjectTrack(src), "一番下の映像には追跡元が無い")
    }

    func testClearObjectFollowWithUndo() {
        let m = makeModel()
        // 追跡結果を Core の適用で作ってから、モデルの解除を確かめる
        let samples = (0...10).map { k in
            TrackSample(t: Double(k) / 10, rect: TrackRect(x: 0.4 + 0.01 * Double(k), y: 0.4, w: 0.2, h: 0.2))
        }
        let track = ObjectTrack(sourceClipId: "src", startRect: TrackRect(x: 0.4, y: 0.4, w: 0.2, h: 0.2), samples: samples)
        m.edit("追従を付ける") { p in
            let loc = ClipEditing.locate("fol", in: p)!
            _ = ObjectTracking.apply(track: track, to: &p.tracks[loc.track].clips[loc.index])
        }
        XCTAssertNotNil(m.project.allClips.first { $0.id == "fol" }?.tracking)
        XCTAssertTrue(m.clearObjectFollow(clipId: "fol"))
        let after = m.project.allClips.first { $0.id == "fol" }!
        XCTAssertNil(after.tracking)
        XCTAssertNil(after.keyframes["x"])
        m.effectiveUndoManager.undo()
        XCTAssertNotNil(m.project.allClips.first { $0.id == "fol" }?.tracking, "Undo で追従が戻る")
    }
}
