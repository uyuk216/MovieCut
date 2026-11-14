import XCTest
import MovieCutCore
@testable import MovieCut

/// シーンで分割の配線: シートを開く条件と、決定が 1 回の Undo でプロジェクトへ入ること。
@MainActor
final class SceneSplitAppTests: XCTestCase {
    private func model(withVideo: Bool) -> ProjectModel {
        var p = Project.new()
        var c = Clip()
        c.id = "v"; c.type = withVideo ? .video : .image; c.src = "/x.mp4"; c.start = 0; c.duration = 6; c.srcDuration = 6
        p.tracks[0].clips = [c]
        let m = ProjectModel(project: p)
        m.selectedClipId = "v"
        return m
    }

    func testOpenSceneSheetGating() {
        let mv = model(withVideo: true)
        mv.openSceneSheet()
        XCTAssertTrue(mv.showSceneSheet)
        XCTAssertEqual(mv.sceneClipId, "v")
        XCTAssertTrue(MenuState(model: mv).canSceneSplit)

        let mi = model(withVideo: false)
        mi.openSceneSheet()
        XCTAssertFalse(mi.showSceneSheet, "画像クリップでは開かない")
        XCTAssertFalse(MenuState(model: mi).canSceneSplit)
    }

    func testSplitAtScenesAppliesWithOneUndo() {
        let m = model(withVideo: true)
        // 3 秒地点に強い差があるプロファイル(0.5 秒ごと・6 秒)
        var times: [Double] = []
        var diffs: [Double] = []
        for i in 0 ... 12 { times.append(Double(i) * 0.5) }
        for i in 0 ..< 12 { diffs.append(times[i + 1] == 3.0 ? 0.9 : 0.01) }
        let prof = SceneProfile(times: times, diffs: diffs, duration: 6)
        XCTAssertTrue(m.splitAtScenes(clipId: "v", profile: prof, params: .default))
        XCTAssertEqual(m.project.allClips.count, 2)
        XCTAssertEqual(m.project.allClips.map { $0.duration }, [3, 3])
        // 差が無いプロファイルでは何も起きず Undo も増えない
        let flat = SceneProfile(times: times, diffs: [Double](repeating: 0.01, count: 12), duration: 6)
        XCTAssertFalse(m.splitAtScenes(clipId: "v", profile: flat, params: .default))
        var steps = 0
        while m.effectiveUndoManager.canUndo { m.effectiveUndoManager.undo(); steps += 1 }
        XCTAssertEqual(steps, 1, "分割は全体で 1 回の Undo")
        XCTAssertEqual(m.project.allClips.count, 1)
    }
}
