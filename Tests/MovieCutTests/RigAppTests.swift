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
