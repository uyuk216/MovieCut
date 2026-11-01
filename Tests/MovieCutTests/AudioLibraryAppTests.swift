import XCTest
import MovieCutCore
@testable import MovieCut

/// 素材ブラウザ(App 側): フォルダの記憶、「タイムラインに追加」(再生ヘッド・音声クリップ・Undo 1 回)。
@MainActor
final class AudioLibraryAppTests: XCTestCase {
    private var dir: URL!
    private var suite: String!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("audiolib-app-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        suite = "audiolib-tests-\(UUID().uuidString)"
    }

    override func tearDown() async throws {
        UserDefaults().removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: dir)
    }

    /// 8 kHz・モノラル・16 ビットの WAV を `seconds` 秒ぶん。
    private func wav(_ seconds: Double, name: String) throws -> URL {
        let rate = 8000, n = Int(Double(rate) * seconds)
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append("RIFF".data(using: .ascii)!); u32(UInt32(36 + n * 2)); d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        d.append("data".data(using: .ascii)!); u32(UInt32(n * 2)); d.append(Data(count: n * 2))
        let u = dir.appendingPathComponent(name)
        try d.write(to: u)
        return u
    }

    func testFolderIsRememberedAcrossLaunches() {
        let defaults = UserDefaults(suiteName: suite)!
        XCTAssertNil(AudioLibraryStore.folder(defaults: defaults))
        AudioLibraryStore.setFolder(dir, defaults: defaults)
        XCTAssertEqual(AudioLibraryStore.folder(defaults: defaults)?.path, dir.path)
        AudioLibraryStore.setFolder(nil, defaults: defaults)
        XCTAssertNil(AudioLibraryStore.folder(defaults: defaults))
    }

    func testAddToTimelinePlacesAudioClipAtPlayheadWithOneUndoStep() async throws {
        let model = ProjectModel(project: Project.new())
        let file = try wav(2, name: "bgm.wav")
        let entry = AudioLibrary.Entry(url: file, name: "bgm.wav", duration: 2)
        model.currentTime = 4
        let before = model.project
        let ids = await AudioLibrarySheet.addToTimeline(entry, model: model)
        XCTAssertEqual(ids.count, 1)
        let clip = model.project.tracks.flatMap(\.clips).first { $0.id == ids[0] }
        XCTAssertEqual(clip?.type, .audio)
        XCTAssertEqual(clip?.start ?? -1, 4, accuracy: 0.001, "再生ヘッドの位置に置く")
        XCTAssertTrue(model.effectiveUndoManager.canUndo)
        model.effectiveUndoManager.undo()
        XCTAssertEqual(model.project, before, "取り消しは 1 回で元に戻る")
    }

    func testUnreadableEntryIsNotAdded() async {
        let model = ProjectModel(project: Project.new())
        let entry = AudioLibrary.Entry(url: dir.appendingPathComponent("broken.mp3"), name: "broken.mp3", duration: nil)
        let before = model.project
        let ids = await AudioLibrarySheet.addToTimeline(entry, model: model)
        XCTAssertEqual(ids, [])
        XCTAssertEqual(model.project, before)
    }

    func testDurationTextFormatsMinutesAndSeconds() {
        XCTAssertEqual(AudioLibrarySheet.durationText(0.4), "0:00")
        XCTAssertEqual(AudioLibrarySheet.durationText(83.6), "1:24")
    }

    /// 試し聴きが鳴り終わったら、再生ボタンを「停止」のままにしない(再生中の表示を戻す)。
    func testPreviewResetsWhenPlaybackEnds() async throws {
        let url = try wav(0.2, name: "short.wav")
        let player = AudioPreviewPlayer()
        player.toggle(url)
        XCTAssertEqual(player.playingURL, url, "鳴らし始めたら印が付く")
        for _ in 0..<400 where player.playingURL != nil { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNil(player.playingURL, "鳴り終わったら印を消す")
    }
}
