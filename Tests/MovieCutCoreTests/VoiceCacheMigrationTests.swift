import XCTest
@testable import MovieCutCore

/// 旧名のキャッシュ(Application Support/yukkuri-editor/voices)を、新名(MovieCut/voices)へ引き継ぐ。
final class VoiceCacheMigrationTests: XCTestCase {
    var root: URL!
    let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("mc-migrate-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? fm.removeItem(at: root) }

    private func makeOld(_ files: [String] = ["a.wav", "b.wav"]) throws {
        let old = root.appendingPathComponent("yukkuri-editor/voices")
        try fm.createDirectory(at: old, withIntermediateDirectories: true)
        for f in files { try Data(f.utf8).write(to: old.appendingPathComponent(f)) }
        // voices 以外のものは触らない
        try Data("keep".utf8).write(to: root.appendingPathComponent("yukkuri-editor/other.txt"))
    }

    func testMovesVoicesAndKeepsEverythingElse() throws {
        try makeOld()
        XCTAssertTrue(VoiceCache.migrateLegacyVoices(in: root))
        let new = root.appendingPathComponent("MovieCut/voices")
        XCTAssertEqual(try Data(contentsOf: new.appendingPathComponent("a.wav")), Data("a.wav".utf8))
        XCTAssertTrue(fm.fileExists(atPath: new.appendingPathComponent("b.wav").path))
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("yukkuri-editor/voices").path), "移した")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("yukkuri-editor/other.txt")), Data("keep".utf8), "他は消さない")
    }

    func testDoesNothingWhenNewAlreadyExists() throws {
        try makeOld()
        let new = root.appendingPathComponent("MovieCut/voices")
        try fm.createDirectory(at: new, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: new.appendingPathComponent("n.wav"))
        XCTAssertFalse(VoiceCache.migrateLegacyVoices(in: root))
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("yukkuri-editor/voices/a.wav").path), "旧は残す")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: new.path), ["n.wav"])
    }

    func testDoesNothingWhenOldMissingAndIsIdempotent() throws {
        XCTAssertFalse(VoiceCache.migrateLegacyVoices(in: root))
        try makeOld(["x.wav"])
        XCTAssertTrue(VoiceCache.migrateLegacyVoices(in: root))
        XCTAssertFalse(VoiceCache.migrateLegacyVoices(in: root), "2 回目は何もしない")
    }

    func testFailureIsNonFatal() throws {
        try makeOld()
        // 移し先の親 "MovieCut" をファイルで塞いで失敗させる
        try Data("block".utf8).write(to: root.appendingPathComponent("MovieCut"))
        XCTAssertFalse(VoiceCache.migrateLegacyVoices(in: root))
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("yukkuri-editor/voices/a.wav").path), "失敗しても旧は残る")
    }
}
