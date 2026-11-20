import XCTest
import MovieCutCore
@testable import MovieCut

/// 「ドラッグ中は値が動くのに、離した瞬間に元の値へ戻る」バグのコード監査(改善ラウンド4・1件目)で
/// 確定した欠陥の回帰テスト。
/// - トラックミキサーの音量・パン: ジェスチャの外(キーボード等)での書き込みが黙って捨てられていた。
/// - ロックされた「長さに合わせる」立ち絵: 合わせ直しがロック判定に触れ、関係ないドラッグの確定が丸ごと断られていた。
/// - ロックされた複合クリップの中: ドラッグ中は動くのに、離したときの `edit` が断って全体が戻っていた。
@MainActor
final class DragRevertAuditTests: XCTestCase {

    private func undoSteps(_ m: ProjectModel) -> Int {
        let u = m.effectiveUndoManager
        var n = 0
        while u.canUndo { u.undo(); n += 1 }
        for _ in 0..<n { u.redo() }
        return n
    }

    // MARK: トラックミキサー(ジェスチャ外の書き込み)

    func testTrackVolumeAndPanWithoutGestureAreAppliedAsEdits() {
        let m = ProjectModel(project: Project.new())
        m.notices = OneTimeNotices()
        // beginGesture していない(キーボード・VoiceOver でスライダーを動かした)書き込みも、落ちずに反映される
        m.liveTrackVolume(0, 0.5)
        XCTAssertEqual(m.project.tracks[0].trackVolumeOrDefault, 0.5, accuracy: 1e-9, "ジェスチャ外の音量変更が捨てられない")
        m.liveTrackPan(0, -0.25)
        XCTAssertEqual(m.project.tracks[0].trackPanOrDefault, -0.25, accuracy: 1e-9, "ジェスチャ外のパン変更が捨てられない")
        XCTAssertEqual(undoSteps(m), 2, "それぞれ 1 回の編集として Undo に載る")
    }

    func testTrackVolumeDragStillCommitsAsOneUndoStep() {
        let m = ProjectModel(project: Project.new())
        m.notices = OneTimeNotices()
        m.beginGesture()
        m.liveTrackVolume(0, 0.5)
        m.liveTrackVolume(0, 0.8)
        m.commitGesture(ProjectModel.trackVolumeUndoName)
        XCTAssertEqual(m.project.tracks[0].trackVolumeOrDefault, 0.8, accuracy: 1e-9)
        XCTAssertEqual(undoSteps(m), 1, "ドラッグは離したときに 1 回だけ")
    }

    // MARK: ロックされた「長さに合わせる」立ち絵と、関係ないドラッグの確定

    func testSpeedDragCommitsEvenWithLockedFollowingTachie() {
        var p = Project.new()
        var tachie = Clip(); tachie.id = "t1"; tachie.type = .tachie; tachie.start = 0; tachie.duration = 5
        tachie.tachieId = "ta"; tachie.followsProjectEnd = true
        var tachieTrack = Track(name: "立ち絵"); tachieTrack.clips = [tachie]; tachieTrack.locked = true
        var video = Clip(); video.id = "v1"; video.type = .video; video.start = 0; video.duration = 5
        video.src = "/tmp/clip-sample.mp4"; video.srcDuration = 60
        var videoTrack = Track(name: "映像"); videoTrack.clips = [video]
        p.tracks = [tachieTrack, videoTrack]
        p.tachies = [Tachie(name: "a")]; p.tachies[0].id = "ta"
        let m = ProjectModel(project: p)
        m.notices = OneTimeNotices()

        m.beginGesture()
        m.liveSpeed(2, clipId: "v1")
        XCTAssertEqual(m.clip("v1")?.duration ?? -1, 2.5, accuracy: 1e-9, "ドラッグ中は速度が効いている")
        m.commitGesture(ProjectModel.speedUndoName)
        XCTAssertEqual(m.clip("v1")?.speed, 2, "離しても速度が戻らない(ロック中の立ち絵の合わせ直しが確定を邪魔しない)")
        XCTAssertEqual(m.clip("v1")?.duration ?? -1, 2.5, accuracy: 1e-9)
        XCTAssertEqual(m.clip("t1")?.duration, 5, "ロック中の立ち絵は合わせ直されず、そのまま")
        XCTAssertEqual(undoSteps(m), 1)
    }

    // MARK: ロックされた複合クリップの中のドラッグ

    func testDragInsideLockedCompoundDoesNotMoveAtAll() throws {
        var p = Project.new()
        var a = Clip(); a.id = "a"; a.type = .image; a.start = 0; a.duration = 4
        p.tracks[0].clips = [a]
        var b = Clip(); b.id = "b"; b.type = .image; b.start = 1; b.duration = 4
        p.tracks[1].clips = [b]
        let m = ProjectModel(project: p)
        m.notices = OneTimeNotices()
        m.selectedClipIDs = ["a", "b"]; m.selectedClipId = "a"
        XCTAssertTrue(m.groupSelectedCompound())
        let compoundId = try XCTUnwrap(m.selectedClipId)
        // 複合クリップのレイヤーをロックしてから中に入る(中は見られる)
        let ti = try XCTUnwrap(m.project.tracks.firstIndex { $0.clips.contains { $0.id == compoundId } })
        XCTAssertTrue(m.edit("ロック") { $0.tracks[ti].locked = true })
        XCTAssertTrue(m.enterCompound(compoundId))
        m.selectOnly("a")
        let innerBefore = m.project

        m.beginGesture()
        m.liveClipField(.volume, 0.4, clipId: "a")
        XCTAssertEqual(m.project, innerBefore, "ロックされた入れ子の中では、ドラッグ中から値が動かない(離してから戻るのではない)")
        m.commitGesture("音量の変更")
        XCTAssertEqual(m.project, innerBefore, "確定でも何も変わらない")
        XCTAssertEqual(m.clip("a")?.volume, nil)
    }
}
