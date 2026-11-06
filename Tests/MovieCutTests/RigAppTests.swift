import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
import MovieCutCore
@testable import MovieCut

/// パーツ式立ち絵: インスペクタの編集(1 回 = Undo 1 回、変わらない編集は履歴に載せない)・取り込み・メニュー項目。
@MainActor
final class RigAppTests: XCTestCase {
    var tmp: URL!
    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("rig-app-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private func png(_ dir: URL, _ name: String, box: CGRect? = nil) throws {
        let ctx = CGContext(data: nil, width: 20, height: 20, bitsPerComponent: 8, bytesPerRow: 80, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(box ?? CGRect(x: 0, y: 0, width: 20, height: 20))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = CGImageDestinationCreateWithURL(dir.appendingPathComponent(name) as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil); XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    private func folder() throws -> URL {
        let d = tmp.appendingPathComponent("れいむ")
        for i in 1...3 { try png(d.appendingPathComponent("目"), "目 (\(i)).png", box: CGRect(x: 2, y: 8, width: 16, height: CGFloat(2 + i * 3))) }
        for i in 1...4 { try png(d, "口 (\(i)).png", box: CGRect(x: 8, y: 2, width: CGFloat(i * 2), height: CGFloat(i * 2))) }
        try png(d, "体 (1).png"); try png(d, "眉 (1).png"); try png(d, "眉 (2).png")
        return d
    }

    private func undoSteps(_ m: ProjectModel) -> Int { let u = m.effectiveUndoManager; var n = 0; while u.canUndo { u.undo(); n += 1 }; for _ in 0..<n { u.redo() }; return n }

    private func modelWithRig() async throws -> (ProjectModel, String) {
        let m = ProjectModel(project: Project.new())
        let imported = await m.importRigFolder(url: try folder())
        let id = try XCTUnwrap(imported)
        return (m, id)
    }

    func testAlignmentAndBehindEditsAreOneUndoAndNoOpsLeaveNoHistory() async throws {
        let (m, id) = try await modelWithRig()
        let base = undoSteps(m)
        m.rigSetAlignment(tachieId: id, .bottom)   // 既に下揃え(未設定)
        m.rigSetSlotBehind(tachieId: id, slot: "眉", behind: false)
        XCTAssertEqual(undoSteps(m), base, "何も変わらない編集は履歴に載せない")
        m.rigSetAlignment(tachieId: id, .center)
        XCTAssertEqual(m.tachie(id)?.rig?.alignment, .center)
        m.rigSetSlotBehind(tachieId: id, slot: "眉", behind: true)
        XCTAssertEqual(m.tachie(id)?.rig?.slot("眉")?.behindBody, true)
        XCTAssertEqual(undoSteps(m), base + 2)
        m.effectiveUndoManager.undo(); XCTAssertNil(m.tachie(id)?.rig?.slot("眉")?.behindBody)
        m.effectiveUndoManager.undo(); XCTAssertNil(m.tachie(id)?.rig?.alignment)
    }

    /// 20×20 の体・眉・目・口と、30×30 の別サイズの眉・目・口を置いたフォルダ(2 グループ)
    private func twoSizeFolder() throws -> URL {
        let d = try folder()
        func big(_ name: String) throws {
            let ctx = CGContext(data: nil, width: 30, height: 30, bitsPerComponent: 8, bytesPerRow: 120, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 4, y: 4, width: 10, height: 10))
            let sub = d.appendingPathComponent("別サイズ"); try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            let dest = CGImageDestinationCreateWithURL(sub.appendingPathComponent(name) as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, ctx.makeImage()!, nil); XCTAssertTrue(CGImageDestinationFinalize(dest))
        }
        for n in ["眉 (1).png", "眉 (2).png", "目 (1).png", "目 (2).png", "口 (1).png", "口 (2).png"] { try big(n) }
        return d
    }

    func testMultiSizeFolderOpensGroupSheetAndImportsSeparateTachiesInOneUndo() async throws {
        let m = ProjectModel(project: Project.new())
        let first = await m.importRigFolder(url: try twoSizeFolder())
        XCTAssertNil(first, "グループが複数あるときはシートを出して、まだ足さない")
        XCTAssertTrue(m.project.tachies.isEmpty)
        let plan = try XCTUnwrap(m.rigGroupPlan)
        XCTAssertEqual(plan.groups.count, 2)
        XCTAssertEqual(plan.selected.count, 2)
        XCTAssertEqual(Set(plan.groups.map { "\($0.width)×\($0.height)" }), ["20×20", "30×30"])
        let before = undoSteps(m)
        let ids = m.importRigGroups(plan.chosen)
        XCTAssertEqual(ids.count, 2)
        XCTAssertNil(m.rigGroupPlan)
        XCTAssertEqual(m.project.tachies.count, 2)
        XCTAssertEqual(Set(m.project.tachies.map(\.name)).count, 2, "名前は重ならない")
        XCTAssertEqual(undoSteps(m), before + 1)
        m.effectiveUndoManager.undo()
        XCTAssertTrue(m.project.tachies.isEmpty)
    }

    func testGroupSheetCanImportOnlyChosenAndCancelAddsNothing() async throws {
        let m = ProjectModel(project: Project.new())
        _ = await m.importRigFolder(url: try twoSizeFolder())
        var plan = try XCTUnwrap(m.rigGroupPlan)
        plan.selected = [1]
        XCTAssertEqual(plan.chosen.count, 1)
        _ = m.importRigGroups(plan.chosen)
        XCTAssertEqual(m.project.tachies.count, 1)
        _ = await m.importRigFolder(url: try twoSizeFolder())
        m.rigGroupPlan = nil   // キャンセル
        XCTAssertEqual(m.project.tachies.count, 1)
    }

    func testPrewarmSignatureOnlyChangesWithTachiesInUseAndPrewarmFillsTheModelCache() async throws {
        let (m, id) = try await modelWithRig()
        XCTAssertNil(ProjectModel.prewarmSignature(m.project), "立ち絵クリップが無ければ先読みしない")
        XCTAssertNotNil(m.addTachieClip(tachieId: id))
        let s1 = try XCTUnwrap(ProjectModel.prewarmSignature(m.project))
        // 立ち絵と関係ない編集では変わらない
        var p = m.project; p.bg = "#123456"
        XCTAssertEqual(ProjectModel.prewarmSignature(p), s1)
        // パーツの選択・揃え・位置の補正が変わると変わる
        XCTAssertNotEqual(ProjectModel.prewarmSignature(TachieEditing.update(m.project, id: id) { $0.rig = RigEditing.setAlignment($0.rig!, .center) }), s1)
        // 先読み(背景)で、モデルの素材キャッシュに合成が入る。同じ指紋では 2 回目は何もしない
        XCTAssertEqual(m.assets.rigCache.cachedFrameCount, 0)
        m.prewarmTachies()
        let deadline = Date().addingTimeInterval(10)
        while m.assets.rigCache.cachedFrameCount == 0 && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertGreaterThan(m.assets.rigCache.cachedFrameCount, 0)
        let sig = m.prewarmSignature
        m.prewarmTachies()
        XCTAssertEqual(m.prewarmSignature, sig)
    }

    private func voiceClip(_ id: String, start: Double, duration: Double) -> Clip {
        var c = Clip(); c.id = id; c.type = .voice; c.start = start; c.duration = duration; return c
    }

    func testFollowProjectEndExtendsOnLaterEditsInTheSameUndoAndStopsOnManualTrim() async throws {
        let (m, id) = try await modelWithRig()
        m.edit("声") { $0.tracks.append({ var t = Track(name: "声"); t.clips = [self.voiceClip("v0", start: 0, duration: 4)]; return t }()) }
        m.currentTime = 0
        m.placeTachie(id, followsEnd: true)
        let cid = try XCTUnwrap(m.selectedClipId)
        var c = try XCTUnwrap(m.project.allClips.first { $0.id == cid })
        XCTAssertEqual(c.followsProjectEnd, true)
        XCTAssertEqual(c.duration, 4, accuracy: 1e-9, "再生位置からプロジェクトの終わりまで")
        // 後から声を足すと、同じ編集(Undo 1 回)で立ち絵クリップも伸びる
        let steps = undoSteps(m)
        m.edit("声を足す") { p in
            let vi = p.tracks.firstIndex { $0.clips.contains { $0.id == "v0" } }!
            p.tracks[vi].clips.append(self.voiceClip("v1", start: 6, duration: 3))
        }
        c = try XCTUnwrap(m.project.allClips.first { $0.id == cid })
        XCTAssertEqual(c.duration, 9, accuracy: 1e-9)
        XCTAssertEqual(undoSteps(m), steps + 1)
        m.effectiveUndoManager.undo()
        XCTAssertEqual(m.project.allClips.first { $0.id == cid }?.duration ?? 0, 4, accuracy: 1e-9, "Undo 1 回で声も伸びも戻る")
        m.effectiveUndoManager.redo()
        // インスペクタの切り替え
        m.setTachieFollowsProjectEnd(clipId: cid, false)
        XCTAssertNil(m.project.allClips.first { $0.id == cid }?.followsProjectEnd)
        m.edit("声を足す") { $0.tracks[1].clips.append(self.voiceClip("v2", start: 9, duration: 2)) }
        XCTAssertEqual(m.project.allClips.first { $0.id == cid }?.duration ?? 0, 9, accuracy: 1e-9, "やめたら伸びない")
        m.setTachieFollowsProjectEnd(clipId: cid, true)
        XCTAssertEqual(m.project.allClips.first { $0.id == cid }?.duration ?? 0, 11, accuracy: 1e-9, "オンにするとその場で合わせる")
        // 長さを手で変えるとやめる
        m.edit("トリム") { p in for ti in p.tracks.indices { for ci in p.tracks[ti].clips.indices where p.tracks[ti].clips[ci].id == cid { p.tracks[ti].clips[ci].duration = 3 } } }
        let t = try XCTUnwrap(m.project.allClips.first { $0.id == cid })
        XCTAssertEqual(t.duration, 3); XCTAssertNil(t.followsProjectEnd)
    }

    func testPlaceWithoutFollowingKeepsFiveSecondsAndWritesNothingNew() async throws {
        let (m, id) = try await modelWithRig()
        m.placeTachie(id)
        let c = try XCTUnwrap(m.project.allClips.first { $0.type == .tachie })
        XCTAssertEqual(c.duration, 5); XCTAssertNil(c.followsProjectEnd)
        let text = String(decoding: try m.project.encoded(), as: UTF8.self)
        XCTAssertFalse(text.contains("followsProjectEnd"))
    }

    func testExpressionAtPlayheadIsOneUndoAndNoOpsLeaveNoHistory() async throws {
        let (m, id) = try await modelWithRig()
        _ = m.rigAddExpression(tachieId: id, name: "笑顔")
        m.edit("声") { $0.tracks.append({ var t = Track(name: "声"); t.clips = [self.voiceClip("v0", start: 0, duration: 4)]; return t }()) }
        m.edit("声2") { $0.tracks[$0.tracks.count - 1].clips[0].text = "こんにちは" }
        m.currentTime = 0
        let cid = try XCTUnwrap(m.addTachieClip(tachieId: id, start: 0, duration: 4))
        m.currentTime = 1
        let steps = undoSteps(m)
        m.setTachieExpressionAtPlayhead(clipId: cid, tag: nil)   // もともと通常
        m.currentTime = 9
        m.setTachieExpressionAtPlayhead(clipId: cid, tag: "笑顔")  // 声が無い
        XCTAssertEqual(undoSteps(m), steps, "何も変わらない編集は履歴に載せない")
        XCTAssertTrue(m.statusText.contains("連動する声がありません"))
        m.currentTime = 1
        m.setTachieExpressionAtPlayhead(clipId: cid, tag: "笑顔")
        XCTAssertEqual(m.project.allClips.first { $0.id == "v0" }?.text, "[笑顔]こんにちは")
        XCTAssertEqual(undoSteps(m), steps + 1)
        m.setTachieExpressionAtPlayhead(clipId: cid, tag: nil)
        XCTAssertEqual(m.project.allClips.first { $0.id == "v0" }?.text, "こんにちは")
        m.effectiveUndoManager.undo()
        XCTAssertEqual(m.project.allClips.first { $0.id == "v0" }?.text, "[笑顔]こんにちは")
        m.effectiveUndoManager.undo()
        XCTAssertEqual(m.project.allClips.first { $0.id == "v0" }?.text, "こんにちは")
    }

    func testImportFolderAddsTachieWithRigAsOneUndoStep() async throws {
        let m = ProjectModel(project: Project.new())
        let chars = m.project.characters.count
        let imported = await m.importRigFolder(url: try folder())
        let id = try XCTUnwrap(imported)
        XCTAssertEqual(m.project.characters.count, chars, "取り込みはキャラクターを作らない(声と字幕は別)")
        XCTAssertEqual(m.project.tachies.count, 1)
        let t = try XCTUnwrap(m.tachie(id))
        XCTAssertEqual(t.name, "れいむ")
        XCTAssertEqual(t.rig?.slots.map(\.name), ["体", "眉", "目", "口"])
        XCTAssertEqual(t.rig?.slot("目")?.parts.count, 3)
        XCTAssertEqual(m.selectedTachieId, id)
        XCTAssertEqual(undoSteps(m), 1)
        m.effectiveUndoManager.undo()
        XCTAssertTrue(m.project.tachies.isEmpty)
        // 画像の無いフォルダ
        let empty = tmp.appendingPathComponent("empty"); try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let none = await m.importRigFolder(url: empty)
        XCTAssertNil(none); XCTAssertNotNil(m.errorMessage)
    }

    func testSelectIsOneUndoAndNoOpRegistersNothing() async throws {
        let (m, id) = try await modelWithRig()
        let steps = undoSteps(m)
        m.rigSelect(tachieId: id, slot: "目", index: 0)          // 今と同じ
        m.rigSelect(tachieId: id, slot: "目", index: 99)         // 範囲外
        m.rigSelect(tachieId: id, slot: "ない", index: 0)
        XCTAssertEqual(undoSteps(m), steps, "何も変わらない編集は履歴に載せない")
        m.rigSelect(tachieId: id, slot: "目", index: 2)
        XCTAssertEqual(m.tachie(id)?.rig?.slot("目")?.active, 2)
        XCTAssertEqual(undoSteps(m), steps + 1)
        m.effectiveUndoManager.undo()
        XCTAssertEqual(m.tachie(id)?.rig?.slot("目")?.active, 0)
    }

    func testBlinkAndMouthAssignmentsAreOneStepEach() async throws {
        let (m, id) = try await modelWithRig()
        m.rigSelect(tachieId: id, slot: "目", index: 2)
        var steps = undoSteps(m)
        m.rigAssignBlink(tachieId: id)
        XCTAssertEqual(m.tachie(id)?.rig?.blink, 2)
        XCTAssertEqual(undoSteps(m), steps + 1); steps += 1
        m.rigAssignBlink(tachieId: id)                            // 同じ割り当て
        XCTAssertEqual(undoSteps(m), steps)
        m.rigSelect(tachieId: id, slot: "口", index: 1); steps += 1
        for role in ["closed", "open", "a", "i", "u", "e", "o"] { m.rigAssignMouth(tachieId: id, role: role); steps += 1 }
        XCTAssertEqual(m.tachie(id)?.rig?.mouthClosed, 1)
        XCTAssertEqual(m.tachie(id)?.rig?.vowels?.count, 5)
        XCTAssertEqual(undoSteps(m), steps)
        m.rigAssignMouth(tachieId: id, role: "a")                 // 同じ
        XCTAssertEqual(undoSteps(m), steps)
        m.rigAssignMouth(tachieId: id, role: "a", use: false)
        XCTAssertNil(m.tachie(id)?.rig?.vowels?["a"])
        m.rigClearBlink(tachieId: id)
        XCTAssertNil(m.tachie(id)?.rig?.blink)
        m.rigClearBlink(tachieId: id)
        XCTAssertEqual(undoSteps(m), steps + 2)
    }

    func testExpressionAddRenameDeleteCaptureCurrentSelection() async throws {
        let (m, id) = try await modelWithRig()
        m.rigSelect(tachieId: id, slot: "眉", index: 1)
        m.rigSelect(tachieId: id, slot: "口", index: 2)
        var steps = undoSteps(m)
        let name = try XCTUnwrap(m.rigAddExpression(tachieId: id))
        XCTAssertEqual(name, "表情1")
        XCTAssertEqual(m.tachie(id)?.rig?.expressions?[name]?["口"], 2)
        XCTAssertEqual(m.tachie(id)?.rig?.expressions?[name]?["眉"], 1)
        steps += 1; XCTAssertEqual(undoSteps(m), steps)
        XCTAssertEqual(m.rigAddExpression(tachieId: id), "表情2", "同じ内容でも別名で追加できる")
        steps += 1
        m.rigRenameExpression(tachieId: id, from: "表情1", to: "笑顔")
        XCTAssertNotNil(m.tachie(id)?.rig?.expressions?["笑顔"]); steps += 1
        m.rigRenameExpression(tachieId: id, from: "笑顔", to: "表情2")     // 既にある名前
        m.rigRenameExpression(tachieId: id, from: "笑顔", to: "[x]")
        m.rigRenameExpression(tachieId: id, from: "ない", to: "y")
        XCTAssertEqual(undoSteps(m), steps)
        // 更新: 選択を変えてから上書き
        m.rigSelect(tachieId: id, slot: "口", index: 0); steps += 1
        m.rigRecaptureExpression(tachieId: id, name: "笑顔"); steps += 1
        XCTAssertEqual(m.tachie(id)?.rig?.expressions?["笑顔"]?["口"], 0)
        m.rigRecaptureExpression(tachieId: id, name: "笑顔")               // 同じ内容
        XCTAssertEqual(undoSteps(m), steps)
        // 選ぶ: その表情のパーツが今の選択になる
        m.rigSelect(tachieId: id, slot: "眉", index: 0); steps += 1
        m.rigApplyExpression(tachieId: id, name: "表情2"); steps += 1
        XCTAssertEqual(m.tachie(id)?.rig?.slot("眉")?.active, 1)
        XCTAssertEqual(undoSteps(m), steps)
        m.rigDeleteExpression(tachieId: id, name: "笑顔"); m.rigDeleteExpression(tachieId: id, name: "表情2"); steps += 2
        XCTAssertNil(m.tachie(id)?.rig?.expressions)
        m.rigDeleteExpression(tachieId: id, name: "ない")
        XCTAssertEqual(undoSteps(m), steps)
    }

    func testEditsOnCharacterWithoutRigDoNothing() {
        let m = ProjectModel(project: Project.new())
        let id = m.project.characters[0].id
        m.rigSelect(tachieId: id, slot: "目", index: 0)
        m.rigAssignBlink(tachieId: id)
        XCTAssertNil(m.rigAddExpression(tachieId: id))
        XCTAssertFalse(m.effectiveUndoManager.canUndo)
    }

    func testRigCharacterSurvivesSaveAndLoad() async throws {
        let (m, id) = try await modelWithRig()
        m.rigSelect(tachieId: id, slot: "目", index: 1); m.rigAssignBlink(tachieId: id); _ = m.rigAddExpression(tachieId: id, name: "笑顔")
        let url = tmp.appendingPathComponent("p.mcpjc")
        try m.project.save(to: url)
        let back = try Project.load(from: url)
        XCTAssertEqual(back.tachies.first { $0.id == id }?.rig, m.tachie(id)?.rig)
        // 未使用素材の判定: リグのパーツは使用中
        XCTAssertTrue(UnusedMedia.usedPaths(in: back).contains(try XCTUnwrap(m.tachie(id)?.rig?.slots.first?.parts.first)))
    }

    func testMenuItemsHaveTitlesNoShortcutAndReasons() {
        var s = MenuState(); s.hasDocument = true
        for (cmd, title) in [(MenuCommand.importRigFolder, "立ち絵パーツのフォルダを読み込む…"), (.importRigPSD, "PSDから立ち絵を作る…")] {
            let item = AppMenuSpec.file(s).first { $0.command == cmd }
            XCTAssertEqual(item?.title, title)
            XCTAssertNil(item?.shortcut)
            XCTAssertEqual(item?.enabled, true)
            let off = AppMenuSpec.file(MenuState()).first { $0.command == cmd }!
            XCTAssertFalse(off.enabled)
            XCTAssertNotNil(AppMenuSpec.disabledReason(for: off, state: MenuState()), "使えない理由が出る")
            var locked = s; locked.isLocked = true
            let lockedItem = AppMenuSpec.file(locked).first { $0.command == cmd }!
            XCTAssertFalse(lockedItem.enabled)
            XCTAssertNotNil(AppMenuSpec.disabledReason(for: lockedItem, state: locked))
        }
    }
}
