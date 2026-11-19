import XCTest
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import MovieCutCore
@testable import MovieCut

/// ファイル ▸ SVGを読み込む… / MIDIを読み込む… / 連番画像を読み込む…(シートなしの取り込み口)。
@MainActor
final class InputFormatsAppTests: XCTestCase {
    private var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("inputapp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func undoSteps(_ m: ProjectModel) -> Int { let u = m.effectiveUndoManager; var n = 0; while u.canUndo { u.undo(); n += 1 }; for _ in 0..<n { u.redo() }; return n }

    // MARK: ヘルパー

    private func writeSVG() throws -> URL {
        let url = dir.appendingPathComponent("sample.svg")
        try ##"<svg xmlns="http://www.w3.org/2000/svg" width="200" height="100" viewBox="0 0 200 100"><rect width="200" height="100" fill="#ff0000"/></svg>"##
            .write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func vlq(_ v: Int) -> [UInt8] {
        var stack = [UInt8(v & 0x7f)]
        var rest = v >> 7
        while rest > 0 { stack.insert(UInt8(rest & 0x7f) | 0x80, at: 0); rest >>= 7 }
        return stack
    }
    private func be16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 0xff), UInt8(v & 0xff)] }
    private func be32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8((v >> (24 - 8 * $0)) & 0xff) } }

    /// C4 を 0.5 秒(120BPM・480tick)鳴らすだけの MIDI。
    private func writeMIDI() throws -> URL {
        var ev: [UInt8] = []
        ev += vlq(0) + [0xff, 0x51, 0x03, 0x07, 0xa1, 0x20]   // テンポ 500000us
        ev += vlq(0) + [0x90, 60, 100]
        ev += vlq(480) + [0x80, 60, 0]
        ev += vlq(0) + [0xff, 0x2f, 0x00]
        var d = Array("MThd".utf8) + be32(6) + be16(0) + be16(1) + be16(480)
        d += Array("MTrk".utf8) + be32(ev.count) + ev
        let url = dir.appendingPathComponent("song.mid")
        try Data(d).write(to: url)
        return url
    }

    private func writeFrame(_ name: String, _ c: (UInt8, UInt8, UInt8)) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let ctx = CGContext(data: nil, width: 20, height: 20, bitsPerComponent: 8, bytesPerRow: 80, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: CGFloat(c.0) / 255, green: CGFloat(c.1) / 255, blue: CGFloat(c.2) / 255, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    // MARK: - SVG

    func testImportSVGPlacesRasterizedImageClipWithOneUndo() async throws {
        let url = try writeSVG()
        let m = ProjectModel(project: Project.new())
        m.currentTime = 3
        let cache = dir.appendingPathComponent("cache")
        let ids = await m.importSVG(url: url, cacheRoot: cache)
        XCTAssertEqual(ids.count, 1)
        let clip = try XCTUnwrap(m.project.allClips.first { $0.id == ids[0] })
        XCTAssertEqual(clip.type, .image)
        XCTAssertEqual(clip.start, 3)
        let src = try XCTUnwrap(clip.src)
        XCTAssertTrue(src.hasSuffix("image.png"))
        // キャンバスに収まる解像度で画像化されている
        let info = try XCTUnwrap(SVGParser.info(atPath: url.path))
        let expected = SVGImporter.fittedPixelSize(info: info, maxWidth: m.project.width, maxHeight: m.project.height)
        let img = try XCTUnwrap(RenderAssets().image(at: src))
        XCTAssertEqual(img.width, Int(expected.width))
        XCTAssertEqual(img.height, Int(expected.height))
        XCTAssertEqual(undoSteps(m), 1)
        XCTAssertTrue(m.project.mediaPool.contains(src))
    }

    func testAddMediaRoutesSVGAndMIDI() async throws {
        let svg = try writeSVG()
        let mid = try writeMIDI()
        let m = ProjectModel(project: Project.new())
        let ids = await m.addMedia(urls: [svg, mid], at: 0)
        XCTAssertEqual(ids.count, 2)
        let types = m.project.allClips.map(\.type)
        XCTAssertTrue(types.contains(.image))
        XCTAssertTrue(types.contains(.audio))
        XCTAssertEqual(m.project.markers.count, 1)
        XCTAssertEqual(m.project.markers[0].name, "MIDI C4")
    }

    func testImportSVGRejectsNonSVG() async throws {
        let url = dir.appendingPathComponent("fake.svg")
        try "<html></html>".write(to: url, atomically: true, encoding: .utf8)
        let m = ProjectModel(project: Project.new())
        let ids = await m.importSVG(url: url, cacheRoot: dir.appendingPathComponent("cache"))
        XCTAssertTrue(ids.isEmpty)
        XCTAssertEqual(m.errorTitle, "SVGを読み込めませんでした")
        XCTAssertTrue(m.project.allClips.isEmpty)
    }

    // MARK: - MIDI

    func testImportMIDIPlacesAudioClipAndMarkersWithOneUndo() async throws {
        let url = try writeMIDI()
        let m = ProjectModel(project: Project.new())
        m.currentTime = 2
        let ids = await m.importMIDI(url: url, cacheRoot: dir.appendingPathComponent("cache"))
        XCTAssertEqual(ids.count, 1)
        let clip = try XCTUnwrap(m.project.allClips.first { $0.id == ids[0] })
        XCTAssertEqual(clip.type, .audio)
        XCTAssertEqual(clip.start, 2)
        XCTAssertEqual(clip.duration, 0.5, accuracy: 1e-9)
        let src = try XCTUnwrap(clip.src)
        XCTAssertTrue(src.hasSuffix("rendered.wav"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: src))
        XCTAssertEqual(m.project.markers.map(\.time), [2])
        XCTAssertEqual(m.project.markers.map(\.name), ["MIDI C4"])
        XCTAssertEqual(undoSteps(m), 1)
    }

    func testImportMIDIRejectsGarbage() async throws {
        let url = dir.appendingPathComponent("bad.mid")
        try Data("not midi".utf8).write(to: url)
        let m = ProjectModel(project: Project.new())
        let ids = await m.importMIDI(url: url, cacheRoot: dir.appendingPathComponent("cache"))
        XCTAssertTrue(ids.isEmpty)
        XCTAssertEqual(m.errorTitle, "MIDIを読み込めませんでした")
    }

    /// プリセット 1 件だけの最小 .sf2(正弦波サンプル、ループ再生)。R2-4 のアプリ側検証用。
    private func writeSF2() throws -> URL {
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xff), UInt8((v >> 8) & 0xff)] }
        func le32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xff) } }
        func fixed(_ s: String, _ len: Int) -> [UInt8] { var b = Array(s.utf8.prefix(len)); b += [UInt8](repeating: 0, count: len - b.count); return b }
        func chunk(_ id: String, _ payload: [UInt8]) -> [UInt8] { var o = Array(id.utf8) + le32(payload.count) + payload; if payload.count % 2 == 1 { o.append(0) }; return o }
        func list(_ t: String, _ payload: [UInt8]) -> [UInt8] { chunk("LIST", Array(t.utf8) + payload) }
        var smpl: [UInt8] = []
        for i in 0..<4410 { let u = UInt16(bitPattern: Int16(0.7 * 32767 * sin(2 * Double.pi * 441 * Double(i) / 44100))); smpl += [UInt8(u & 0xff), UInt8(u >> 8)] }
        var shdr = fixed("sine", 20) + le32(0) + le32(4410) + le32(0) + le32(4410) + le32(44100) + [69, 0] + le16(0) + le16(1)
        shdr += fixed("EOS", 20) + le32(0) + le32(0) + le32(0) + le32(0) + le32(0) + [0, 0] + le16(0) + le16(0)
        let phdr = fixed("Sine", 20) + le16(0) + le16(0) + le16(0) + le32(0) + le32(0) + le32(0)
                 + fixed("EOP", 20) + le16(0) + le16(0) + le16(1) + le32(0) + le32(0) + le32(0)
        let pbag = le16(0) + le16(0) + le16(1) + le16(0)
        let pgen = le16(41) + le16(0)
        let inst = fixed("inst", 20) + le16(0) + fixed("EOI", 20) + le16(1)
        let ibag = le16(0) + le16(0) + le16(2) + le16(0)
        let igen = le16(53) + le16(0) + le16(54) + le16(1)
        var pdtaBody: [UInt8] = []
        pdtaBody += chunk("phdr", phdr) + chunk("pbag", pbag) + chunk("pmod", [UInt8](repeating: 0, count: 10))
        pdtaBody += chunk("pgen", pgen) + chunk("inst", inst) + chunk("ibag", ibag)
        pdtaBody += chunk("imod", [UInt8](repeating: 0, count: 10)) + chunk("igen", igen) + chunk("shdr", shdr)
        let body = Array("sfbk".utf8) + list("INFO", chunk("INAM", fixed("AppTest", 8))) + list("sdta", chunk("smpl", smpl)) + list("pdta", pdtaBody)
        let url = dir.appendingPathComponent("font.sf2")
        try Data(Array("RIFF".utf8) + le32(body.count) + body).write(to: url)
        return url
    }

    func testImportMIDIWithSoundFontUsesSoundFontCacheAndStatus() async throws {
        let url = try writeMIDI()
        let sf = try writeSF2()
        let m = ProjectModel(project: Project.new())
        let ids = await m.importMIDI(url: url, cacheRoot: dir.appendingPathComponent("cache"), soundFontPath: sf.path)
        XCTAssertEqual(ids.count, 1)
        let clip = try XCTUnwrap(m.project.allClips.first { $0.id == ids[0] })
        let src = try XCTUnwrap(clip.src)
        XCTAssertTrue(((src as NSString).lastPathComponent).hasPrefix("rendered-sf-"))
        XCTAssertTrue(m.statusText.contains("SoundFont"))
        // SoundFont 未指定の従来経路は rendered.wav のまま(従来互換)
        let m2 = ProjectModel(project: Project.new())
        let ids2 = await m2.importMIDI(url: url, cacheRoot: dir.appendingPathComponent("cache2"))
        let src2 = try XCTUnwrap(m2.project.allClips.first { $0.id == ids2[0] }?.src)
        XCTAssertTrue(src2.hasSuffix("rendered.wav"))
    }

    // MARK: - 連番画像

    func testImportImageSequencePlacesAnimatedClip() async throws {
        var urls: [URL] = []
        for i in 1...4 { urls.append(try writeFrame("frame_000\(i).png", (255, 0, 0))) }
        let seq = try XCTUnwrap(ImageSequenceDetector.singleSequence(urls: urls))
        let m = ProjectModel(project: Project.new())
        let ids = await m.importImageSequence(seq, fps: 12, at: 1, cacheRoot: dir.appendingPathComponent("cache"))
        XCTAssertEqual(ids.count, 1)
        let clip = try XCTUnwrap(m.project.allClips.first { $0.id == ids[0] })
        XCTAssertEqual(clip.type, .image)
        XCTAssertEqual(clip.playsAnimation, true)
        XCTAssertEqual(clip.start, 1)
        XCTAssertEqual(clip.duration, 4.0 / 12, accuracy: 1e-9)
        XCTAssertEqual(undoSteps(m), 1)
    }

    func testAddMediaWithFolderImportsSequence() async throws {
        let folder = dir.appendingPathComponent("frames")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for i in 1...3 {
            let url = folder.appendingPathComponent("walk_\(i).png")
            let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
            XCTAssertTrue(CGImageDestinationFinalize(dest))
        }
        let m = ProjectModel(project: Project.new())
        // フォルダのドロップ/追加は連番として取り込む(既定 24fps: 3 コマ = 0.125 秒)
        let ids = await m.addMedia(urls: [folder], at: 0)
        XCTAssertEqual(ids.count, 1)
        let clip = try XCTUnwrap(m.project.allClips.first { $0.id == ids[0] })
        XCTAssertEqual(clip.playsAnimation, true)
        XCTAssertEqual(clip.duration, 3.0 / 24, accuracy: 1e-9)
    }

    // MARK: - メニュー

    func testInputFormatMenuSpecs() {
        var s = MenuState()
        s.hasDocument = true
        let file = AppMenuSpec.file(s)
        for (command, title) in [(MenuCommand.importSVG, "SVGを読み込む…"), (.importMIDI, "MIDIを読み込む…"), (.importImageSequence, "連番画像を読み込む…")] {
            let item = file.first { $0.command == command }
            XCTAssertEqual(item?.title, title)
            XCTAssertEqual(item?.enabled, true)
            XCTAssertNil(item?.shortcut)
        }
    }
}
