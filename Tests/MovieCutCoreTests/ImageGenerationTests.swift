import XCTest
@testable import MovieCutCore

/// 画像生成の API 直接連携(OpenAI 互換): 設定の未設定時無効化、エンドポイント
/// 検証、リクエスト組み立て、モック応答(Base64 / URL)からのファイル生成と
/// 検証、HTTP エラー、偽プロバイダ。実サービスへの通信はしない(通信は差し替え)。
/// 認証情報は扱わない(キーは空、またはダミーの番兵文字列だけを使う)。
final class ImageGenerationTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("imagegen-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "imagegen-test-\(UUID().uuidString)")!
    }

    private func pngData() throws -> Data {
        try XCTUnwrap(QRCode.pngData(text: "imagegen-test"))
    }

    private func b64Response() throws -> Data {
        let b64 = try pngData().base64EncodedString()
        return Data("{\"data\":[{\"b64_json\":\"\(b64)\"}]}".utf8)
    }

    /// 応答を順に返す通信の差し替え(リクエストも記録する)。
    final class StubTransport: ImageGenerationTransport, @unchecked Sendable {
        var responses: [(Data, Int)]
        var requests: [URLRequest] = []
        init(_ responses: [(Data, Int)]) { self.responses = responses }
        func send(_ request: URLRequest) async throws -> (Data, Int) {
            requests.append(request)
            guard !responses.isEmpty else { throw GenerativeMediaError.transport("stub に応答が無い") }
            return responses.removeFirst()
        }
    }

    private func provider(transport: ImageGenerationTransport, apiKey: String = "") -> OpenAICompatibleImageProvider {
        OpenAICompatibleImageProvider(endpoint: URL(string: "https://example.com/v1/images/generations")!,
                                      model: "test-model", apiKey: apiKey, transport: transport, outputDirectory: dir)
    }

    // MARK: 設定(未設定なら無効)

    func testUnconfiguredIsDisabledAndThrows() {
        let s = ImageGenerationSettings.load(from: freshDefaults())
        XCTAssertFalse(s.isConfigured)
        XCTAssertEqual(s.destinationDescription, "(未設定)")
        XCTAssertThrowsError(try s.makeProvider()) {
            guard case GenerativeMediaError.notConfigured = $0 else { return XCTFail("\($0)") }
        }
    }

    func testEndpointValidationMatchesTextGeneration() {
        XCTAssertNil(ImageGenerationSettings.endpointProblem("https://example.com/v1/images/generations"))
        XCTAssertNil(ImageGenerationSettings.endpointProblem("http://127.0.0.1:8080/v1/images/generations"))
        XCTAssertNil(ImageGenerationSettings.endpointProblem("http://localhost:8080/v1/images/generations"))
        XCTAssertNotNil(ImageGenerationSettings.endpointProblem("http://example.com/v1/images/generations"), "http の外部宛ては不可")
        XCTAssertNotNil(ImageGenerationSettings.endpointProblem(""))
        XCTAssertNotNil(ImageGenerationSettings.endpointProblem("example.com"))
    }

    func testSettingsRoundTripAndConfigured() throws {
        let d = freshDefaults()
        var s = ImageGenerationSettings()
        s.endpoint = "http://127.0.0.1:8080/v1/images/generations"
        s.model = "local-model"
        s.size = ImageGenerationSize.landscape.rawValue
        s.timeoutSeconds = 30
        s.save(to: d)
        let back = ImageGenerationSettings.load(from: d)
        XCTAssertEqual(back, s)
        XCTAssertTrue(back.isConfigured)
        XCTAssertTrue(back.destinationDescription.contains("local-model"))
        _ = try back.makeProvider()
        var noModel = s
        noModel.model = " "
        XCTAssertFalse(noModel.isConfigured)
        XCTAssertThrowsError(try noModel.makeProvider()) {
            guard case GenerativeMediaError.notConfigured = $0 else { return XCTFail("\($0)") }
        }
    }

    func testConfirmationAndDestinationNeverContainAPIKey() {
        var s = ImageGenerationSettings()
        s.endpoint = "https://example.com/v1/images/generations"
        s.model = "m1"
        s.apiKey = "test-sentinel-" + "not-a-real-key"
        let c = s.confirmation(prompt: "夕焼けの海")
        XCTAssertFalse(c.summaryText.contains("test-sentinel-not-a-real-key"))
        XCTAssertFalse(c.destination.contains("test-sentinel-not-a-real-key"))
        XCTAssertFalse(s.destinationDescription.contains("test-sentinel-not-a-real-key"))
        XCTAssertTrue(c.summaryText.contains("夕焼けの海"))
    }

    // MARK: リクエスト組み立て

    func testMakeRequestBuildsOpenAICompatibleBody() throws {
        let p = provider(transport: StubTransport([]))
        let req = try p.makeRequest(GenerativeMediaRequest(kind: .image, prompt: " 夕焼けの海 ", size: "1792x1024"))
        XCTAssertEqual(req.url?.absoluteString, "https://example.com/v1/images/generations")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"), "キーが空なら付けない")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(req.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "test-model")
        XCTAssertEqual(body["prompt"] as? String, "夕焼けの海", "前後の空白は落とす")
        XCTAssertEqual(body["size"] as? String, "1792x1024")
        XCTAssertEqual(body["n"] as? Int, 1)
        XCTAssertEqual(body["response_format"] as? String, "b64_json")
    }

    func testMakeRequestPutsKeyOnlyInAuthorizationHeader() throws {
        let p = provider(transport: StubTransport([]), apiKey: "test-sentinel-" + "not-a-real-key")
        let req = try p.makeRequest(GenerativeMediaRequest(kind: .image, prompt: "海"))
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer test-sentinel-not-a-real-key")
        let bodyText = String(decoding: try XCTUnwrap(req.httpBody), as: UTF8.self)
        XCTAssertFalse(bodyText.contains("test-sentinel-not-a-real-key"), "キー��本文には入れない")
    }

    func testMakeRequestDefaultsSizeAndRejectsEmptyPrompt() throws {
        let p = provider(transport: StubTransport([]))
        let req = try p.makeRequest(GenerativeMediaRequest(kind: .image, prompt: "海"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(req.httpBody)) as? [String: Any])
        XCTAssertEqual(body["size"] as? String, ImageGenerationSize.square.rawValue)
        XCTAssertThrowsError(try p.makeRequest(GenerativeMediaRequest(kind: .image, prompt: " "))) {
            XCTAssertEqual($0 as? GenerativeMediaError, .emptyPrompt)
        }
    }

    // MARK: モック応答からの生成

    func testGenerateFromBase64ResponseWritesReadableImage() async throws {
        let stub = StubTransport([(try b64Response(), 200)])
        let p = provider(transport: stub)
        let result = try await p.generate(GenerativeMediaRequest(kind: .image, prompt: "夕焼けの海"))
        XCTAssertEqual(result.kind, .image)
        XCTAssertEqual(result.clipType, .image)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.fileURL.path))
        XCTAssertTrue(AIImageStore.isReadableImage(result.fileURL))
        XCTAssertEqual(try Data(contentsOf: result.fileURL), try pngData())
        XCTAssertEqual(stub.requests.count, 1)
    }

    func testGenerateFromURLResponseDownloadsImage() async throws {
        let stub = StubTransport([
            (Data("{\"data\":[{\"url\":\"https://example.com/made.png\"}]}".utf8), 200),
            (try pngData(), 200),
        ])
        let p = provider(transport: stub)
        let result = try await p.generate(GenerativeMediaRequest(kind: .image, prompt: "海"))
        XCTAssertTrue(AIImageStore.isReadableImage(result.fileURL))
        XCTAssertEqual(stub.requests.count, 2)
        XCTAssertEqual(stub.requests.last?.url?.absoluteString, "https://example.com/made.png")
        XCTAssertEqual(stub.requests.last?.httpMethod, "GET")
    }

    func testGenerateHTTPErrorReportsStatus() async throws {
        let stub = StubTransport([(Data("bad key".utf8), 401)])
        let p = provider(transport: stub)
        do {
            _ = try await p.generate(GenerativeMediaRequest(kind: .image, prompt: "海"))
            XCTFail("HTTP エラーは失敗する")
        } catch let e as GenerativeMediaError {
            guard case .http(let code, _) = e else { return XCTFail("別のエラー: \(e)") }
            XCTAssertEqual(code, 401)
        }
    }

    func testGenerateGarbageAndEmptyResponsesFail() async throws {
        let garbage = StubTransport([(Data("not json".utf8), 200)])
        do {
            _ = try await provider(transport: garbage).generate(GenerativeMediaRequest(kind: .image, prompt: "海"))
            XCTFail()
        } catch let e as GenerativeMediaError {
            guard case .unparsable = e else { return XCTFail("別のエラー: \(e)") }
        }
        let empty = StubTransport([(Data("{\"data\":[]}".utf8), 200)])
        do {
            _ = try await provider(transport: empty).generate(GenerativeMediaRequest(kind: .image, prompt: "海"))
            XCTFail()
        } catch {
            XCTAssertEqual(error as? GenerativeMediaError, .emptyResponse)
        }
    }

    func testGenerateNonImageBytesAreRemovedAndThrow() async throws {
        let notImage = Data("hello".utf8).base64EncodedString()
        let stub = StubTransport([(Data("{\"data\":[{\"b64_json\":\"\(notImage)\"}]}".utf8), 200)])
        do {
            _ = try await provider(transport: stub).generate(GenerativeMediaRequest(kind: .image, prompt: "海"))
            XCTFail("画像でない内容は失敗する")
        } catch {
            XCTAssertEqual(error as? GenerativeMediaError, .notAnImage)
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(leftovers.isEmpty, "読めないファイルは残さない: \(leftovers)")
    }

    func testGenerateRejectsNonImageKind() async {
        let p = provider(transport: StubTransport([]))
        do {
            _ = try await p.generate(GenerativeMediaRequest(kind: .video, prompt: "海"))
            XCTFail()
        } catch {
            XCTAssertEqual(error as? GenerativeMediaError, .unsupportedKind(.video))
        }
    }

    // MARK: 偽プロバイダ

    func testFakeProviderWritesImageAndRecordsRequest() async throws {
        let fake = FakeImageGenerationProvider(.succeed(try pngData()), outputDirectory: dir)
        let result = try await fake.generate(GenerativeMediaRequest(kind: .image, prompt: "海", size: "1024x1792"))
        XCTAssertTrue(AIImageStore.isReadableImage(result.fileURL))
        XCTAssertEqual(fake.requests.count, 1)
        XCTAssertEqual(fake.requests.first?.size, "1024x1792")
        XCTAssertEqual(fake.supportedKinds, [.image])
    }

    func testFakeProviderFailurePropagates() async {
        let fake = FakeImageGenerationProvider(.fail(.transport("offline")), outputDirectory: dir)
        do {
            _ = try await fake.generate(GenerativeMediaRequest(kind: .image, prompt: "海"))
            XCTFail()
        } catch {
            XCTAssertEqual(error as? GenerativeMediaError, .transport("offline"))
        }
    }
}
