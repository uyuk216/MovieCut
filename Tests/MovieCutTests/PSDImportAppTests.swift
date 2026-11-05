import XCTest
import AppKit
import MovieCutCore
@testable import MovieCut

/// ファイル ▸ PSDを読み込む…(シートなしの取り込み口 `importPSD`)。小さな PSD(RAW)を組み立てて試す。
@MainActor
final class PSDImportAppTests: XCTestCase {
    private func be16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 0xff), UInt8(v & 0xff)] }
    private func be32(_ v: Int) -> [UInt8] { let u = UInt32(truncatingIfNeeded: v); return (0..<4).map { UInt8((u >> UInt32(24 - 8 * $0)) & 0xff) } }

    private func psd(width: Int, height: Int, layers: [(name: String, rect: (Int, Int, Int, Int), color: [UInt8], opacity: UInt8, visible: Bool)]) -> Data {
        var d: [UInt8] = Array("8BPS".utf8) + be16(1) + [UInt8](repeating: 0, count: 6) + be16(4) + be32(height) + be32(width) + be16(8) + be16(3)
        d += be32(0) + be32(0)
        var recs: [UInt8] = [], ch: [UInt8] = []
        for l in layers {
            let w = l.rect.3 - l.rect.1, h = l.rect.2 - l.rect.0
            recs += be32(l.rect.0) + be32(l.rect.1) + be32(l.rect.2) + be32(l.rect.3) + be16(4)
            let ids = [0, 1, 2, 0xffff]
            for id in ids { recs += be16(id) + be32(2 + w * h) }
            recs += Array("8BIM".utf8) + Array("norm".utf8) + [l.opacity, 0, l.visible ? 0 : 2, 0]
            let nm = Array(l.name.utf8)
            var extra = be32(0) + be32(0) + [UInt8(nm.count)] + nm
            extra += [UInt8](repeating: 0, count: (4 - (1 + nm.count) % 4) % 4)
            recs += be32(extra.count) + extra
            for k in 0..<4 { ch += be16(0) + [UInt8](repeating: l.color[k], count: w * h) }
        }
        var info = be16(layers.count) + recs + ch
        if info.count % 2 == 1 { info.append(0) }
        let misc = be32(info.count) + info
        d += be32(misc.count) + misc + be16(0)
        for _ in 0..<4 { d += [UInt8](repeating: 255, count: width * height) }
        return Data(d)
    }

    private func undoSteps(_ m: ProjectModel) -> Int { let u = m.effectiveUndoManager; var n = 0; while u.canUndo { u.undo(); n += 1 }; for _ in 0..<n { u.redo() }; return n }

    func testLayersBecomeClipsOnOwnLayersWithOneUndo() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("psdapp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("test.psd")
        try psd(width: 1920, height: 1080, layers: [
            ("背景", (0, 0, 1080, 1920), [200, 0, 0, 255], 255, true),
            ("顔", (270, 480, 810, 1440), [0, 200, 0, 255], 128, true),
            ("消す", (0, 0, 100, 100), [0, 0, 200, 255], 255, false),
        ]).write(to: file)

        var p = Project.new()
        let m = ProjectModel(project: p)
        p = m.project
        m.currentTime = 3
        let ids = await m.importPSD(url: file, mode: .layers, cacheRoot: dir.appendingPathComponent("cache"))
        XCTAssertEqual(ids.count, 2)
        let clips = ids.compactMap { id in m.project.allClips.first { $0.id == id } }
        XCTAssertEqual(clips.map(\.type), [.image, .image])
        XCTAssertEqual(clips.map(\.start), [3, 3])
        XCTAssertEqual(clips[0].duration, 5)
        XCTAssertEqual(try XCTUnwrap(clips[1].opacity), 128.0 / 255, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(clips[1].x), 0.5, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(clips[1].scale), 0.5, accuracy: 1e-6)
        // 下のレイヤーが小さい段番号
        let rows = ids.map { id in m.project.tracks.firstIndex { $0.clips.contains { $0.id == id } }! }
        XCTAssertLessThan(rows[0], rows[1])
        XCTAssertTrue(m.statusText.contains("非表示 1 枚"))
        for c in clips { XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(c.src))) }
        XCTAssertEqual(undoSteps(m), 1)
    }

    func testFlattenedAndBrokenFile() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("psdapp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.psd")
        try psd(width: 64, height: 36, layers: [("一", (0, 0, 36, 64), [1, 2, 3, 255], 255, true)]).write(to: file)
        let m = ProjectModel(project: .new())
        let ids = await m.importPSD(url: file, mode: .flattened, cacheRoot: dir.appendingPathComponent("c"))
        XCTAssertEqual(ids.count, 1)
        XCTAssertEqual(m.project.allClips.count, 1)
        let bad = dir.appendingPathComponent("bad.psd")
        try Data("nope".utf8).write(to: bad)
        let m2 = ProjectModel(project: .new())
        let none = await m2.importPSD(url: bad, mode: .layers, cacheRoot: dir.appendingPathComponent("c"))
        XCTAssertTrue(none.isEmpty)
        XCTAssertNotNil(m2.errorMessage)
        XCTAssertTrue(m2.project.allClips.isEmpty)
    }

    func testMenuItem() {
        var s = MenuState(); s.hasDocument = true
        let item = AppMenuSpec.file(s).first { $0.command == .importPSD }
        XCTAssertEqual(item?.title, "PSDを読み込む…")
        XCTAssertNil(item?.shortcut)
        XCTAssertEqual(item?.enabled, true)
        XCTAssertFalse(AppMenuSpec.file(MenuState()).first { $0.command == .importPSD }!.enabled)
        XCTAssertTrue(ClipEditing.isDroppableMedia(path: "/a/b.PSD"))
    }
}
