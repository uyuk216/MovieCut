import XCTest
@testable import MovieCutCore

/// W5-4: 動画生成(非同期ジョブのポーリング)・音声/音楽生成(同期応答)・
/// 生成延長の計画と配置。実サービスへの通信はしない(通信は差し替え)。
/// 認証情報は扱わない(キーは空、またはダミーの番兵文字列だけを使う)。
final class GenerativeMediaProvidersTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("genmedia-av-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "genmedia-av-test-\(UUID().uuidString)")!
    }

    /// 応答を順に返す通信の差し替え(リクエストも記録する)。
    final class AVStubTransport: ImageGenerationTransport, @unchecked Sendable {
        var responses: [(Data, Int)]
        var requests: [URLRequest] = []
        init(_ responses: [(Data, Int)]) { self.responses = responses }
        func send(_ request: URLRequest) async throws -> (Data, Int) {
            requests.append(request)
            guard !responses.isEmpty else { throw GenerativeMediaError.transport("stub に応答が無い") }
            return responses.removeFirst()
        }
    }

    private func videoProvider(transport: ImageGenerationTransport, apiKey: String = "", maxPoll: Int = 3) -> OpenAICompatibleVideoProvider {
        OpenAICompatibleVideoProvider(endpoint: URL(string: "https://example.com/v1/videos")!,
                                      model: "video-model", apiKey: apiKey, pollIntervalSeconds: 0,
                                      maxPollAttempts: maxPoll, transport: transport, outputDirectory: dir)
    }

    private func audioProvider(transport: ImageGenerationTransport, apiKey: String = "") -> OpenAICompatibleAudioProvider {
        OpenAICompatibleAudioProvider(endpoint: URL(string: "https://example.com/v1/audio/generations")!,
                                      model: "audio-model", apiKey: apiKey, transport: transport, outputDirectory: dir)
    }

    private func bodyJSON(_ req: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(req.httpBody)) as? [String: Any])
    }

    // MARK: 保存場所と形式

    func testStoreSanitizesFormatAndDefaults() {
        XCTAssertEqual(GeneratedMediaStore.sanitizedFormat(nil, for: .video), "mp4")
        XCTAssertEqual(GeneratedMediaStore.sanitizedFormat(".MP4", for: .video), "mp4")
        XCTAssertEqual(GeneratedMediaStore.sanitizedFormat("we b/m", for: .audio), "webm")
        XCTAssertEqual(GeneratedMediaStore.sanitizedFormat("../etc", for: .music), "etc")
        XCTAssertEqual(GeneratedMediaStore.sanitizedFormat("", for: .audio), "mp3")
        XCTAssertEqual(GeneratedMediaStore.directory().path, DataLocations.current.generatedMedia.path)
        XCTAssertTrue(DataLocations.current.allPaths.contains(DataLocations.current.generatedMedia))
    }

    func testResponseParsingHelpers() throws {
        let data = Data("{\"id\":\"job-1\",\"status\":\"In_Progress\",\"data\":[{\"url\":\"https://example.com/x.mp4\"}]}".utf8)
        XCTAssertEqual(GenerativeResponseParsing.jobID(from: data), "job-1")
        XCTAssertEqual(GenerativeResponseParsing.jobStatus(from: data), "in_progress")
        XCTAssertEqual(GenerativeResponseParsing.mediaURL(from: data)?.absoluteString, "https://example.com/x.mp4")
        XCTAssertTrue(GenerativeResponseParsing.isInProgress("in_progress"))
        XCTAssertFalse(GenerativeResponseParsing.isInProgress("completed"))
        XCTAssertFalse(GenerativeResponseParsing.isInProgress("failed"))
        let fail = Data("{\"status\":\"failed\",\"error\":{\"message\":\"だめでした\"}}".utf8)
        XCTAssertEqual(GenerativeResponseParsing.failureDetail(from: fail), "だめでした")
    }

    // MARK: 動画 - リクエスト組み立て

    func testVideoMakeRequestBuildsBodyWithSizeDurationFormat() throws {
        let p = videoProvider(transport: AVStubTransport([]))
        let req = try p.makeRequest(GenerativeMediaRequest(kind: .video, prompt: " 海を飛ぶ ", targetDuration: 8, size: "720x1280", outputFormat: "mov"))
        XCTAssertEqual(req.url?.absoluteString, "https://example.com/v1/videos")
        XCTAssertEqual(req.httpMethod, "POST")
        let body = try bodyJSON(req)
        XCTAssertEqual(body["model"] as? String, "video-model")
        XCTAssertEqual(body["prompt"] as? String, "海を飛ぶ")
        XCTAssertEqual(body["size"] as? String, "720x1280")
        XCTAssertEqual(body["seconds"] as? Double, 8)
        XCTAssertEqual(body["output_format"] as? String, "mov")
        XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"), "キーが空なら付けない")
    }

    func testVideoMakeRequestPutsKeyOnlyInAuthorizationHeader() throws {
        let p = videoProvider(transport: AVStubTransport([]), apiKey: "test-sentinel-" + "not-a-real-key")
        let req = try p.makeRequest(GenerativeMediaRequest(kind: .video, prompt: "海"))
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer test-sentinel-not-a-real-key")
        XCTAssertFalse(String(decoding: try XCTUnwrap(req.httpBody), as: UTF8.self).contains("test-sentinel-not-a-real-key"))
        XCTAssertEqual(p.jobURL(id: "job 1").absoluteString, "https://example.com/v1/videos/job%201")
        XCTAssertEqual(p.contentURL(id: "job-1").absoluteString, "https://example.com/v1/videos/job-1/content")
    }

    // MARK: 動画 - 同期完了 / ポーリング / 失敗 / 時間切れ

    func testVideoGenerateSyncBase64Response() async throws {
        let bytes = Data("fake-mp4-bytes".utf8)
        let payload = Data("{\"data\":[{\"b64_json\":\"\(bytes.base64EncodedString())\"}]}".utf8)
        let stub = AVStubTransport([(payload, 200)])
        let result = try await videoProvider(transport: stub).generate(
            GenerativeMediaRequest(kind: .video, prompt: "海", targetDuration: 6, outputFormat: "mp4"))
        XCTAssertEqual(result.kind, .video)
        XCTAssertEqual(result.clipType, .video)
        XCTAssertEqual(result.duration, 6)
        XCTAssertEqual(result.fileURL.pathExtension, "mp4")
        XCTAssertEqual(try Data(contentsOf: result.fileURL), bytes)
        XCTAssertEqual(stub.requests.count, 1, "同期完了ならポーリングしない")
    }

    func testVideoGeneratePollsUntilCompletedThenDownloadsURL() async throws {
        let stub = AVStubTransport([
            (Data("{\"id\":\"job-9\",\"status\":\"queued\"}".utf8), 200),
            (Data("{\"id\":\"job-9\",\"status\":\"in_progress\"}".utf8), 200),
            (Data("{\"id\":\"job-9\",\"status\":\"completed\",\"url\":\"https://example.com/made.mp4\"}".utf8), 200),
            (Data("video-bytes".utf8), 200),
        ])
        let result = try await videoProvider(transport: stub).generate(
            GenerativeMediaRequest(kind: .video, prompt: "海", targetDuration: 4))
        XCTAssertEqual(try Data(contentsOf: result.fileURL), Data("video-bytes".utf8))
        XCTAssertEqual(stub.requests.count, 4, "作成 1 + ポーリング 2 + 取得 1")
        XCTAssertEqual(stub.requests[1].url?.absoluteString, "https://example.com/v1/videos/job-9")
        XCTAssertEqual(stub.requests[1].httpMethod, "GET")
        XCTAssertEqual(stub.requests[3].url?.absoluteString, "https://example.com/made.mp4")
    }

    func testVideoGeneratePollsAndFallsBackToContentEndpoint() async throws {
        let stub = AVStubTransport([
            (Data("{\"id\":\"job-2\",\"status\":\"queued\"}".utf8), 202),
            (Data("{\"status\":\"completed\"}".utf8), 200),
            (Data("content-bytes".utf8), 200),
        ])
        let result = try await videoProvider(transport: stub).generate(
            GenerativeMediaRequest(kind: .video, prompt: "海"))
        XCTAssertEqual(try Data(contentsOf: result.fileURL), Data("content-bytes".utf8))
        XCTAssertEqual(stub.requests.last?.url?.absoluteString, "https://example.com/v1/videos/job-2/content")
    }

    func testVideoGenerateJobFailureAndTimeout() async throws {
        let failing = AVStubTransport([
            (Data("{\"id\":\"job-3\",\"status\":\"queued\"}".utf8), 200),
            (Data("{\"status\":\"failed\",\"error\":{\"message\":\"モデルが混んでいます\"}}".utf8), 200),
        ])
        do {
            _ = try await videoProvider(transport: failing).generate(GenerativeMediaRequest(kind: .video, prompt: "海"))
            XCTFail()
        } catch let e as GenerativeMediaError {
            guard case .jobFailed(let detail) = e else { return XCTFail("別のエラー: \(e)") }
            XCTAssertTrue(detail.contains("モデルが混んでいます"))
        }
        let slow = AVStubTransport([
            (Data("{\"id\":\"job-4\",\"status\":\"queued\"}".utf8), 200),
            (Data("{\"status\":\"in_progress\"}".utf8), 200),
            (Data("{\"status\":\"in_progress\"}".utf8), 200),
        ])
        do {
            _ = try await videoProvider(transport: slow, maxPoll: 2).generate(GenerativeMediaRequest(kind: .video, prompt: "海"))
            XCTFail()
        } catch {
            XCTAssertEqual(error as? GenerativeMediaError, .jobTimedOut)
        }
    }

    func testVideoGenerateHTTPErrorAndWrongKind() async throws {
        let stub = AVStubTransport([(Data("bad".utf8), 500)])
        do {
            _ = try await videoProvider(transport: stub).generate(GenerativeMediaRequest(kind: .video, prompt: "海"))
            XCTFail()
        } catch let e as GenerativeMediaError {
            guard case .http(let code, _) = e else { return XCTFail("別のエラー: \(e)") }
            XCTAssertEqual(code, 500)
        }
        do {
            _ = try await videoProvider(transport: AVStubTransport([])).generate(GenerativeMediaRequest(kind: .image, prompt: "海"))
            XCTFail()
        } catch {
            XCTAssertEqual(error as? GenerativeMediaError, .unsupportedKind(.image))
        }
    }

    // MARK: 音声 / 音楽 - リクエストと同期応答

    func testAudioMakeRequestBuildsBody() throws {
        let p = audioProvider(transport: AVStubTransport([]))
        let req = try p.makeRequest(GenerativeMediaRequest(kind: .music, prompt: " 明るい曲 ", targetDuration: 12, outputFormat: "wav"))
        let body = try bodyJSON(req)
        XCTAssertEqual(body["model"] as? String, "audio-model")
        XCTAssertEqual(body["prompt"] as? String, "明るい曲")
        XCTAssertEqual(body["input"] as? String, "明るい曲", "読み上げ系の input にも同じ文を入れる")
        XCTAssertEqual(body["kind"] as? String, "music")
        XCTAssertEqual(body["response_format"] as? String, "wav")
        XCTAssertEqual(body["duration"] as? Double, 12)
    }

    func testAudioGenerateFromRawBytesResponse() async throws {
        let stub = AVStubTransport([(Data("raw-mp3-bytes".utf8), 200)])
        let result = try await audioProvider(transport: stub).generate(
            GenerativeMediaRequest(kind: .audio, prompt: "ドアの音", targetDuration: 2, outputFormat: "mp3"))
        XCTAssertEqual(result.kind, .audio)
        XCTAssertEqual(result.clipType, .audio)
        XCTAssertEqual(result.duration, 2)
        XCTAssertEqual(result.fileURL.pathExtension, "mp3")
        XCTAssertEqual(try Data(contentsOf: result.fileURL), Data("raw-mp3-bytes".utf8))
    }

    func testAudioGenerateFromBase64AndURLResponses() async throws {
        let bytes = Data("music-bytes".utf8)
        let b64 = Data("{\"data\":[{\"b64_json\":\"\(bytes.base64EncodedString())\"}]}".utf8)
        let fromB64 = try await audioProvider(transport: AVStubTransport([(b64, 200)])).generate(
            GenerativeMediaRequest(kind: .music, prompt: "曲"))
        XCTAssertEqual(try Data(contentsOf: fromB64.fileURL), bytes)
        XCTAssertEqual(fromB64.duration, GenerativeMediaKind.music.defaultDuration)

        let stub = AVStubTransport([
            (Data("{\"url\":\"https://example.com/song.mp3\"}".utf8), 200),
            (Data("song-bytes".utf8), 200),
        ])
        let fromURL = try await audioProvider(transport: stub).generate(
            GenerativeMediaRequest(kind: .soundscape, prompt: "雨の音", outputFormat: "mp3"))
        XCTAssertEqual(fromURL.kind, .soundscape)
        XCTAssertEqual(try Data(contentsOf: fromURL.fileURL), Data("song-bytes".utf8))
        XCTAssertEqual(stub.requests.count, 2)
    }

    func testAudioGenerateErrors() async throws {
        do {
            _ = try await audioProvider(transport: AVStubTransport([(Data("{\"foo\":1}".utf8), 200)])).generate(
                GenerativeMediaRequest(kind: .audio, prompt: "音"))
            XCTFail("メディアの無い JSON は解釈不能")
        } catch let e as GenerativeMediaError {
            guard case .unparsable = e else { return XCTFail("別のエラー: \(e)") }
        }
        do {
            _ = try await audioProvider(transport: AVStubTransport([(Data(), 200)])).generate(
                GenerativeMediaRequest(kind: .audio, prompt: "音"))
            XCTFail()
        } catch {
            XCTAssertEqual(error as? GenerativeMediaError, .emptyResponse)
        }
        do {
            _ = try await audioProvider(transport: AVStubTransport([])).generate(
                GenerativeMediaRequest(kind: .video, prompt: "映像"))
            XCTFail()
        } catch {
            XCTAssertEqual(error as? GenerativeMediaError, .unsupportedKind(.video))
        }
    }

    // MARK: 設定(動画 / 音声)

    func testVideoSettingsRoundTripConfiguredAndKeyNotInConfirmation() throws {
        let d = freshDefaults()
        XCTAssertFalse(VideoGenerationSettings.load(from: d).isConfigured)
        XCTAssertThrowsError(try VideoGenerationSettings.load(from: d).makeProvider()) {
            guard case GenerativeMediaError.notConfigured = $0 else { return XCTFail("\($0)") }
        }
        var s = VideoGenerationSettings()
        s.endpoint = "https://example.com/v1/videos"
        s.model = "video-model"
        s.apiKey = "test-sentinel-" + "not-a-real-key"
        s.size = VideoGenerationSize.portrait.rawValue
        s.outputFormat = "mov"
        s.save(to: d)
        let back = VideoGenerationSettings.load(from: d)
        XCTAssertEqual(back, s)
        XCTAssertTrue(back.isConfigured)
        _ = try back.makeProvider()
        let c = back.confirmation(prompt: "海")
        XCTAssertFalse(c.summaryText.contains("test-sentinel-not-a-real-key"))
        XCTAssertFalse(c.destination.contains("test-sentinel-not-a-real-key"))
        XCTAssertTrue(c.summaryText.contains("あなたの API アカウントに課金されます") || c.summaryText.contains("あなたが設定した API アカウントに課金されます"))
        XCTAssertTrue(c.summaryText.contains("MovieCut のサーバは経由しません"))
        XCTAssertTrue(c.summaryText.contains("mov"))
        XCTAssertNotNil(VideoGenerationSettings.endpointProblem("http://example.com/v1/videos"), "http の外部宛ては不可")
    }

    func testAudioSettingsRoundTripAndKindsConfirmation() throws {
        let d = freshDefaults()
        var s = AudioGenerationSettings()
        s.endpoint = "http://127.0.0.1:9000/v1/audio/generations"
        s.model = "local-audio"
        s.outputFormat = "wav"
        s.save(to: d)
        let back = AudioGenerationSettings.load(from: d)
        XCTAssertEqual(back, s)
        XCTAssertTrue(back.isConfigured)
        let provider = try back.makeProvider()
        XCTAssertEqual(provider.supportedKinds, [.audio, .music, .soundscape])
        let c = back.confirmation(kind: .music, prompt: "曲")
        XCTAssertEqual(c.kind, .music)
        XCTAssertTrue(c.summaryText.contains("wav"))
        XCTAssertFalse(AudioGenerationSettings.load(from: freshDefaults()).isConfigured)
    }

    // MARK: 生成延長(計画)

    private func clip(type: ClipType, start: Double = 10, duration: Double = 6) -> Clip {
        var c = Clip()
        c.type = type
        c.start = start
        c.duration = duration
        c.src = "/tmp/source.mp4"
        return c
    }

    func testExtensionPlanForVideoClip() throws {
        let plan = try GenerativeExtensionPlanner.plan(clip: clip(type: .video), headSeconds: 2, tailSeconds: 3)
        XCTAssertEqual(plan.kind, .video)
        XCTAssertEqual(plan.extendedStart, 8)
        XCTAssertEqual(plan.extendedDuration, 11)
        XCTAssertEqual(plan.headSegment, GenerativeExtensionSegment(isHead: true, start: 8, duration: 2))
        XCTAssertEqual(plan.tailSegment, GenerativeExtensionSegment(isHead: false, start: 16, duration: 3))
        XCTAssertTrue(plan.summaryDescription.contains("2"))
        XCTAssertTrue(plan.summaryDescription.contains("3"))
        let reqs = plan.generationRequests(prompt: "続きの映像", outputFormat: "mp4")
        XCTAssertEqual(reqs.count, 2)
        XCTAssertEqual(reqs[0].targetStart, 8)
        XCTAssertEqual(reqs[0].targetDuration, 2)
        XCTAssertEqual(reqs[1].targetStart, 16)
        XCTAssertEqual(reqs[1].kind, .video)
        // 片側だけの計画も作れる
        let tailOnly = try GenerativeExtensionPlanner.plan(clip: clip(type: .audio), headSeconds: 0, tailSeconds: 5)
        XCTAssertEqual(tailOnly.kind, .audio)
        XCTAssertNil(tailOnly.headSegment)
        XCTAssertEqual(tailOnly.generationRequests(prompt: "続き").count, 1)
    }

    func testExtensionPlanRejectsInvalidInputs() {
        XCTAssertTrue(GenerativeExtensionPlanner.supports(clip(type: .video)))
        XCTAssertTrue(GenerativeExtensionPlanner.supports(clip(type: .audio)))
        XCTAssertFalse(GenerativeExtensionPlanner.supports(clip(type: .image)))
        for (head, tail) in [(0.0, 0.0), (-1.0, 2.0), (31.0, 0.0), (0.0, Double.nan)] {
            XCTAssertThrowsError(try GenerativeExtensionPlanner.plan(clip: clip(type: .video), headSeconds: head, tailSeconds: tail)) {
                guard case GenerativeMediaError.invalidExtension = $0 else { return XCTFail("別のエラー: \($0)") }
            }
        }
        // 前の延長が 0 秒より前に出る指定は止める
        XCTAssertThrowsError(try GenerativeExtensionPlanner.plan(clip: clip(type: .video, start: 1), headSeconds: 2, tailSeconds: 0)) {
            guard case GenerativeMediaError.invalidExtension = $0 else { return XCTFail("別のエラー: \($0)") }
        }
        XCTAssertThrowsError(try GenerativeExtensionPlanner.plan(clip: clip(type: .text), headSeconds: 1, tailSeconds: 0)) {
            guard case GenerativeMediaError.invalidExtension = $0 else { return XCTFail("別のエラー: \($0)") }
        }
    }

    func testExtensionPlacementAddsSegmentsAndLeavesOriginalUntouched() throws {
        var project = Project.new()
        let original = clip(type: .video)
        // 元クリップをプロジェクトへ置く(配置の土台として 1 本入れる)
        let placed = GenerativeMediaPlacement.place(
            GenerativeMediaResult(kind: .video, fileURL: URL(fileURLWithPath: "/tmp/source.mp4"), duration: original.duration),
            at: original.start, in: &project)
        XCTAssertEqual(placed.count, 1)
        let plan = try GenerativeExtensionPlanner.plan(clip: original, headSeconds: 2, tailSeconds: 3)
        let head = GenerativeMediaResult(kind: .video, fileURL: URL(fileURLWithPath: "/tmp/gen-head.mp4"), duration: 99)
        let tail = GenerativeMediaResult(kind: .video, fileURL: URL(fileURLWithPath: "/tmp/gen-tail.mp4"), duration: 99)
        let ids = GenerativeExtensionPlacement.place(plan: plan, headResult: head, tailResult: tail, in: &project)
        XCTAssertEqual(ids.count, 2)
        let headClip = try XCTUnwrap(project.allClips.first { $0.id == ids[0] })
        XCTAssertEqual(headClip.start, 8, accuracy: 1e-9)
        XCTAssertEqual(headClip.duration, 2, accuracy: 1e-9, "結果の長さではなく計画の長さで置く")
        XCTAssertEqual(headClip.type, .video)
        let tailClip = try XCTUnwrap(project.allClips.first { $0.id == ids[1] })
        XCTAssertEqual(tailClip.start, 16, accuracy: 1e-9)
        XCTAssertEqual(tailClip.duration, 3, accuracy: 1e-9)
        let orig = try XCTUnwrap(project.allClips.first { $0.id == placed[0] })
        XCTAssertEqual(orig.start, original.start, accuracy: 1e-9, "元クリップは書き換えない")
        XCTAssertEqual(orig.duration, original.duration, accuracy: 1e-9)
    }

    // MARK: 配置(共通口への接続)

    func testGeneratedVideoAndAudioPlaceAsClips() throws {
        var project = Project.new()
        let v = GenerativeMediaPlacement.place(
            GenerativeMediaResult(kind: .video, fileURL: URL(fileURLWithPath: "/tmp/g.mp4"), duration: 7), at: 1, in: &project)
        let a = GenerativeMediaPlacement.place(
            GenerativeMediaResult(kind: .music, fileURL: URL(fileURLWithPath: "/tmp/g.mp3"), duration: 9), at: 2, in: &project)
        XCTAssertEqual(project.allClips.first { $0.id == v[0] }?.type, .video)
        XCTAssertEqual(project.allClips.first { $0.id == a[0] }?.type, .audio)
    }
}
