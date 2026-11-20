import XCTest
import MovieCutCore
@testable import MovieCut

/// ラベル付きステッパー行(LabeledStepperRow)の Undo 集約。
/// 行の書き込み経路(beginStepperSession → live 系で連続ステップ →
/// commitStepperSession)をモデル層で再現し、「長押し 1 セッション = Undo 1 回」
/// 「短押し = Undo 1 回」「値域の端で何も変わらないセッションは登録なし」
/// 「セッション外の 1 ステップ(キーボード経路)は 1 回ずつの編集」を固定する。
@MainActor
final class SheetStepperAppTests: XCTestCase {

    private func makeModel(_ clips: [Clip]) -> ProjectModel {
        var p = Project.new()
        p.tracks[0].clips = clips
        let m = ProjectModel(project: p)
        m.notices = OneTimeNotices()
        return m
    }

    private func clip(_ id: String, type: ClipType = .image) -> Clip {
        var c = Clip(); c.id = id; c.type = type; c.start = 0; c.duration = 2
        if type == .image { c.src = "/tmp/none.png" }
        return c
    }

    private func undoAll(_ m: ProjectModel) -> Int {
        var n = 0
        while m.effectiveUndoManager.canUndo { m.effectiveUndoManager.undo(); n += 1 }
        return n
    }

    // MARK: メッシュ格子(移行前は setClipProperty で 1 ステップ = 1 Undo だった行)

    func testMeshGridHoldSessionIsOneUndoStep() {
        let m = makeModel([clip("i")])
        m.selectedClipId = "i"
        m.ensureMeshWarp(clipId: "i")
        let baseCols = m.selectedClip?.meshWarp?.cols ?? -1
        XCTAssertEqual(baseCols, 3)

        // 長押し 1 セッション: 開始 → 連続 3 ステップ → 離す
        m.beginStepperSession()
        for _ in 0..<3 {
            let cur = m.selectedClip?.meshWarp?.cols ?? baseCols
            m.liveMeshGrid(cols: StepperValue.stepped(cur, by: 1, in: MeshWarp.minGrid...MeshWarp.maxGrid),
                           rows: m.selectedClip?.meshWarp?.rows ?? 3, clipId: "i")
        }
        XCTAssertEqual(m.selectedClip?.meshWarp?.cols, 6, "セッション中も値はすぐ反映される")
        m.commitStepperSession(ProjectModel.warpUndoName)

        m.effectiveUndoManager.undo()
        XCTAssertEqual(m.selectedClip?.meshWarp?.cols, 3, "セッションは 1 回の Undo で丸ごと戻る")
        XCTAssertEqual(undoAll(m), 1, "残りは用意の 1 回だけ(用意 1 回 + セッション 1 回で合計 2 回)")
    }

    func testMeshGridShortPressIsOneUndoStep() {
        let m = makeModel([clip("i")])
        m.selectedClipId = "i"
        m.ensureMeshWarp(clipId: "i")
        m.beginStepperSession()
        m.liveMeshGrid(cols: 4, rows: 3, clipId: "i")
        m.commitStepperSession(ProjectModel.warpUndoName)
        XCTAssertEqual(m.selectedClip?.meshWarp?.cols, 4)
        m.effectiveUndoManager.undo()
        XCTAssertEqual(m.selectedClip?.meshWarp?.cols, 3, "短押しも 1 回で戻る")
    }

    func testMeshGridSessionAtLimitRegistersNothing() {
        let m = makeModel([clip("i")])
        m.selectedClipId = "i"
        m.ensureMeshWarp(clipId: "i")
        m.setMeshGrid(cols: MeshWarp.maxGrid, rows: 3, clipId: "i")
        // 上限で押し続けても値は動かない → セッションは Undo に何も積まない
        m.beginStepperSession()
        for _ in 0..<3 {
            let cur = m.selectedClip?.meshWarp?.cols ?? MeshWarp.maxGrid
            m.liveMeshGrid(cols: StepperValue.stepped(cur, by: 1, in: MeshWarp.minGrid...MeshWarp.maxGrid),
                           rows: 3, clipId: "i")
        }
        m.commitStepperSession(ProjectModel.warpUndoName)
        XCTAssertEqual(m.selectedClip?.meshWarp?.cols, MeshWarp.maxGrid)
        XCTAssertEqual(undoAll(m), 2, "用意 + 上限までの変更だけ(セッションぶんは増えない)")
    }

    // MARK: ビジュアライザの本数(移行前は setClipProperty で 1 ステップ = 1 Undo だった行)

    /// InspectorView の行と同じ書き込み(最新の本数から 1 ステップぶんを live で書く)。
    private func stepVisualizerCount(_ m: ProjectModel, id: String, by delta: Int) {
        let cur = m.clip(id)?.visualizerOrDefault.countOrDefault ?? Visualizer.defaultCount
        let next = StepperValue.stepped(cur, by: delta, in: Visualizer.countRange)
        m.liveClipProperty({ $0.visualizer = ClipInspector.vizUpdated($0.visualizer) { $0.count = next } },
                           name: "ビジュアライザの本数の変更", clipId: id)
    }

    func testVisualizerCountHoldSessionIsOneUndoStep() {
        let m = makeModel([clip("a", type: .visualizer)])
        m.selectedClipId = "a"
        m.beginStepperSession()
        for _ in 0..<5 { stepVisualizerCount(m, id: "a", by: 1) }
        m.commitStepperSession("ビジュアライザの本数の変更")
        XCTAssertEqual(m.clip("a")?.visualizerOrDefault.countOrDefault, Visualizer.defaultCount + 5)
        XCTAssertEqual(undoAll(m), 1, "5 ステップの長押しが Undo 1 回にまとまる")
        XCTAssertEqual(m.clip("a")?.visualizerOrDefault.countOrDefault, Visualizer.defaultCount)
        XCTAssertNil(m.clip("a")?.visualizer, "既定に戻ると項目ごと消える")
    }

    // MARK: 図形の線の太さ(移行前は coalescedClipProperty だった行もセッション方式へ統一)

    private func stepStrokeWidth(_ m: ProjectModel, id: String, by delta: Double) {
        let cur = m.clip(id)?.figureOrDefault.strokeWidthOrDefault ?? 0
        let next = StepperValue.stepped(cur, by: delta, in: Figure.strokeWidthRange)
        m.liveClipProperty({ $0.figure = ClipInspector.figUpdated($0.figure) { $0.strokeWidth = next } },
                           name: "図形の線の太さの変更", clipId: id)
    }

    func testStrokeWidthHoldSessionIsOneUndoStep() {
        let m = makeModel([clip("s", type: .shape)])
        m.selectedClipId = "s"
        let base = m.clip("s")?.figureOrDefault.strokeWidthOrDefault ?? -1
        m.beginStepperSession()
        for _ in 0..<4 { stepStrokeWidth(m, id: "s", by: 1) }
        m.commitStepperSession("図形の線の太さの変更")
        XCTAssertEqual(m.clip("s")?.figureOrDefault.strokeWidthOrDefault ?? -1, base + 4, accuracy: 1e-9)
        XCTAssertEqual(undoAll(m), 1, "4 ステップの長押しが Undo 1 回にまとまる")
        XCTAssertEqual(m.clip("s")?.figureOrDefault.strokeWidthOrDefault ?? -1, base, accuracy: 1e-9)
    }

    // MARK: セッションの外枠

    func testEmptySessionRegistersNothing() {
        let m = makeModel([clip("i")])
        m.selectedClipId = "i"
        m.beginStepperSession()
        m.commitStepperSession("x")
        XCTAssertFalse(m.effectiveUndoManager.canUndo, "何も変えていないセッションは登録しない")
    }

    func testStepsOutsideSessionAreOneUndoEach() {
        // キーボード・VoiceOver 経路: セッションを通らない 1 ステップは従来どおり 1 回の編集。
        let m = makeModel([clip("a", type: .visualizer)])
        m.selectedClipId = "a"
        stepVisualizerCount(m, id: "a", by: 1)
        stepVisualizerCount(m, id: "a", by: 1)
        XCTAssertEqual(m.clip("a")?.visualizerOrDefault.countOrDefault, Visualizer.defaultCount + 2)
        XCTAssertEqual(undoAll(m), 2)
    }
}
