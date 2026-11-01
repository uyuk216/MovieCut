import XCTest
import MovieCutCore

/// 素材ブラウザの Core: 拡張子の判定・自然順の並べ替え・フォルダの走査(壊れたファイルに強いこと)。
final class AudioLibraryTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("audiolib-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// 16 ビット・モノラル・8 kHz の WAV を `seconds` 秒ぶん書く。
    private func wav(seconds: Double) -> Data {
        let rate = 8000, n = Int(Double(rate) * seconds)
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append("RIFF".data(using: .ascii)!); u32(UInt32(36 + n * 2)); d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        d.append("data".data(using: .ascii)!); u32(UInt32(n * 2)); d.append(Data(count: n * 2))
        return d
    }

    @discardableResult
    private func put(_ name: String, _ data: Data) throws -> URL {
        let u = dir.appendingPathComponent(name)
        try data.write(to: u)
        return u
    }

    // MARK: 判定

    func testExtensionFilterIsCaseInsensitiveAndSkipsHidden() {
        XCTAssertTrue(AudioLibrary.isAudioFileName("bgm.MP3"))
        XCTAssertTrue(AudioLibrary.isAudioFileName("se.wav"))
        XCTAssertTrue(AudioLibrary.isAudioFileName("voice.m4a"))
        XCTAssertFalse(AudioLibrary.isAudioFileName("movie.mp4"))
        XCTAssertFalse(AudioLibrary.isAudioFileName("pic.png"))
        XCTAssertFalse(AudioLibrary.isAudioFileName("noext"))
        XCTAssertFalse(AudioLibrary.isAudioFileName(".hidden.wav"))
    }

    func testSortIsNaturalAndStable() {
        let names = ["track10.wav", "Track2.wav", "track1.wav", "a.mp3"]
        let entries = names.map { AudioLibrary.Entry(url: URL(fileURLWithPath: "/x/\($0)"), name: $0, duration: 1) }
        XCTAssertEqual(AudioLibrary.sorted(entries).map(\.name), ["a.mp3", "track1.wav", "Track2.wav", "track10.wav"])
    }

    // MARK: 走査

    func testScanListsOnlyAudioWithDurations() async throws {
        try put("b-long.wav", wav(seconds: 2))
        try put("a-short.wav", wav(seconds: 0.5))
        try put("notes.txt", Data("hi".utf8))
        try put("pic.png", Data([0x89, 0x50]))
        try put(".secret.wav", wav(seconds: 1))
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("folder.wav"), withIntermediateDirectories: true)
        let list = await AudioLibrary.scan(folder: dir)
        XCTAssertEqual(list.map(\.name), ["a-short.wav", "b-long.wav"], "音声以外・隠し・フォルダは除く")
        XCTAssertEqual(list[0].duration ?? 0, 0.5, accuracy: 0.05)
        XCTAssertEqual(list[1].duration ?? 0, 2.0, accuracy: 0.05)
        XCTAssertTrue(list.allSatisfy(\.isReadable))
    }

    func testBrokenAudioIsKeptButNotReadable() async throws {
        try put("ok.wav", wav(seconds: 1))
        try put("broken.mp3", Data("this is not audio".utf8))
        let list = await AudioLibrary.scan(folder: dir)
        XCTAssertEqual(list.map(\.name), ["broken.mp3", "ok.wav"])
        XCTAssertEqual(list.first { $0.name == "broken.mp3" }?.isReadable, false, "壊れたファイルは一覧に残すが追加はできない")
        XCTAssertEqual(list.first { $0.name == "ok.wav" }?.isReadable, true)
    }

    func testMissingFolderGivesEmptyList() async {
        let gone = dir.appendingPathComponent("no-such-folder")
        let list = await AudioLibrary.scan(folder: gone)
        XCTAssertEqual(list, [])
    }

    func testDanglingSymlinkIsSkipped() async throws {
        let target = dir.appendingPathComponent("missing-target.wav")
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("link.wav"), withDestinationURL: target)
        let list = await AudioLibrary.scan(folder: dir)
        XCTAssertEqual(list, [], "壊れたリンクは例外にせず飛ばす")
    }
}
