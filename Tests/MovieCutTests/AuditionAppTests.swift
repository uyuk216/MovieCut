import XCTest
import AVFoundation
import MovieCutCore
@testable import MovieCut

@MainActor
final class FakeAuditionPlayer: AuditionPlaying {
    var played: [URL] = []
    var stopCount = 0
    func play(url: URL) { played.append(url) }
    func stop() { stopCount += 1 }
}

/// 重なったクリップの音だけの試聴: メニューの状態・対象の巡回・スクラブで鳴る・プロジェクトを変えない。
@MainActor
final class AuditionAppTests: XCTestCase {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("audition-app-\(UUID().uuidString)")
    override func setUpWithError() throws { try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    func writeTone(_ name: String, seconds: Double = 4) throws -> String {
        let u = tmp.appendingPathComponent(name)
        let sr = 24000.0
        let f = try AVAudioFile(forWriting: u, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sr, AVNumberOfChannelsKey: 1,
                                                          AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false],
                                commonFormat: .pcmFormatFloat32, interleaved: false)
        let n = Int(seconds * sr)
        let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(n))!
        b.frameLength = AVAudioFrameCount(n)
        for i in 0..<n { b.floatChannelData![0][i] = 0.3 * Float(sin(2 * .pi * 440 * Double(i) / sr)) }
        try f.write(from: b)
        return u.path
    }

    /// 0〜4 秒の "a"(下)と 2〜6 秒の "b"(上)。2〜4 秒が重なる。
    func model() throws -> (ProjectModel, FakeAuditionPlayer) {
        var p = Project.new()
        func c(_ id: String, _ src: String, _ start: Double) -> Clip {
            var x = Clip(); x.id = id; x.type = .audio; x.src = src; x.start = start; x.duration = 4; x.srcDuration = 4
            return x
        }
        p.tracks[0].clips = [c("a", try writeTone("a.wav"), 0)]
        p.tracks[1].clips = [c("b", try writeTone("b.wav"), 2)]
        let m = ProjectModel(project: p)
        let fake = FakeAuditionPlayer()
        m.auditionPlayer = fake
        return (m, fake)
    }

    func testMenuItemsStateReasonsAndNoShortcut() {
        var s = MenuState(); s.hasDocument = true
        var items = AppMenuSpec.auditionItems(s)
        XCTAssertEqual(items.map(\.command), [.toggleAudition, .cycleAudition])
        XCTAssertTrue(items.allSatisfy { !$0.enabled && $0.shortcut == nil })
        XCTAssertEqual(AppMenuSpec.disabledReason(for: items[0], state: s), "再生位置に音のあるクリップがありません")
        XCTAssertEqual(AppMenuSpec.disabledReason(for: items[1], state: s), "再生位置で音が重なったクリップが 2 つ以上ありません")
        s.auditionCandidateCount = 1
        items = AppMenuSpec.auditionItems(s)
        XCTAssertTrue(items[0].enabled); XCTAssertFalse(items[1].enabled)
        s.auditionCandidateCount = 2; s.auditionActive = true
        items = AppMenuSpec.auditionItems(s)
        XCTAssertTrue(items[1].enabled)
        XCTAssertEqual(items[0].checked, true)
        s.auditionCandidateCount = 0
        XCTAssertTrue(AppMenuSpec.auditionItems(s)[0].enabled, "オンのときは、鳴っているクリップが無い場所でも切れる")
        XCTAssertTrue(AppMenuSpec.playback(s).contains { $0.command == .toggleAudition }, "再生メニューの表に入っている")
    }

    func testMenuStateReadsTheModel() throws {
        let (m, _) = try model()
        m.currentTime = 3
        XCTAssertEqual(MenuState(model: m).auditionCandidateCount, 2)
        m.currentTime = 1
        XCTAssertEqual(MenuState(model: m).auditionCandidateCount, 1)
        m.currentTime = 9
        XCTAssertEqual(MenuState(model: m).auditionCandidateCount, 0)
    }

    func testToggleOnPlaysOnlyTheSelectedClipAndOffStops() async throws {
        let (m, fake) = try model()
        m.currentTime = 3
        m.selectOnly("b")
        XCTAssertTrue(m.toggleAudition())
        XCTAssertTrue(m.auditionOn)
        XCTAssertEqual(m.auditionClipId, "b")
        await m.auditionTask?.value
        XCTAssertEqual(fake.played.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fake.played[0].path))
        let before = fake.stopCount
        XCTAssertTrue(m.toggleAudition())
        XCTAssertFalse(m.auditionOn)
        XCTAssertGreaterThan(fake.stopCount, before)
        XCTAssertNil(m.auditionClipId)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fake.played[0].path), "一時ファイルは消す")
    }

    func testToggleRefusedWhereNothingSounds() throws {
        let (m, fake) = try model()
        m.currentTime = 9
        XCTAssertFalse(m.toggleAudition())
        XCTAssertFalse(m.auditionOn)
        XCTAssertEqual(m.statusText, "再生位置に音のあるクリップがありません")
        XCTAssertTrue(fake.played.isEmpty)
    }

    func testScrubbingPlaysSnippetsAndStaysOnTheTarget() async throws {
        let (m, fake) = try model()
        m.currentTime = 3
        m.selectOnly("a")
        m.toggleAudition()
        await m.auditionTask?.value
        XCTAssertEqual(fake.played.count, 1)
        m.playback.seek(to: 3.5)                     // スクラブ: 同じ対象 a が、新しい位置から鳴る
        await m.auditionTask?.value
        XCTAssertEqual(fake.played.count, 2)
        m.playback.seek(to: 5)                       // a は 4 秒で終わる: b へは移らず、鳴らさない
        await m.auditionTask?.value
        XCTAssertEqual(fake.played.count, 2)
        XCTAssertEqual(m.auditionClipId, "a")
        m.playback.seek(to: 1)
        await m.auditionTask?.value
        XCTAssertEqual(fake.played.count, 3, "戻ってくればまた鳴る")
    }

    func testRapidScrubsOnlyPlayTheLatest() async throws {
        let (m, fake) = try model()
        m.currentTime = 3
        m.selectOnly("a")
        m.toggleAudition()
        await m.auditionTask?.value
        let base = fake.played.count
        for t in stride(from: 0.2, through: 3.0, by: 0.2) { m.playback.seek(to: t) }
        await m.auditionTask?.value
        XCTAssertEqual(fake.played.count - base, 1, "古い要求は捨てる")
    }

    func testCycleVisitsOverlappingClipsInOrder() async throws {
        let (m, fake) = try model()
        m.currentTime = 3
        XCTAssertTrue(m.cycleAuditionTarget())
        XCTAssertTrue(m.auditionOn)
        let first = m.auditionClipId
        XCTAssertEqual(first, "a")
        await m.auditionTask?.value
        m.cycleAuditionTarget()
        XCTAssertEqual(m.auditionClipId, "b")
        XCTAssertTrue(m.statusText.contains("2/2"))
        await m.auditionTask?.value
        m.cycleAuditionTarget()
        XCTAssertEqual(m.auditionClipId, "a", "最後の次は先頭")
        await m.auditionTask?.value
        XCTAssertEqual(fake.played.count, 3)
    }

    func testAuditionDoesNotChangeTheDocumentOrUndo() async throws {
        let (m, _) = try model()
        let before = try m.project.encoded()
        m.currentTime = 3
        m.toggleAudition()
        await m.auditionTask?.value
        m.playback.seek(to: 2.5)
        await m.auditionTask?.value
        m.cycleAuditionTarget()
        await m.auditionTask?.value
        m.toggleAudition()
        XCTAssertEqual(try m.project.encoded(), before)
        XCTAssertFalse(m.effectiveUndoManager.canUndo)
    }

    func testStartingNormalPlaybackSilencesTheSnippet() async throws {
        let (m, fake) = try model()
        m.currentTime = 3
        m.toggleAudition()
        await m.auditionTask?.value
        let before = fake.stopCount
        m.playback.play()
        XCTAssertGreaterThan(fake.stopCount, before)
        m.playback.pause()
        m.stopAudition()
    }

    func testLockedModelRefuses() throws {
        let (m, fake) = try model()
        m.currentTime = 3
        m.isExporting = true
        XCTAssertFalse(m.toggleAudition())
        XCTAssertFalse(m.cycleAuditionTarget())
        XCTAssertTrue(fake.played.isEmpty)
    }
}
