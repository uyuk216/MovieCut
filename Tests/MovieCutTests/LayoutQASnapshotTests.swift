import XCTest
import SwiftUI
import AppKit
import MovieCutCore
@testable import MovieCut

/// 画面の外で主要画面を描いて PNG にする(MC_SNAPSHOT_OUT_DIR で出力先を変えられる)。
/// 1100×700 と 1456×840 の 2 つの大きさ。出力は目視確認用。
@MainActor
final class LayoutQASnapshotTests: XCTestCase {
    private static let outDir = ProcessInfo.processInfo.environment["MC_SNAPSHOT_OUT_DIR"]
        ?? "/private/tmp/claude-501/-Users-USER------------/07529bfa-5715-4444-bf9c-c37229b6ab4d/scratchpad/qa-ui"

    private func snap<V: View>(_ v: V, size: NSSize, name: String) throws {
        let host = NSHostingView(rootView: ZStack { Color(white: 0.11); v }.preferredColorScheme(.dark))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let url = URL(fileURLWithPath: Self.outDir).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        XCTAssertGreaterThan(data.count, 5_000)
    }

    /// 文字・吹き出し・クロマキー付きの素材・キャラを用意したモデル。
    private func richModel() -> ProjectModel {
        let m = ProjectModel(project: .new())
        m.notices = OneTimeNotices()
        _ = m.addBlurClip()
        m.playback.seek(to: 1)
        let t = m.addTextClip()
        m.scriptText = "こんにちは\n今日はいい天気ですね"
        m.statusText = "テスト中"
        m.addCharacter()
        if let t { m.setBubble(Bubble(), name: "吹き出しを付ける", clipId: t) }
        m.selectOnly(nil)
        return m
    }

    func testMainWindowAt1100x700() throws {
        let m = richModel()
        try snap(ContentView(model: m, fileURL: nil), size: NSSize(width: 1100, height: 700), name: "main-1100x700.png")
    }

    func testMainWindowAt1456x840() throws {
        let m = richModel()
        try snap(ContentView(model: m, fileURL: nil), size: NSSize(width: 1456, height: 840), name: "main-1456x840.png")
    }

    func testInspectorTallCaptureTextWithBubble() throws {
        let m = richModel()
        let t = try XCTUnwrap(m.project.tracks.flatMap { $0.clips }.first { $0.type == .text }?.id)
        m.selectOnly(t)
        try snap(InspectorView(model: m, speakers: SpeakerCatalog()), size: NSSize(width: 340, height: 1400), name: "inspector-text-bubble.png")
    }

    func testInspectorTallCaptureImageWithChroma() async throws {
        let m = ProjectModel(project: .new())
        m.notices = OneTimeNotices()
        // 画像素材(緑の単色)を 1 枚置く
        let dir = URL(fileURLWithPath: Self.outDir).appendingPathComponent("src")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let img = NSImage(size: NSSize(width: 320, height: 180))
        img.lockFocus(); NSColor(calibratedRed: 0, green: 0.69, blue: 0.25, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 320, height: 180).fill(); img.unlockFocus()
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(img.tiffRepresentation)))
        let url = dir.appendingPathComponent("green.png")
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        let ids = await m.addMedia(urls: [url], at: 0)
        let clipId = try XCTUnwrap(ids.first)
        m.selectOnly(clipId)
        let ok1 = m.addEffect(.chromaKey, clipId: clipId), ok2 = m.addEffect(.lut, clipId: clipId)
        print("EFFECT-ADD image chroma=\(ok1) lut=\(ok2)")
        try snap(InspectorView(model: m, speakers: SpeakerCatalog()), size: NSSize(width: 340, height: 1400), name: "inspector-image-chroma-lut.png")
    }

    func testSilenceCutSheetAlone() throws {
        let m = richModel()
        try snap(SilenceCutSheet(model: m), size: NSSize(width: 520, height: 420), name: "silence-sheet.png")
    }
}
