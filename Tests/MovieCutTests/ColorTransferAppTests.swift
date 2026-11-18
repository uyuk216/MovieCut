import XCTest
import SwiftUI
import AppKit
import MovieCutCore
@testable import MovieCut

/// 色調転写(#58)のアプリ側: 参照画像の読み込み(1 操作 = 1 Undo)とメニュー項目。計算は MovieCutCore の ColorTransferTests が担う。
@MainActor
final class ColorTransferAppTests: XCTestCase {
    private func clip(_ id: String, _ type: ClipType, start: Double, dur: Double) -> Clip {
        var c = Clip(); c.id = id; c.type = type; c.start = start; c.duration = dur
        if type == .image || type == .video { c.src = "/tmp/none.png" }
        if type == .audio { c.src = "/tmp/none.wav"; c.srcDuration = dur }
        return c
    }

    private func makeModel() -> ProjectModel {
        var p = Project.new()
        p.fps = 60
        p.tracks[0].clips = [clip("a", .image, start: 0, dur: 4), clip("m", .audio, start: 14, dur: 6)]
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

    private func solidPNG(_ dir: URL, _ name: String) throws -> URL {
        let c = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(CGColor(srgbRed: 0.8, green: 0.5, blue: 0.2, alpha: 1))
        c.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        let url = dir.appendingPathComponent(name)
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, c.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    func testLoadReferenceIsOneUndoStepAndNoOpRegistersNothing() throws {
        let m = makeModel()
        let u = m.effectiveUndoManager
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("transfer-app-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let good = try solidPNG(dir, "ref.png")
        let bad = dir.appendingPathComponent("bad.png")
        try "not an image".write(to: bad, atomically: true, encoding: .utf8)
        m.selectedClipId = "a"
        XCTAssertTrue(m.loadColorTransferReference(from: good))
        XCTAssertEqual(m.clip("a")?.effects.map(\.kind), ["colorTransfer"])
        XCTAssertEqual(m.clip("a")?.effects[0].path, good.path)
        XCTAssertEqual(undoSteps(m), 1)
        XCTAssertTrue((u.undoActionName).hasPrefix("色調転写の参照"))
        XCTAssertFalse(m.loadColorTransferReference(from: good), "同じファイルは何も変えない")
        XCTAssertFalse(m.loadColorTransferReference(from: bad), "画像でないファイルは断る")
        XCTAssertEqual(m.clip("a")?.effects.count, 1)
        XCTAssertEqual(undoSteps(m), 1)
        u.undo()
        XCTAssertEqual(m.clip("a")?.effects.count, 0)
        // 音声クリップには付けられない
        m.selectedClipId = "m"
        XCTAssertFalse(m.loadColorTransferReference(from: good))
    }

    func testColorTransferMenuItem() {
        var s = MenuState()
        s.hasDocument = true; s.canExport = true
        s.resolutionKey = "1920x1080"; s.codec = "h264"; s.bg = "#000000"
        s.canEffect = true
        let item = AppMenuSpec.colorTransferItem(s)
        XCTAssertEqual(item.title, "色調転写の参照画像…"); XCTAssertEqual(item.command, .colorTransferLoad)
        XCTAssertTrue(item.enabled); XCTAssertNil(item.shortcut)
        var off = MenuState(); off.hasDocument = true
        XCTAssertFalse(AppMenuSpec.colorTransferItem(off).enabled)
        XCTAssertTrue(AppMenuSpec.all(s).contains { $0.command == .colorTransferLoad })
    }
}
