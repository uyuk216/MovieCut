import XCTest
import AppKit
import MovieCutCore
@testable import MovieCut

/// W5-4: 生成メディア(API)の動画/音声・音楽と生成延長の画面側。
/// 未設定時の無効表示、確認 → 生成 → 配置(Undo 1 回)、生成延長で元の
/// クリップが不変なこと。プロバイダは偽物に差し替え、実通信はしない。
@MainActor
final class GenerativeMediaAVAppTests: XCTestCase {
    private var scratch: URL!
    private var savedVideo: VideoGenerationSettings!
    private var savedAudio: AudioGenerationSettings!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("genmedia-av-app-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        savedVideo = VideoGenerationSettings.load()
        savedAudio = AudioGenerationSettings.load()
    }

    override func tearDownWithError() throws {
        savedVideo.save()
        savedAudio.save()
        try? FileManager.default.removeItem(at: scratch)
    }

    private func undoSteps(_ m: ProjectModel) -> Int {
        let u = m.effectiveUndoManager
        var n = 0
        while u.canUndo { u.undo(); n += 1 }
        for _ in 0..<n { u.redo() }
        return n
    }

    private func configuredVideo() {
        var s = VideoGenerationSettings()
        s.endpoint = "http://127.0.0.1:8080/v1/videos"
        s.model = "local-video"
        s.save()
    }

    private func configuredAudio() {
        var s = AudioGenerationSettings()
        s.endpoint = "http://127.0.0.1:8080/v1/audio/generations"
        s.model = "local-audio"
        s.save()
    }

    func testMenuItemsDisabledWhenUnconfiguredAndEnabledWhenConfigured() {
        VideoGenerationSettings().save()
        AudioGenerationSettings().save()
        let m = ProjectModel(project: .new())
        XCTAssertFalse(m.videoGenerationConfigured)
        XCTAssertFalse(m.audioGenerationConfigured)
        XCTAssertFalse(AppMenuSpec.generatedVideoItem(MenuState(model: m)).enabled)
        XCTAssertFalse(AppMenuSpec.generatedAudioItem(MenuState(model: m)).enabled)
        XCTAssertFalse(AppMenuSpec.generatedMusicItem(MenuState(model: m)).enabled)
        XCTAssertFalse(AppMenuSpec.generatedSoundscapeItem(MenuState(model: m)).enabled)
        XCTAssertEqual(AppMenuSpec.generatedVideoItem(MenuState(model: m)).command, .generateVideoAPI)
        XCTAssertEqual(AppMenuSpec.generativeExtendItem(MenuState(model: m)).command, .generativeExtend)
        configuredVideo()
        configuredAudio()
        XCTAssertTrue(m.videoGenerationConfigured)
        XCTAssertTrue(m.audioGenerationConfigured)
        XCTAssertTrue(AppMenuSpec.generatedVideoItem(MenuState(model: m)).enabled)
        XCTAssertTrue(AppMenuSpec.generatedMusicItem(MenuState(model: m)).enabled)
    }

    func testGenerateVideoPlacesClipWithOneUndoAfterConfirmation() async throws {
        configuredVideo()
        let fake = FakeGenerativeMediaProvider(.succeed(scratch.appendingPathComponent("made.mp4"), duration: 6))
        let m = ProjectModel(project: .new())
        m.genMediaUI.makeVideoProvider = { fake }
        var shown: [(String, String)] = []
        m.genMediaUI.confirmSend = { d, s in shown.append((d, s)); return true }
        m.currentTime = 3
        let id = await m.generateVideoViaAPI(prompt: "海を飛ぶ")
        let clip = try XCTUnwrap(m.project.allClips.first { $0.id == id })
        XCTAssertEqual(clip.type, .video)
        XCTAssertEqual(clip.start, 3, accuracy: 1e-9)
        XCTAssertEqual(shown.count, 1)
        XCTAssertTrue(shown.first?.1.contains("課金されます") ?? false)
        XCTAssertTrue(shown.first?.1.contains("MovieCut のサーバは経由しません") ?? false)
        XCTAssertEqual(fake.requests.first?.kind, .video)
        XCTAssertEqual(undoSteps(m), 1)
        XCTAssertEqual(m.statusText, "生成した動画を追加しました")
    }

    func testGenerateMusicPlacesAudioClipAndDeclinedConfirmationGeneratesNothing() async throws {
        configuredAudio()
        let fake = FakeGenerativeMediaProvider(.succeed(scratch.appendingPathComponent("song.mp3"), duration: 8))
        let m = ProjectModel(project: .new())
        m.genMediaUI.makeAudioProvider = { fake }
        m.genMediaUI.confirmSend = { _, _ in true }
        let id = await m.generateAudioViaAPI(kind: .music, prompt: "明るい曲")
        let clip = try XCTUnwrap(m.project.allClips.first { $0.id == id })
        XCTAssertEqual(clip.type, .audio)
        XCTAssertEqual(fake.requests.first?.kind, .music)

        let m2 = ProjectModel(project: .new())
        let fake2 = FakeGenerativeMediaProvider(.succeed(scratch.appendingPathComponent("song2.mp3"), duration: 8))
        m2.genMediaUI.makeAudioProvider = { fake2 }
        m2.genMediaUI.confirmSend = { _, _ in false }
        let id2 = await m2.generateAudioViaAPI(kind: .audio, prompt: "送らない音")
        XCTAssertNil(id2)
        XCTAssertEqual(fake2.requests.count, 0, "確認を断ったら生成しない")
        XCTAssertTrue(m2.project.allClips.isEmpty)
    }

    func testGenerativeExtendAddsSegmentsWithOneUndoAndLeavesOriginalUntouched() async throws {
        configuredVideo()
        let m = ProjectModel(project: .new())
        // 元の動画クリップを 10 秒から 6 秒で置いて選ぶ
        var ids: [String] = []
        XCTAssertTrue(m.edit("元の動画の追加", { pr in
            ids = GenerativeMediaPlacement.place(
                GenerativeMediaResult(kind: .video, fileURL: scratch.appendingPathComponent("src.mp4"), duration: 6),
                at: 10, in: &pr)
        }))
        m.selectedClipId = ids[0]
        XCTAssertTrue(m.canGenerativeExtendSelected)
        XCTAssertTrue(m.generativeExtendConfigured)
        XCTAssertTrue(AppMenuSpec.generativeExtendItem(MenuState(model: m)).enabled)

        let fake = FakeGenerativeMediaProvider(.succeed(scratch.appendingPathComponent("ext.mp4"), duration: 99))
        m.genMediaUI.makeVideoProvider = { fake }
        var shown: [(String, String)] = []
        m.genMediaUI.confirmSend = { d, s in shown.append((d, s)); return true }
        let added = await m.generativeExtendSelected(prompt: "続きの映像", headSeconds: 2, tailSeconds: 3)
        XCTAssertEqual(added.count, 2)
        XCTAssertEqual(fake.requests.count, 2)
        XCTAssertTrue(shown.first?.1.contains("生成延長") ?? false)
        XCTAssertTrue(shown.first?.1.contains("課金されます") ?? false)
        let head = try XCTUnwrap(m.project.allClips.first { $0.id == added[0] })
        XCTAssertEqual(head.start, 8, accuracy: 1e-9)
        XCTAssertEqual(head.duration, 2, accuracy: 1e-9)
        let tail = try XCTUnwrap(m.project.allClips.first { $0.id == added[1] })
        XCTAssertEqual(tail.start, 16, accuracy: 1e-9)
        XCTAssertEqual(tail.duration, 3, accuracy: 1e-9)
        let original = try XCTUnwrap(m.project.allClips.first { $0.id == ids[0] })
        XCTAssertEqual(original.start, 10, accuracy: 1e-9, "元クリップは書き換えない")
        XCTAssertEqual(original.duration, 6, accuracy: 1e-9)
        XCTAssertEqual(undoSteps(m), 2, "元の追加 1 回 + 生成延長の配置 1 回だけが Undo 対象")
        XCTAssertEqual(m.statusText, "生成延長で前後の区間を追加しました")
    }

    func testGenerativeExtendUnconfiguredOrWrongClipAddsNothing() async throws {
        VideoGenerationSettings().save()
        let m = ProjectModel(project: .new())
        var ids: [String] = []
        XCTAssertTrue(m.edit("元の動画の追加", { pr in
            ids = GenerativeMediaPlacement.place(
                GenerativeMediaResult(kind: .video, fileURL: scratch.appendingPathComponent("src.mp4"), duration: 6),
                at: 10, in: &pr)
        }))
        m.selectedClipId = ids[0]
        XCTAssertTrue(m.canGenerativeExtendSelected)
        XCTAssertFalse(m.generativeExtendConfigured, "未設定なら生成延長は無効表示")
        XCTAssertFalse(AppMenuSpec.generativeExtendItem(MenuState(model: m)).enabled)
        var asked = 0
        m.genMediaUI.confirmSend = { _, _ in asked += 1; return true }
        let added = await m.generativeExtendSelected(prompt: "続き", headSeconds: 0, tailSeconds: 2)
        XCTAssertEqual(added.count, 0)
        XCTAssertEqual(asked, 0, "未設定なら確認の前に止める")
        XCTAssertEqual(m.project.allClips.count, 1)
    }
}
