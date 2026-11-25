import XCTest
import AppKit
import MovieCutCore
@testable import MovieCut

/// 配線フォローアップバッチQ のアプリ側テスト。
/// F-1: プラグインエフェクトのメニュー到達・追加・初期値戻しと、プラグイン形式の書き出しメニュー到達・実行。
/// F-2: 顔ぼかし一括付与/解除のメニュー到達と Undo。
@MainActor
final class WiringFollowupsAppTests: XCTestCase {
    private func clip(_ id: String, _ type: ClipType, start: Double, dur: Double) -> Clip {
        var c = Clip(); c.id = id; c.type = type; c.start = start; c.duration = dur
        if type == .image || type == .video { c.src = "/tmp/none.png" }
        if type == .text { c.text = "テキスト"; c.fontSize = 80 }
        return c
    }

    private func makeModel() -> ProjectModel {
        var p = Project.new()
        p.tracks[0].clips = [clip("a", .image, start: 0, dur: 4), clip("t", .text, start: 10, dur: 2)]
        p.tracks[1].clips = [clip("v", .video, start: 2, dur: 6)]
        let m = ProjectModel(project: p)
        m.notices = OneTimeNotices()
        return m
    }

    private func undoSteps(_ m: ProjectModel) -> Int {
        let u = m.effectiveUndoManager
        var n = 0
        while u.canUndo { u.undo(); n += 1 }
        for _ in 0..<n { u.redo() }
        return n
    }

    // MARK: - F-2 顔ぼかしメニュー

    func testFaceBlurMenuItemsReflectStateAndPerformAppliesAndRemovesWithUndo() {
        let m = makeModel()
        var state = MenuState(model: m)
        let items = AppMenuSpec.faceBlurItems(state)
        XCTAssertEqual(items.map(\.command), [.faceBlurApplyAll, .faceBlurRemoveAll])
        XCTAssertTrue(items[0].enabled, "クリップがあるので一括付与は有効")
        XCTAssertFalse(items[1].enabled, "まだ付いていないので一括解除は無効")
        // 確認用の一覧(all)にも載っている(メニュー到達性の担保は MenuReachabilityTests が別途見る)。
        XCTAssertTrue(AppMenuSpec.all(state).contains { $0.command == .faceBlurApplyAll })
        XCTAssertTrue(AppMenuSpec.all(state).contains { $0.command == .faceBlurRemoveAll })

        AppMenu.perform(.faceBlurApplyAll, model: m)
        XCTAssertEqual(FaceBlurBulk.count(in: m.project), 2, "画像と映像に付く(テキストは対象外)")
        XCTAssertEqual(undoSteps(m), 1, "一括付与は 1 回の Undo")
        XCTAssertEqual(m.effectiveUndoManager.undoActionName, "顔ぼかしを一括で付ける")

        state = MenuState(model: m)
        XCTAssertEqual(state.faceBlurCount, 2)
        let items2 = AppMenuSpec.faceBlurItems(state)
        XCTAssertTrue(items2[1].enabled)
        XCTAssertEqual(items2[1].hint, "2 件に付いています")

        AppMenu.perform(.faceBlurRemoveAll, model: m)
        XCTAssertEqual(FaceBlurBulk.count(in: m.project), 0)
        XCTAssertEqual(undoSteps(m), 2, "一括解除も 1 回の Undo(累計 2)")
        m.effectiveUndoManager.undo()
        XCTAssertEqual(FaceBlurBulk.count(in: m.project), 2, "解除の Undo で戻る")
    }

    func testFaceBlurModelFunctionsSkipLockedAndReportActualCount() {
        var p = Project.new()
        p.tracks[0].clips = [clip("a", .image, start: 0, dur: 2)]
        p.tracks[1].clips = [clip("b", .image, start: 0, dur: 2)]
        p.tracks[1].locked = true
        let m = ProjectModel(project: p)
        m.notices = OneTimeNotices()
        XCTAssertEqual(m.applyFaceBlurToAll(), 1, "ロックされたレイヤーの分は数えない")
        XCTAssertFalse(FaceBlurBulk.hasFaceBlur(m.clip("b")!))
        XCTAssertTrue(FaceBlurBulk.hasFaceBlur(m.clip("a")!))
        XCTAssertEqual(m.statusText, "1 個のクリップに顔ぼかしを付けました")
        XCTAssertEqual(m.removeAllFaceBlur(), 1)
        XCTAssertEqual(m.statusText, "1 個のクリップから顔ぼかしを外しました")
    }

    func testFaceBlurModelFunctionsReportZeroWhenNoTargets() {
        var p = Project.new()
        p.tracks[0].clips = [clip("t", .text, start: 0, dur: 2)]
        let m = ProjectModel(project: p)
        m.notices = OneTimeNotices()
        XCTAssertEqual(m.applyFaceBlurToAll(), 0, "対象(映像・画像・複合)が無ければ 0 で、Undo も積まない")
        XCTAssertEqual(undoSteps(m), 0)
        XCTAssertEqual(m.removeAllFaceBlur(), 0)
        XCTAssertEqual(undoSteps(m), 0)
    }

    // MARK: - F-1 プラグインエフェクトのメニューと追加

    func testPluginEffectMenuItemsAndAddSelectedClip() {
        let m = makeModel()
        m.selectedClipId = "a"
        let state = MenuState(model: m)
        XCTAssertEqual(state.pluginEffectDescriptors.map(\.id), [InvertEffectPlugin.effectID, PosterizeEffectPlugin.effectID])
        let items = AppMenuSpec.pluginEffectItems(state)
        XCTAssertEqual(items.map(\.command), [.effectAddPlugin(InvertEffectPlugin.effectID), .effectAddPlugin(PosterizeEffectPlugin.effectID)])
        XCTAssertTrue(items.allSatisfy { $0.enabled }, "エフェクト対応クリップを選んでいるので有効")
        XCTAssertTrue(AppMenuSpec.all(state).contains { $0.command == .effectAddPlugin(InvertEffectPlugin.effectID) })

        AppMenu.perform(.effectAddPlugin(InvertEffectPlugin.effectID), model: m)
        let effects = m.clip("a")?.effects ?? []
        XCTAssertEqual(effects.map(\.kind), [InvertEffectPlugin.effectID])
        XCTAssertEqual(effects[0].params["amount"], 1, "記述子の初期値で足される")
        XCTAssertEqual(undoSteps(m), 1)

        XCTAssertFalse(m.addPluginEffectSelected("plugin.unknown"), "無いプラグインは何もしない")
        XCTAssertEqual(m.clip("a")?.effects.count, 1)
    }

    func testPluginEffectResetReturnsToDescriptorDefaults() {
        let m = makeModel()
        m.selectedClipId = "a"
        XCTAssertTrue(m.addPluginEffectSelected(PosterizeEffectPlugin.effectID))
        m.edit("値を変える") { p in p.tracks[0].clips[0].effects[0].params["levels"] = 3 }
        XCTAssertEqual(m.clip("a")?.effects[0].params["levels"], 3)
        XCTAssertTrue(m.resetEffect(at: 0, clipId: "a"), "プラグインエフェクトも初期値に戻せる")
        XCTAssertEqual(m.clip("a")?.effects[0].params["levels"], 6, "記述子の初期値(6)に戻る")
        XCTAssertFalse(m.resetEffect(at: 0, clipId: "a"), "すでに初期値なら何もしない")
    }

    // MARK: - F-1 プラグイン書き出しのメニューと実行

    func testPluginExportMenuItemsAndProjectInfoExportRuns() async throws {
        // 書き出しは素材欠落で止まるため、素材を持たないテキストだけのプロジェクトで確かめる。
        var proj = Project.new()
        proj.tracks[0].clips = [clip("t", .text, start: 0, dur: 3)]
        let m = ProjectModel(project: proj)
        m.notices = OneTimeNotices()
        let state = MenuState(model: m)
        XCTAssertEqual(state.pluginExportFormats.map(\.id), [GIFExportPlugin.formatID, ProjectInfoExportPlugin.formatID])
        let items = AppMenuSpec.pluginExportItems(state)
        XCTAssertEqual(items.map(\.command), [.exportPluginFormat(GIFExportPlugin.formatID), .exportPluginFormat(ProjectInfoExportPlugin.formatID)])
        XCTAssertTrue(items.allSatisfy { $0.enabled })
        XCTAssertTrue(AppMenuSpec.all(state).contains { $0.command == .exportPluginFormat(ProjectInfoExportPlugin.formatID) })

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wiring-q-app-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("info.json")
        let outcome = await m.runPluginExport(formatID: ProjectInfoExportPlugin.formatID, to: out)
        switch outcome { case .success: break; default: return XCTFail("プラグイン書き出しが成功するはず: \(outcome)") }
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: out)) as? [String: Any]
        XCTAssertEqual(json?["width"] as? Int, m.project.width)
        XCTAssertEqual(json?["clips"] as? Int, 1)

        // 担当プラグインが無い形式は、黙って別形式に化けず失敗する。
        let bogus = dir.appendingPathComponent("bogus.bin")
        let outcome2 = await m.runPluginExport(formatID: "no-such-format", to: bogus)
        switch outcome2 { case .failure: break; default: return XCTFail("未知の形式は失敗のはず: \(outcome2)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: bogus.path))
    }
}
