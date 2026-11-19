import XCTest
@testable import MovieCutCore

/// AIテキスト生成(W3-08 / 監査 #74): プロンプト・読み取り・設定の未設定時無効化・
/// 汎用クライアント(通信は差し替え)・モック・台本への取り込み(純粋関数)。
/// 実サービスへの通信はしない(認証情報も扱わない)。
final class TextGenerationTests: XCTestCase {
    let names = ["キャラ1", "キャラ3"]

    // MARK: プロンプトと読み取り

    func testPromptContainsThemeKeywordsCountAndContext() {
        let r = DialogueGenerationRequest(theme: "猫カフェ", keywords: ["猫", "雨"], characterNames: names, count: 5,
                                          contextLines: ["キャラ1: いらっしゃい"])
        let s = DialogueSuggestionPrompt.build(r)
        XCTAssertTrue(s.contains("猫カフェ"))
        XCTAssertTrue(s.contains("猫、雨"))
        XCTAssertTrue(s.contains("キャラ1、キャラ3"))
        XCTAssertTrue(s.contains("5 件"))
        XCTAssertTrue(s.contains("キャラ1: いらっしゃい"), "今の台本を続きの参考として渡す")
    }

    func testPromptClampsCount() {
        let s = DialogueSuggestionPrompt.build(.init(theme: "x", characterNames: names, count: 999))
        XCTAssertTrue(s.contains("30 件"))
    }

    func testParseKnownSpeakersFencesAndPlainLines() throws {
        let r = """
        もちろんです。
        ```
        キャラ1: こんにちは
        キャラ3：やあ
        - キャラ1: 「元気だよ」
        そのままの文
        ナレーター: 知らない人は捨てる
        キャラ1: こんにちは
        ```
        """
        let got = try DialogueSuggestionPrompt.parse(r, characterNames: names)
        XCTAssertEqual(got, [
            DialogueSuggestion(characterName: "キャラ1", text: "こんにちは"),
            DialogueSuggestion(characterName: "キャラ3", text: "やあ"),
            DialogueSuggestion(characterName: "キャラ1", text: "元気だよ"),
            DialogueSuggestion(characterName: nil, text: "そのままの文"),
        ])
    }

    func testParseGarbageThrows() {
        XCTAssertThrowsError(try DialogueSuggestionPrompt.parse("すみません、できません。", characterNames: names)) {
            guard case TextGenerationError.unparsable = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try DialogueSuggestionPrompt.parse("", characterNames: names))
    }

    func testParsedLinesAreImportableByExistingParser() throws {
        let p = Project.new()
        for s in try DialogueSuggestionPrompt.parse("キャラ1: やあ\nキャラ3: どうも", characterNames: names) {
            let (who, text) = try XCTUnwrap(ScriptTimeline.parse(line: s.scriptLine, characters: p.characters, selectedCharId: nil))
            XCTAssertEqual(who.name, s.characterName)
            XCTAssertFalse(text.isEmpty)
        }
    }

    // MARK: 設定(未設定なら無効)

    private func freshDefaults() -> UserDefaults {
        let d = UserDefaults(suiteName: "textgen-test-\(UUID().uuidString)")!
        return d
    }

    func testUnconfiguredIsDisabledAndThrows() {
        let s = TextGenerationSettings.load(from: freshDefaults())
        XCTAssertFalse(s.isConfigured)
        XCTAssertEqual(s.destinationDescription, "(未設定)")
        XCTAssertThrowsError(try s.makeProvider()) {
            guard case TextGenerationError.notConfigured = $0 else { return XCTFail("\($0)") }
        }
    }

    func testEndpointValidation() {
        XCTAssertNil(TextGenerationSettings.endpointProblem("https://example.com/v1/chat/completions"))
        XCTAssertNil(TextGenerationSettings.endpointProblem("http://127.0.0.1:11434/v1/chat/completions"))
        XCTAssertNil(TextGenerationSettings.endpointProblem("http://localhost:1234/v1/chat/completions"))
        XCTAssertNotNil(TextGenerationSettings.endpointProblem("http://example.com/v1/chat/completions"), "http の外部宛ては不可")
        XCTAssertNotNil(TextGenerationSettings.endpointProblem(""))
        XCTAssertNotNil(TextGenerationSettings.endpointProblem("example.com"))
        XCTAssertNotNil(TextGenerationSettings.endpointProblem("ftp://example.com"))
    }

    func testSettingsRoundTripAndConfigured() throws {
        let d = freshDefaults()
        var s = TextGenerationSettings()
        s.endpoint = "http://127.0.0.1:11434/v1/chat/completions"
        s.model = "local-model"
        s.timeoutSeconds = 30
        s.save(to: d)
        let back = TextGenerationSettings.load(from: d)
        XCTAssertEqual(back, s)
        XCTAssertTrue(back.isConfigured)
        XCTAssertTrue(back.destinationDescription.contains("local-model"))
        _ = try back.makeProvider()   // 未設定エラーにならない
        // モデルが空なら未設定扱い
        var noModel = s
        noModel.model = " "
        XCTAssertFalse(noModel.isConfigured)
        XCTAssertThrowsError(try noModel.makeProvider()) {
            guard case TextGenerationError.notConfigured = $0 else { return XCTFail("\($0)") }
        }
    }

    // MARK: 汎用クライアント(通信は差し替え)

    final class StubTransport: TextGenerationTransport, @unchecked Sendable {
        var responseData: Data
        var status: Int
        var lastRequest: URLRequest?
        init(data: Data, status: Int = 200) { responseData = data; self.status = status }
        func send(_ request: URLRequest) async throws -> (Data, Int) {
            lastRequest = request
            return (responseData, status)
        }
    }

    private func chatJSON(_ content: String) -> Data {
        let obj: [String: Any] = ["choices": [["message": ["role": "assistant", "content": content]]]]
        return try! JSONSerialization.data(withJSONObject: obj)
    }

    func testHTTPProviderParsesChatResponse() async throws {
        let transport = StubTransport(data: chatJSON("キャラ1: こんにちは\nキャラ3: やあ"))
        let provider = OpenAICompatibleTextProvider(endpoint: URL(string: "http://127.0.0.1:11434/v1/chat/completions")!,
                                                    model: "local-model", transport: transport)
        let got = try await provider.generateDialogue(.init(theme: "猫", characterNames: names, count: 2))
        XCTAssertEqual(got.map(\.scriptLine), ["キャラ1: こんにちは", "キャラ3: やあ"])
        let req = try XCTUnwrap(transport.lastRequest)
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"), "キーが無ければヘッダーも付けない")
        let body = try XCTUnwrap(req.httpBody)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        XCTAssertEqual(json?["model"] as? String, "local-model")
        let messages = json?["messages"] as? [[String: Any]]
        XCTAssertTrue((messages?.first?["content"] as? String)?.contains("猫") == true)
    }

    func testHTTPProviderSendsKeyOnlyAsHeaderWhenUserSetIt() async throws {
        // 実際の認証情報ではない、テスト専用のダミー文字列。ヘッダーにだけ入ることの確認用。
        let transport = StubTransport(data: chatJSON("キャラ1: はい"))
        let provider = OpenAICompatibleTextProvider(endpoint: URL(string: "https://example.com/v1/chat/completions")!,
                                                    model: "m", apiKey: "dummy-test-key", transport: transport)
        _ = try await provider.generateDialogue(.init(theme: "x", characterNames: names))
        XCTAssertEqual(transport.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer dummy-test-key")
    }

    func testHTTPProviderHTTPErrorAndBadBody() async {
        let transport = StubTransport(data: Data("server boom".utf8), status: 500)
        let provider = OpenAICompatibleTextProvider(endpoint: URL(string: "https://example.com/v1/chat/completions")!,
                                                    model: "m", transport: transport)
        do {
            _ = try await provider.generateDialogue(.init(theme: "x", characterNames: names))
            XCTFail("失敗するはず")
        } catch let e as TextGenerationError {
            guard case .http(500, _) = e else { return XCTFail("\(e)") }
        } catch { XCTFail("\(error)") }

        let bad = StubTransport(data: Data("{}".utf8), status: 200)
        let p2 = OpenAICompatibleTextProvider(endpoint: URL(string: "https://example.com/v1/chat/completions")!,
                                              model: "m", transport: bad)
        do {
            _ = try await p2.generateDialogue(.init(theme: "x", characterNames: names))
            XCTFail("失敗するはず")
        } catch let e as TextGenerationError {
            XCTAssertEqual(e, .unparsable)
        } catch { XCTFail("\(error)") }
    }

    // MARK: モックと取り込み

    func testFakeProviderRecordsRequests() async throws {
        let fake = FakeTextGenerationProvider(.suggestions([DialogueSuggestion(characterName: "キャラ1", text: "案です")]))
        let got = try await fake.generateDialogue(.init(theme: "猫", keywords: ["雨"], characterNames: names, count: 3))
        XCTAssertEqual(got.count, 1)
        XCTAssertEqual(fake.requests.count, 1)
        XCTAssertEqual(fake.requests.first?.theme, "猫")
        XCTAssertEqual(fake.requests.first?.keywords, ["雨"])
    }

    func testImportAppendingDedupesAndHandlesEmptyScript() {
        let suggestions = [DialogueSuggestion(characterName: "キャラ1", text: "こんにちは"),
                           DialogueSuggestion(characterName: nil, text: "ナレーション")]
        let (t1, n1) = DialogueImport.appending(suggestions, to: "")
        XCTAssertEqual(t1, "キャラ1: こんにちは\nナレーション")
        XCTAssertEqual(n1, 2)
        // 既にある行は足さない
        let (t2, n2) = DialogueImport.appending(suggestions, to: t1)
        XCTAssertEqual(t2, t1)
        XCTAssertEqual(n2, 0)
        // 末尾に足す
        let (t3, n3) = DialogueImport.appending([DialogueSuggestion(characterName: "キャラ3", text: "やあ")], to: t1)
        XCTAssertEqual(t3, t1 + "\nキャラ3: やあ")
        XCTAssertEqual(n3, 1)
    }
}
