import XCTest
@testable import MovieCutCore

final class AITests: XCTestCase {
    // MARK: 台本
    let names = ["霊夢", "魔理沙"]

    func testScriptParseToleratesFencesAndProse() throws {
        let r = """
        もちろんです!台本です。
        ```
        霊夢: こんにちは
        魔理沙：やあ、元気か?
        - 霊夢: 「元気だよ」
        **魔理沙**: そうか
        ナレーター: 知らない人
        ```
        以上です。
        """
        XCTAssertEqual(try AIScriptPrompt.parse(r, characterNames: names), ["霊夢: こんにちは", "魔理沙: やあ、元気か?", "霊夢: 元気だよ", "魔理沙: そうか"])
    }
    func testScriptParseWithoutFences() throws {
        XCTAssertEqual(try AIScriptPrompt.parse("前置き\n1. 霊夢: はい\n説明: これは無視", characterNames: names), ["霊夢: はい"])
    }
    func testScriptGarbageThrows() {
        XCTAssertThrowsError(try AIScriptPrompt.parse("すみません、できません。", characterNames: names)) {
            guard case AIError.unparsable = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try AIScriptPrompt.parse("", characterNames: names))
    }
    func testScriptParsedLinesAreImportableByExistingParser() throws {
        let p = Project.new()
        for l in try AIScriptPrompt.parse("霊夢: やあ", characterNames: p.characters.map(\.name)) {
            let (who, text) = try XCTUnwrap(ScriptTimeline.parse(line: l, characters: p.characters, selectedCharId: nil))
            XCTAssertEqual(who.name, "霊夢"); XCTAssertEqual(text, "やあ")
        }
    }
    func testScriptPromptContainsThemeAndNames() {
        let s = AIScriptPrompt.build(.init(theme: "猫の飼い方", characterNames: names, lineCount: 10))
        XCTAssertTrue(s.contains("猫の飼い方")); XCTAssertTrue(s.contains("霊夢、魔理沙")); XCTAssertTrue(s.contains("10 行"))
        XCTAssertTrue(AIScriptPrompt.build(.init(theme: "x", characterNames: names, lineCount: 9999)).contains("60 行"))
    }

    // MARK: チャプター
    func testChapterParse() throws {
        let r = "```\n0:00 イントロ\n[1:05] - 本題\n2:30 まとめ\n99:00 長さ超え\n```"
        let c = try AIChapterPrompt.parse(r, duration: 200)
        XCTAssertEqual(c.map(\.time), [0, 65, 150])
        XCTAssertEqual(c.map(\.title), ["イントロ", "本題", "まとめ"])
        let made = Chapters.make(from: AIChapterPrompt.markers(from: c))
        XCTAssertEqual(made.text, "0:00 イントロ\n1:05 本題\n2:30 まとめ")
        XCTAssertTrue(made.warnings.isEmpty)
    }
    func testChapterParseSortsDedupesAndHours() throws {
        let c = try AIChapterPrompt.parse("1:00:05 後\n0:30 A\n0:30 重複\n1. 0:00 先頭", duration: 4000)
        XCTAssertEqual(c.map(\.time), [0, 30, 3605])
        XCTAssertEqual(c[1].title, "A")
    }
    func testChapterGarbageThrows() {
        XCTAssertThrowsError(try AIChapterPrompt.parse("チャプターは作れません", duration: 100))
    }
    func testChapterPromptTruncatesLongInput() {
        let cues = (0..<3000).map { SubtitleCue(start: Double($0), end: Double($0) + 1, text: "あいうえおかきくけこ") }
        let r = AIChapterPrompt.build(cues: cues, duration: 3000)
        XCTAssertTrue(r.truncated)
        XCTAssertLessThan(r.prompt.count, AIChapterPrompt.maxInputCharacters + 1000)
        XCTAssertFalse(AIChapterPrompt.build(cues: Array(cues.prefix(3)), duration: 10).truncated)
    }

    // MARK: 言い換え
    func testRewriteParse() throws {
        XCTAssertEqual(try AIRewritePrompt.parse("「こんにちは」"), "こんにちは")
        XCTAssertEqual(try AIRewritePrompt.parse("直したセリフ: やあ"), "やあ")
        XCTAssertEqual(try AIRewritePrompt.parse("```\nどうも\n```"), "どうも")
        XCTAssertEqual(try AIRewritePrompt.parse("\n\n- はい。\n二行目"), "はい。")
        XCTAssertThrowsError(try AIRewritePrompt.parse("  \n```\n```"))
        XCTAssertEqual(try AIRewritePrompt.parse(String(repeating: "あ", count: 1000)).count, AIRewritePrompt.maxLength)
    }
    func testRewritePromptHasOriginal() {
        let s = AIRewritePrompt.build(text: "元の文", characterName: "霊夢", mode: .shorten)
        XCTAssertTrue(s.contains("元の文")); XCTAssertTrue(s.contains("短く")); XCTAssertTrue(s.contains("霊夢"))
    }

    // MARK: 偽プロバイダ
    func testFakeProviderEndToEnd() async throws {
        let f = FakeAIProvider(.reply("霊夢: はい\n魔理沙: いいえ"))
        let out = try await f.complete("p")
        XCTAssertEqual(try AIScriptPrompt.parse(out, characterNames: names).count, 2)
        XCTAssertEqual(f.prompts, ["p"])
    }
    func testFakeProviderCancel() async {
        let f = FakeAIProvider(.delay(seconds: 5, reply: "x"))
        let t = Task { try await f.complete("p") }
        try? await Task.sleep(nanoseconds: 50_000_000)
        t.cancel()
        do { _ = try await t.value; XCTFail() } catch { XCTAssertEqual(error as? AIError, .cancelled) }
    }
    func testJapaneseErrorMessages() {
        let all: [AIError] = [.notConfigured, .emptyCommand, .commandNotFound("x"), .launchFailed("y"), .timedOut(3), .cancelled, .nonZeroExit(2, "boom"), .outputTooLarge(10), .emptyResponse, .notLocalURL("http://e.com"), .serverUnreachable("z"), .httpStatus(500), .badResponse, .unparsable("台本")]
        for e in all { XCTAssertTrue(e.localizedDescription.unicodeScalars.contains { $0.value > 0x3000 }, "\(e)") }
    }

    // MARK: コマンド版(実プロセス。無害なスクリプトだけ)
    func script(_ body: String) throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ai-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("fake ai.sh")   // 空白入りのパスも試す
        try ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return url.path
    }
    func quoted(_ p: String) -> String { "'" + p + "'" }

    func testCommandSuccessReadsStdin() async throws {
        let path = try script("read -r first\nprintf '霊夢: 受け取った(%s)\\n' \"$first\"\n")
        let p = try CommandAIProvider(commandLine: quoted(path) + " --flag", timeout: 10)
        let out = try await p.complete("テーマ\n二行目")
        XCTAssertEqual(out, "霊夢: 受け取った(テーマ)\n")
    }
    func testCommandGarbageOutputStillReturnsButParserRejects() async throws {
        let path = try script("echo 'すみません、お手伝いできません'\n")
        let out = try await CommandAIProvider(commandLine: quoted(path), timeout: 10).complete("x")
        XCTAssertThrowsError(try AIScriptPrompt.parse(out, characterNames: names))
    }
    func testCommandTimeout() async throws {
        let path = try script("sleep 30\n")
        let p = try CommandAIProvider(commandLine: quoted(path), timeout: 0.5)
        let t0 = Date()
        do { _ = try await p.complete("x"); XCTFail() } catch { XCTAssertEqual(error as? AIError, .timedOut(1)) }
        XCTAssertLessThan(Date().timeIntervalSince(t0), 10)
    }
    func testCommandCancel() async throws {
        let path = try script("sleep 30\n")
        let p = try CommandAIProvider(commandLine: quoted(path), timeout: 60)
        let t = Task { try await p.complete("x") }
        try await Task.sleep(nanoseconds: 300_000_000)
        let t0 = Date()
        t.cancel()
        do { _ = try await t.value; XCTFail() } catch { XCTAssertEqual(error as? AIError, .cancelled) }
        XCTAssertLessThan(Date().timeIntervalSince(t0), 5)
    }
    func testCommandHugeOutputIsCapped() async throws {
        let path = try script("yes 'あいうえおかきくけこ'\n")
        let p = try CommandAIProvider(commandLine: quoted(path), timeout: 20, maxOutputBytes: 10_000)
        let t0 = Date()
        do { _ = try await p.complete("x"); XCTFail() } catch { XCTAssertEqual(error as? AIError, .outputTooLarge(10_000)) }
        XCTAssertLessThan(Date().timeIntervalSince(t0), 10)
    }
    func testCommandNonZeroExitShowsStderr() async throws {
        let path = try script("echo 'ログインが必要です' >&2\nexit 3\n")
        do { _ = try await CommandAIProvider(commandLine: quoted(path), timeout: 10).complete("x"); XCTFail() } catch {
            XCTAssertEqual(error as? AIError, .nonZeroExit(3, "ログインが必要です\n"))
            XCTAssertTrue(error.localizedDescription.contains("ログインが必要です"))
        }
    }
    func testCommandEmptyOutput() async throws {
        let path = try script("exit 0\n")
        do { _ = try await CommandAIProvider(commandLine: quoted(path), timeout: 10).complete("x"); XCTFail() } catch { XCTAssertEqual(error as? AIError, .emptyResponse) }
    }
    func testCommandMissingAndEmpty() {
        XCTAssertThrowsError(try CommandAIProvider(commandLine: "/nonexistent/zzz -p")) { XCTAssertEqual($0 as? AIError, .commandNotFound("/nonexistent/zzz")) }
        XCTAssertThrowsError(try CommandAIProvider(commandLine: "   ")) { XCTAssertEqual($0 as? AIError, .emptyCommand) }
        XCTAssertThrowsError(try CommandAIProvider(commandLine: "definitely-not-a-command-xyz")) { XCTAssertEqual($0 as? AIError, .commandNotFound("definitely-not-a-command-xyz")) }
    }
    func testCommandLineSplit() {
        XCTAssertEqual(AICommandLine.split("claude -p"), ["claude", "-p"])
        XCTAssertEqual(AICommandLine.split(#"a "b c" 'd e' f\ g ''"#), ["a", "b c", "d e", "f g", ""])
        XCTAssertEqual(AICommandLine.split("  "), [])
        // シェルの記号は解釈しない(そのまま引数)
        XCTAssertEqual(AICommandLine.split("echo hi; rm -rf x | cat"), ["echo", "hi;", "rm", "-rf", "x", "|", "cat"])
    }

    // MARK: HTTP 版
    func testHTTPRejectsNonLocal() {
        for u in ["http://example.com", "https://127.0.0.1", "http://192.168.0.2:11434", "ftp://localhost", "garbage"] {
            XCTAssertThrowsError(try HTTPAIProvider(baseURL: u, model: "m"), u) { guard case AIError.notLocalURL = $0 else { return XCTFail() } }
        }
        XCTAssertNoThrow(try HTTPAIProvider(baseURL: "http://127.0.0.1:11434", model: "m"))
        XCTAssertNoThrow(try HTTPAIProvider(baseURL: "http://localhost:11434", model: "m"))
        XCTAssertNoThrow(try HTTPAIProvider(baseURL: "http://[::1]:11434", model: "m"))
    }
    func testHTTPRequestAndResponse() async throws {
        let box = Box()
        let p = try HTTPAIProvider(baseURL: "http://127.0.0.1:11434", model: "gemma", transport: { req in
            box.set(req)
            return (Data(#"{"response":"霊夢: はい","done":true}"#.utf8), 200)
        })
        let out = try await p.complete("プロンプト")
        XCTAssertEqual(out, "霊夢: はい")
        let req = try XCTUnwrap(box.req)
        XCTAssertEqual(req.url?.absoluteString, "http://127.0.0.1:11434/api/generate")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(req.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "gemma"); XCTAssertEqual(body["prompt"] as? String, "プロンプト"); XCTAssertEqual(body["stream"] as? Bool, false)
    }
    func testHTTPErrors() async throws {
        func make(_ t: @escaping HTTPAIProvider.Transport) throws -> HTTPAIProvider { try HTTPAIProvider(baseURL: "http://localhost:1", model: "m", transport: t) }
        do { _ = try await make({ _ in (Data(), 500) }).complete("x"); XCTFail() } catch { XCTAssertEqual(error as? AIError, .httpStatus(500)) }
        do { _ = try await make({ _ in (Data("nope".utf8), 200) }).complete("x"); XCTFail() } catch { XCTAssertEqual(error as? AIError, .badResponse) }
        do { _ = try await make({ _ in (Data(#"{"response":" "}"#.utf8), 200) }).complete("x"); XCTFail() } catch { XCTAssertEqual(error as? AIError, .emptyResponse) }
        do { _ = try await make({ _ in throw URLError(.cannotConnectToHost) }).complete("x"); XCTFail() } catch { guard case AIError.serverUnreachable = error else { return XCTFail("\(error)") } }
        do { _ = try await make({ _ in (Data(count: HTTPAIProvider.maxResponseBytes + 1), 200) }).complete("x"); XCTFail() } catch { guard case AIError.outputTooLarge = error else { return XCTFail("\(error)") } }
        do { _ = try await make({ _ in throw URLError(.timedOut) }).complete("x"); XCTFail() } catch { guard case AIError.timedOut = error else { return XCTFail("\(error)") } }
    }

    // MARK: 設定
    func testSettingsRoundTripAndProvider() throws {
        let d = UserDefaults(suiteName: "ai-test-\(UUID().uuidString)")!
        XCTAssertEqual(AISettings.load(from: d).kind, .none)
        XCTAssertThrowsError(try AISettings.load(from: d).makeProvider()) { XCTAssertEqual($0 as? AIError, .notConfigured) }
        var s = AISettings(); s.kind = .http; s.url = "http://localhost:11434"; s.model = "m"; s.timeoutSeconds = 30
        s.save(to: d)
        XCTAssertEqual(AISettings.load(from: d), s)
        XCTAssertTrue(try s.makeProvider() is HTTPAIProvider)
        s.kind = .command; s.command = "/bin/cat"
        XCTAssertTrue(try s.makeProvider() is CommandAIProvider)
        s.timeoutSeconds = 99999; s.save(to: d)
        XCTAssertEqual(AISettings.load(from: d).timeoutSeconds, 900)
        XCTAssertTrue(s.destinationDescription.contains("/bin/cat"))
    }

    // MARK: project-info
    func testProjectInfoJSON() async throws {
        var p = Project.new()
        let dir = FileManager.default.temporaryDirectory
        try await ScriptTimeline.add(lines: ["霊夢: こんにちは"], to: &p, voice: ToneVoiceProvider(), directory: dir)
        p.markers = [Marker(time: 1, name: "章")]
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try ProjectInfo.json(p).utf8)) as? [String: Any])
        XCTAssertEqual(obj["size"] as? String, "1920x1080")
        XCTAssertEqual(obj["clipCount"] as? Int, 1)
        XCTAssertEqual(obj["script"] as? [String], ["霊夢: こんにちは"])
        XCTAssertEqual((obj["characters"] as? [[String: Any]])?.count, 3)
        XCTAssertEqual((obj["markers"] as? [[String: Any]])?.first?["name"] as? String, "章")
        let clip = try XCTUnwrap((obj["clips"] as? [[String: Any]])?.first)
        XCTAssertEqual(clip["character"] as? String, "霊夢"); XCTAssertEqual(clip["type"] as? String, "voice")
    }
}

private final class Box: @unchecked Sendable {
    private let l = NSLock(); private var r: URLRequest?
    func set(_ x: URLRequest) { l.withLock { r = x } }
    var req: URLRequest? { l.withLock { r } }
}
