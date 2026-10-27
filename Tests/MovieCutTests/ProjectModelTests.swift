import XCTest
import AVFoundation
import MovieCutCore
@testable import MovieCut

@MainActor
final class ProjectModelTests: XCTestCase {
    private func makeModel() -> ProjectModel {
        let m = ProjectModel(project: .new())
        m.voiceProviderFactory = { _ in ToneVoiceProvider() }
        return m
    }

    func testEditUndoRedoRoundTrip() {
        let m = makeModel()
        let um = m.effectiveUndoManager
        let original = m.project
        m.edit("fps変更") { $0.fps = 30 }
        XCTAssertEqual(m.project.fps, 30)
        m.edit("背景変更") { $0.bg = "#ffffff" }
        XCTAssertEqual(m.project.bg, "#ffffff")
        XCTAssertTrue(um.canUndo)
        um.undo()
        XCTAssertEqual(m.project.bg, "#000000")
        XCTAssertEqual(m.project.fps, 30)
        um.undo()
        XCTAssertEqual(m.project, original)
        XCTAssertFalse(um.canUndo)
        XCTAssertTrue(um.canRedo)
        um.redo(); um.redo()
        XCTAssertEqual(m.project.fps, 30)
        XCTAssertEqual(m.project.bg, "#ffffff")
    }

    func testNoOpEditRegistersNothing() {
        let m = makeModel()
        m.edit("何もしない") { _ in }
        XCTAssertFalse(m.effectiveUndoManager.canUndo)
    }

    func testApplyVideoSizeScalesAndSetsCodec() {
        let m = makeModel()
        var c = Clip(); c.type = .text; c.fontSize = 80; c.blur = 10
        m.edit("準備") { $0.tracks[0].clips.append(c) }
        m.applyVideoSize(1080, 1920)   // 面積は同じ → 倍率 1
        XCTAssertEqual(m.project.width, 1080); XCTAssertEqual(m.project.height, 1920)
        XCTAssertEqual(m.project.tracks[0].clips[0].fontSize, 80)
        XCTAssertEqual(m.project.codec, "h264")
        m.applyVideoSize(3840, 2160)   // 面積 4 倍 → 2 倍
        XCTAssertEqual(m.project.tracks[0].clips[0].fontSize, 160)
        XCTAssertEqual(m.project.tracks[0].clips[0].blur, 20)
        XCTAssertEqual(m.project.codec, "hevc")
        m.effectiveUndoManager.undo()
        XCTAssertEqual(m.project.width, 1080)
        XCTAssertEqual(m.project.tracks[0].clips[0].fontSize, 80)
        XCTAssertEqual(m.project.codec, "h264")
    }

    func testSelectResolutionKeyAndCustom() {
        let m = makeModel()
        m.selectResolution("1366x768")
        XCTAssertEqual(m.resolutionKey, "1366x768")
        XCTAssertTrue(ResolutionPresets.isPreset(m.resolutionKey))
        m.selectResolution("custom")
        XCTAssertTrue(m.showResolutionSheet)
        XCTAssertEqual(m.resolutionKey, "1366x768")
        m.applyVideoSize(1234, 777)
        XCTAssertEqual(m.resolutionKey, "1234x777")
        XCTAssertFalse(ResolutionPresets.isPreset(m.resolutionKey))
    }

    func testSettingsApplyIsOneUndoStep() {
        let m = makeModel()
        let before = m.project
        let original = VideoSettingsDraft(m.project)
        var d = original
        d.width = 3840; d.height = 2160; d.fps = 30; d.bg = "#ffffff"
        m.applySettings(d, original: original)
        XCTAssertEqual(m.project.codec, "hevc")
        XCTAssertEqual(m.project.fps, 30)
        XCTAssertEqual(m.project.bg, "#ffffff")
        m.effectiveUndoManager.undo()
        XCTAssertEqual(m.project, before)
        XCTAssertFalse(m.effectiveUndoManager.canUndo)
    }

    func testAddCharacter() {
        let m = makeModel()
        let n = m.project.characters.count
        m.addCharacter()
        XCTAssertEqual(m.project.characters.count, n + 1)
        let c = m.project.characters.last!
        XCTAssertEqual(c.name, "キャラ\(n + 1)")
        XCTAssertEqual(c.engine, "voicevox")
        XCTAssertEqual(c.speaker, 3); XCTAssertEqual(c.speed, 1); XCTAssertEqual(c.pitch, 0); XCTAssertEqual(c.intonation, 1)
        XCTAssertEqual(c.color, "#4f8cff")
        XCTAssertEqual(c.x, 0.5); XCTAssertFalse(c.flip)
        XCTAssertEqual(m.selectedCharId, c.id)
        m.effectiveUndoManager.undo()
        XCTAssertEqual(m.project.characters.count, n)
        XCTAssertEqual(m.effectiveSelectedCharId, m.project.characters.first?.id)   // 消えた選択は先頭に戻る
    }

    func testDefaultSelectedCharIsFirst() {
        let m = makeModel()
        XCTAssertNotNil(m.selectedCharId)
        XCTAssertEqual(m.selectedCharId, m.project.characters.first?.id)
    }

    func testScriptAddsClipsAsOneUndoStep() async {
        let m = makeModel()
        var fitted = 0
        m.onFitTimeline = { fitted += 1 }
        await m.generateVoices(from: "霊夢: こんにちは\nずんだもん: こんばんは\n\n   \n名無し: 誰が読む")
        let clips = m.project.allClips.filter { $0.type == .voice }
        XCTAssertEqual(clips.count, 3)
        XCTAssertEqual(m.statusText, "3 個のセリフを並べました")
        XCTAssertEqual(fitted, 1)
        XCTAssertNil(m.busyMessage)
        XCTAssertNil(m.errorMessage)
        let um = m.effectiveUndoManager
        um.undo()
        XCTAssertEqual(m.project.allClips.count, 0)
        XCTAssertFalse(um.canUndo)   // 1 回で全部戻る
        um.redo()
        XCTAssertEqual(m.project.allClips.filter { $0.type == .voice }.count, 3)
    }

    func testEmptyScriptDoesNothing() async {
        let m = makeModel()
        await m.generateVoices(from: " \n\n  ")
        XCTAssertFalse(m.effectiveUndoManager.canUndo)
        XCTAssertEqual(m.statusText, "")
    }

    func testScriptFailureShowsError() async {
        struct Boom: LocalizedError { var errorDescription: String? { "テスト失敗" } }
        final class Failing: VoiceProvider {
            func synthesize(character: Character, text: String, in directory: URL) async throws -> VoiceResult { throw Boom() }
        }
        let m = makeModel()
        m.voiceProviderFactory = { _ in Failing() }
        await m.generateVoices(from: "霊夢: だめ")
        XCTAssertEqual(m.errorMessage, "テスト失敗")
        XCTAssertEqual(m.project.allClips.count, 0)
        XCTAssertFalse(m.effectiveUndoManager.canUndo)
        XCTAssertNil(m.busyMessage)
    }

    func testExportThroughModelProducesValidMP4() async throws {
        let m = makeModel()
        m.applyVideoSize(640, 360)
        m.edit("fps") { $0.fps = 30 }
        await m.generateVoices(from: "霊夢: 一つ目\nずんだもん: 二つ目")
        XCTAssertFalse(m.project.allClips.isEmpty)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("ye-model-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: out) }
        let outcome = await m.runExport(to: out)
        guard case .success = outcome else { return XCTFail("export did not succeed: \(outcome)") }
        XCTAssertFalse(m.isExporting)
        XCTAssertEqual(m.exportProgress, 1)
        let asset = AVURLAsset(url: out)
        let v = try await asset.loadTracks(withMediaType: .video)
        let a = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(v.count, 1); XCTAssertEqual(a.count, 1)
        let size = try await v[0].load(.naturalSize)
        XCTAssertEqual(Int(size.width), 640); XCTAssertEqual(Int(size.height), 360)
        let dur = try await asset.load(.duration).seconds
        XCTAssertEqual(dur, m.project.endTime, accuracy: 0.2)
    }

    func testExportOfEmptyProjectFailsWithMessage() async {
        let m = makeModel()
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("ye-empty-\(UUID().uuidString).mp4")
        let outcome = await m.runExport(to: out)
        guard case .failure = outcome else { return XCTFail("should fail") }
        XCTAssertEqual(m.errorMessage, "タイムラインが空です")
        XCTAssertFalse(m.isExporting)
    }

    func testTimecode() {
        XCTAssertEqual(timecode(0), "00:00.00")
        XCTAssertEqual(timecode(4.68), "00:04.68")
        XCTAssertEqual(timecode(75.5), "01:15.50")
    }
}
