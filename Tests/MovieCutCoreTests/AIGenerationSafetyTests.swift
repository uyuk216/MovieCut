import XCTest
@testable import MovieCutCore

/// C22(AI・生成・マルチカメラ): 巨大値・非有限値でのクラッシュ、URL生成、
/// 箇条書き誤認、マルチカメラの消音と範囲、SIGTERM無視プロセスの強制終了。
final class AIGenerationSafetyTests: XCTestCase {

    func testPlacementDurationRejectsInfinity() {
        let r = GenerativeMediaResult(kind: .video, fileURL: URL(fileURLWithPath: "/tmp/x.mp4"), duration: .infinity)
        XCTAssertEqual(r.placementDuration, GenerativeMediaKind.video.defaultDuration)
        let ok = GenerativeMediaResult(kind: .video, fileURL: URL(fileURLWithPath: "/tmp/x.mp4"), duration: 7)
        XCTAssertEqual(ok.placementDuration, 7)
    }

    func testSecondsTextHandlesHugeValues() {
        XCTAssertEqual(VideoGenerationSettings.secondsText(5), "5")
        XCTAssertFalse(VideoGenerationSettings.secondsText(1e20).isEmpty)
        XCTAssertFalse(VideoGenerationSettings.secondsText(.infinity).isEmpty)
    }

    func testJobURLKeepsQueryAndEncodesId() {
        let p = OpenAICompatibleVideoProvider(endpoint: URL(string: "https://example.com/videos?version=1")!, model: "m")
        let u = p.jobURL(id: "job/123")
        XCTAssertTrue(u.absoluteString.contains("/videos/job%2F123"), "ID は1つのパス要素として符号化される: \(u)")
        XCTAssertEqual(URLComponents(url: u, resolvingAgainstBaseURL: false)?.query, "version=1")
    }

    func testCleanLineKeepsLeadingDecimal() {
        XCTAssertEqual(AIText.cleanLine("3.14について"), "3.14について")
        XCTAssertEqual(AIText.cleanLine("1. テスト"), "テスト")
        XCTAssertEqual(AIText.cleanLine("0.5秒待って"), "0.5秒待って")
    }

    func testTranslateParseKeepsLeadingDecimalAndRejectsBadExpected() throws {
        XCTAssertEqual(try AITranslatePrompt.parse("1\t.5 seconds", expected: 1), [".5 seconds"])
        XCTAssertEqual(try AITranslatePrompt.parse("", expected: 0), [])
        XCTAssertEqual(try AITranslatePrompt.parse("1\tHi", expected: -1), [])
    }

    func testMulticamRangeRejectsNegativeDuration() {
        var c = Clip(); c.type = .video; c.start = 10; c.duration = -1
        let g = MulticamGroup(name: "g", angles: [MulticamAngle(name: "a", clip: c, syncOffset: 0)], targetTrackId: "t")
        XCTAssertNil(g.range)
    }

    func testMulticamMakeGroupSilencesVolumeKeyframes() {
        var ref = Clip(); ref.id = "ref"; ref.type = .video; ref.src = "/a.mp4"; ref.start = 0; ref.duration = 5
        var other = Clip(); other.id = "other"; other.type = .video; other.src = "/b.mp4"; other.start = 0; other.duration = 5
        other.keyframes["volume"] = [Keyframe(t: 0, v: 1), Keyframe(t: 5, v: 1)]
        var t1 = Track(); t1.clips = [ref]
        var t2 = Track(); t2.clips = [other]
        var p = Project(); p.tracks = [t1, t2]
        let outcome = Multicam.makeGroup(in: p, ids: ["ref", "other"], localLags: [:])
        guard case .created(let np, _) = outcome else { return XCTFail("グループが作れませんでした: \(outcome)") }
        let muted = np.tracks.flatMap(\.clips).first { $0.id == "other" }
        XCTAssertEqual(muted?.volume, 0)
        XCTAssertNil(muted?.keyframes["volume"], "音量キーフレームが残るとミキサーで音が出る")
    }

    func testTruncatedPNGIsNotReadable() throws {
        // 実物の 1x1 PNG を IHDR の途中で切る(ヘッダーは読めても画素はデコードできない)
        let full = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("c22-\(UUID().uuidString).png")
        try full.prefix(40).write(to: u)
        defer { try? FileManager.default.removeItem(at: u) }
        XCTAssertFalse(AIImageStore.isReadableImage(u))
        let good = FileManager.default.temporaryDirectory.appendingPathComponent("c22-\(UUID().uuidString).png")
        try full.write(to: good)
        defer { try? FileManager.default.removeItem(at: good) }
        XCTAssertTrue(AIImageStore.isReadableImage(good))
    }

    func testProcessRunForceKillsSIGTERMIgnoringCommand() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("c22-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("stubborn.sh")
        try "#!/bin/sh\ntrap '' TERM\nsleep 30\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let run = ProcessRun(executable: "/bin/sh", arguments: [script.path], input: Data(), timeout: 1, maxOutputBytes: 1024)
        let started = Date()
        do {
            _ = try await run.start()
            XCTFail("時間切れになるはず")
        } catch let e as AIError {
            guard case .timedOut = e else { return XCTFail("timedOut のはず: \(e)") }
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "SIGKILL への格上げで有限時間に戻る")
    }
}
