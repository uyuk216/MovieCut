import XCTest
import MovieCutCore
@testable import MovieCut

/// AIラフカット(第 1 版)のアプリ側: 対象の収集、モック生成 → シーンとして適用
/// (Undo 1 回・元のタイムラインは不変)、未設定・失敗・空プランの表示、メニュー項目。
/// 実サービスへの通信はしない(プロバイダと文字起こしは偽物に差し替える)。
@MainActor
final class RoughCutAppTests: XCTestCase {
    private func makeProject() -> Project {
        var p = Project.new()
        p.tracks = [Track(name: "映像"), Track(name: "音声")]
        var v = Clip(); v.id = "v1"; v.type = .video; v.src = "/tmp/a.mp4"; v.start = 0; v.duration = 60; v.offset = 10
        var a = Clip(); a.id = "a1"; a.type = .audio; a.src = "/tmp/b.wav"; a.start = 0; a.duration = 30; a.offset = 0
        p.tracks[0].clips = [v]
        p.tracks[1].clips = [a]
        return p
    }

    private let fakeTranscripts: (ProjectModel, Clip) -> [TranscriptSegment]? = { _, clip in
        switch clip.id {
        case "v1": return [TranscriptSegment(text: "導入", start: 12, end: 15),
                            TranscriptSegment(text: "本編", start: 30, end: 50)]
        case "a1": return [TranscriptSegment(text: "音声", start: 1, end: 4)]
        default: return nil
        }
    }

    private func makeModel(provider: FakeRoughCutProvider) -> ProjectModel {
        let m = ProjectModel(project: makeProject())
        m.notices = OneTimeNotices()
        m.roughCutUI = RoughCutUI(makeProvider: { provider }, transcripts: fakeTranscripts)
        return m
    }

    // MARK: 対象の収集

    func testSourcesCollectFromInjectedTranscripts() {
        let m = makeModel(provider: FakeRoughCutProvider(.plan(RoughCutPlan(segments: []))))
        let sources = m.roughCutSources()
        XCTAssertEqual(sources.map(\.clipId), ["v1", "a1"])
        XCTAssertEqual(sources[0].windowStart, 10)
        XCTAssertEqual(sources[0].windowEnd, 70)
        XCTAssertEqual(sources[0].segments.map(\.text), ["導入", "本編"])
        XCTAssertEqual(sources[1].windowEnd, 30)
    }

    // MARK: 生成 → 適用

    func testGenerateThenApplyCreatesSceneWithOneUndo() async {
        let fake = FakeRoughCutProvider(.raw(#"{"summary": "まとめ", "segments": [{"clip": "v1", "start": 30, "end": 50, "title": "本編"}, {"clip": "a1", "start": 1, "end": 4}, {"clip": "v1", "start": 12, "end": 15}]}"#))
        let m = makeModel(provider: fake)
        let sources = m.roughCutSources()
        let plan = await m.generateAIRoughCut(instruction: "面白いところだけ", targetDuration: 30, sources: sources)
        let got = try! XCTUnwrap(plan)
        XCTAssertEqual(got.segments.count, 3)
        XCTAssertEqual(got.droppedCount, 0)
        XCTAssertEqual(fake.requests.first?.instruction, "面白いところだけ")
        XCTAssertEqual(fake.requests.first?.targetDuration, 30)
        XCTAssertEqual(fake.requests.first?.clips.count, 2)
        XCTAssertNil(m.busyMessage)
        XCTAssertEqual(m.rootProject.scenes.count, 0, "生成だけではプロジェクトは変わらない")

        let tracksBefore = m.rootProject.tracks
        let name = m.applyAIRoughCut(got)
        XCTAssertEqual(name, "AIラフカット")
        XCTAssertEqual(m.rootProject.scenes.count, 1)
        let scene = m.rootProject.scenes[0]
        XCTAssertEqual(scene.name, "AIラフカット")
        XCTAssertEqual(scene.tracks.map(\.name), ["映像", "音声"])
        XCTAssertEqual(scene.tracks[0].clips.map(\.offset), [30, 12])
        XCTAssertEqual(scene.tracks[0].clips.map(\.start), [0, 20])
        XCTAssertEqual(scene.tracks[1].clips.map(\.offset), [1])
        XCTAssertEqual(m.rootProject.tracks, tracksBefore, "元のタイムラインは変えない")
        XCTAssertEqual(m.effectiveUndoManager.undoActionName, "AIラフカットを作成")
        XCTAssertTrue(m.statusText.contains("区間 3 件"))

        if m.isInsideScene { XCTAssertTrue(m.exitSceneScope()) }
        m.effectiveUndoManager.undo()
        XCTAssertEqual(m.rootProject.scenes.count, 0, "Undo 1 回でシーンが消える")
        m.effectiveUndoManager.redo()
        XCTAssertEqual(m.rootProject.scenes.count, 1)
    }

    func testSecondApplyGetsNumberedName() {
        let m = makeModel(provider: FakeRoughCutProvider(.plan(RoughCutPlan(segments: []))))
        let plan = RoughCutPlan(segments: [RoughCutSegment(clipId: "v1", start: 30, end: 40)])
        XCTAssertEqual(m.applyAIRoughCut(plan), "AIラフカット")
        if m.isInsideScene { XCTAssertTrue(m.exitSceneScope()) }
        XCTAssertEqual(m.applyAIRoughCut(plan), "AIラフカット 2")
        XCTAssertEqual(m.rootProject.scenes.map(\.name), ["AIラフカット", "AIラフカット 2"])
    }

    // MARK: 失敗してもプロジェクトは変わらない

    func testUnconfiguredShowsErrorAndChangesNothing() async {
        let m = ProjectModel(project: makeProject())
        m.notices = OneTimeNotices()
        m.roughCutUI = RoughCutUI(makeProvider: { throw TextGenerationError.notConfigured }, transcripts: fakeTranscripts)
        let before = m.rootProject
        let got = await m.generateAIRoughCut(instruction: "短く", targetDuration: nil, sources: m.roughCutSources())
        XCTAssertNil(got)
        XCTAssertEqual(m.errorTitle, "AIラフカットを使えません")
        XCTAssertTrue(m.errorMessage?.contains("設定されていません") == true)
        XCTAssertEqual(m.rootProject, before)
        XCTAssertNil(m.busyMessage)
    }

    func testNoSourcesShowsError() async {
        let m = makeModel(provider: FakeRoughCutProvider(.plan(RoughCutPlan(segments: []))))
        let before = m.rootProject
        let got = await m.generateAIRoughCut(instruction: "短く", targetDuration: nil, sources: [])
        XCTAssertNil(got)
        XCTAssertEqual(m.errorTitle, "AIラフカットを使えません")
        XCTAssertTrue(m.errorMessage?.contains("文字起こしのある素材クリップがタイムラインにありません") == true)
        XCTAssertEqual(m.rootProject, before)
    }

    func testGarbageResponseChangesNothing() async {
        let m = makeModel(provider: FakeRoughCutProvider(.raw("すみません、できません。")))
        let before = m.rootProject
        let got = await m.generateAIRoughCut(instruction: "短く", targetDuration: nil, sources: m.roughCutSources())
        XCTAssertNil(got)
        XCTAssertEqual(m.errorTitle, "ラフカットを作れませんでした")
        XCTAssertTrue(m.errorMessage?.contains("読み取れませんでした") == true)
        XCTAssertEqual(m.rootProject, before)
    }

    func testEmptyPlanChangesNothing() async {
        let m = makeModel(provider: FakeRoughCutProvider(.raw(#"{"segments": [{"clip": "ghost", "start": 0, "end": 10}]}"#)))
        let before = m.rootProject
        let got = await m.generateAIRoughCut(instruction: "短く", targetDuration: nil, sources: m.roughCutSources())
        XCTAssertNil(got)
        XCTAssertEqual(m.errorTitle, "ラフカットを作れませんでした")
        XCTAssertTrue(m.errorMessage?.contains("使える区間がありませんでした") == true)
        XCTAssertEqual(m.rootProject, before)
    }

    func testCancelledGoesToStatus() async {
        let m = makeModel(provider: FakeRoughCutProvider(.fail(.cancelled)))
        let before = m.rootProject
        let got = await m.generateAIRoughCut(instruction: "短く", targetDuration: nil, sources: m.roughCutSources())
        XCTAssertNil(got)
        XCTAssertEqual(m.errorTitle, "エラー", "エラー画面は出さない(タイトルは既定のまま)")
        XCTAssertNil(m.errorMessage)
        XCTAssertEqual(m.statusText, "ラフカットの生成をキャンセルしました")
        XCTAssertEqual(m.rootProject, before)
    }

    // MARK: メニュー

    func testMenuItemAndEnablement() {
        var s = MenuState()
        s.hasDocument = true
        XCTAssertTrue(AppMenuSpec.aiRoughCutItem(s).enabled)
        XCTAssertEqual(AppMenuSpec.aiRoughCutItem(s).command, .aiRoughCut)
        XCTAssertEqual(AppMenuSpec.aiRoughCutItem(s).title, "AIでラフカットを作る…")
        let noDoc = MenuState()
        XCTAssertFalse(AppMenuSpec.aiRoughCutItem(noDoc).enabled)
    }
}
