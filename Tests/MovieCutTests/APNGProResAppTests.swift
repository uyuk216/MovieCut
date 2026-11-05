import XCTest
import ImageIO
import AVFoundation
import UniformTypeIdentifiers
import MovieCutCore
@testable import MovieCut

/// 出力 ▸ APNGとして書き出す…・書き出し形式の ProRes・透明な背景(メニュー表とモデル経由の書き出し)。
@MainActor
final class APNGProResAppTests: XCTestCase {
    private func state(_ f: (inout MenuState) -> Void = { _ in }) -> MenuState {
        var s = MenuState(); s.hasDocument = true; s.canExport = true; f(&s); return s
    }

    private func makeModel(duration: Double = 2) -> ProjectModel {
        var p = Project.new()
        p.width = 320; p.height = 180; p.fps = 30
        var t = Clip(); t.type = .text; t.text = "A"; t.start = 0; t.duration = duration; t.fontSize = 60
        p.tracks[4].clips.append(t)
        let m = ProjectModel(project: p)
        m.notices = OneTimeNotices()
        return m
    }

    private var tmpDir: URL { FileManager.default.temporaryDirectory.appendingPathComponent("apngapp-\(UUID().uuidString)") }

    func testAPNGMenuItem() {
        let s = state()
        let spec = AppMenuSpec.apngExport(s)
        XCTAssertEqual(spec.title, "APNGとして書き出す…")
        XCTAssertNil(spec.shortcut)
        XCTAssertTrue(spec.enabled)
        XCTAssertTrue(AppMenuSpec.all(s).contains { $0.command == .exportAPNG })
        XCTAssertFalse(AppMenuSpec.apngExport(state { $0.isLocked = true }).enabled)
        XCTAssertFalse(AppMenuSpec.apngExport(state { $0.canExport = false }).enabled)
        XCTAssertNotNil(AppMenuSpec.disabledReason(for: AppMenuSpec.apngExport(state { $0.canExport = false }), state: state { $0.canExport = false }), "押せない理由が出る")
        let used = AppMenuSpec.all(s).compactMap(\.shortcut)
        XCTAssertEqual(used.count, Set(used).count, "ショートカットの重複なし")
    }

    func testCodecAndBackgroundMenuListProResAndTransparent() {
        let s = state { $0.codec = OutputPlan.proRes4444; $0.bg = Project.transparentBackground }
        let codecs = AppMenuSpec.codecItems(s)
        XCTAssertEqual(codecs.map(\.command), [.codec("h264"), .codec("hevc"), .codec("prores422"), .codec("prores4444")])
        XCTAssertEqual(codecs.map(\.checked), [false, false, false, true])
        let bgs = AppMenuSpec.backgroundItems(s)
        XCTAssertEqual(bgs.last?.command, .background("transparent"))
        XCTAssertEqual(bgs.last?.checked, true)
        XCTAssertTrue(codecs.allSatisfy { $0.shortcut == nil })
    }

    func testSetCodecProResIsOneUndoAndSurvivesResolutionChange() {
        let m = makeModel()
        let u = m.effectiveUndoManager
        AppMenu.perform(.codec("prores4444"), model: m)
        XCTAssertEqual(m.project.codec, "prores4444")
        AppMenu.perform(.background("transparent"), model: m)
        XCTAssertTrue(m.project.hasTransparentBackground)
        u.undo()
        XCTAssertFalse(m.project.hasTransparentBackground)
        u.undo()
        XCTAssertEqual(m.project.codec, "h264")
        u.redo()
        m.applyVideoSize(3840, 2160)
        XCTAssertEqual(m.project.codec, "prores4444", "4K にしても ProRes は HEVC に替わらない")
        m.setCodec("bogus")
        XCTAssertEqual(m.project.codec, "prores4444", "知らない形式は受け付けない")
    }

    func testExportPanelTypeFollowsProResCode() {
        let prores = ExportPanelOptions(documentName: "d", initial: .current, custom: [], projectCodec: "prores422")
        XCTAssertEqual(prores.contentType(for: .current), .quickTimeMovie)
        XCTAssertEqual(prores.contentType(for: .builtin(.youtube1080)), .mpeg4Movie, "プリセットは従来どおり mp4")
        XCTAssertEqual(prores.contentType(for: .builtin(.audio)), .mpeg4Audio)
        let normal = ExportPanelOptions(documentName: "d", initial: .current, custom: [])
        XCTAssertEqual(normal.contentType(for: .current), .mpeg4Movie)
        let m = makeModel()
        m.setCodec("prores422")
        XCTAssertEqual(m.exportSuggestedName(preset: nil), "\(m.documentName).mov")
        m.setCodec("hevc")
        XCTAssertEqual(m.exportSuggestedName(preset: nil), "\(m.documentName).mp4")
    }

    func testRunAPNGExportThroughModelWritesFileAndIsNotAnEdit() async throws {
        let m = makeModel(duration: 2)
        let dir = tmpDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("m.png")
        let outcome = await m.runAPNGExport(to: out, options: APNGOptions(fps: 10, maxWidth: 160, loopCount: 2), range: nil)
        guard case .success(let url) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(url, out)
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(out as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(src), 20)
        XCTAssertFalse(m.isExporting)
        XCTAssertFalse(m.effectiveUndoManager.canUndo, "書き出しは編集ではない")
    }

    func testRunExportWithProResProducesMovWithProResTrack() async throws {
        let m = makeModel(duration: 1)
        m.setCodec("prores422")
        let dir = tmpDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("p.mov")
        let outcome = await m.runExport(to: out)
        guard case .success = outcome else { return XCTFail("\(outcome)") }
        let asset = AVURLAsset(url: out)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let vt = try XCTUnwrap(tracks.first)
        let fd = try await vt.load(.formatDescriptions)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(fd[0]), kCMVideoCodecType_AppleProRes422)
    }
}
