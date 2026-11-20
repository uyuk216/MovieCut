import XCTest
@testable import MovieCutCore

final class MediaDownloadPolicyTests: XCTestCase {
    private let key = "test-sentinel-" + "not-a-real-key"
    private let endpoint = URL(string: "https://api.example.com/v1/audio/generations")!

    private func tmp() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("mdp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func testAllowedSchemes() {
        XCTAssertTrue(MediaDownloadPolicy.isAllowedDownloadURL(URL(string: "https://cdn.example.com/a.mp3")!))
        XCTAssertTrue(MediaDownloadPolicy.isAllowedDownloadURL(URL(string: "http://127.0.0.1:8080/a.mp3")!))
        XCTAssertTrue(MediaDownloadPolicy.isAllowedDownloadURL(URL(string: "http://localhost/a.mp3")!))
        XCTAssertTrue(MediaDownloadPolicy.isAllowedDownloadURL(URL(string: "http://[::1]:9/a.mp3")!))
        for bad in ["http://example.com/a.mp3", "file:///etc/passwd", "data:audio/mp3;base64,AAAA", "ftp://example.com/a", "javascript:alert(1)"] {
            XCTAssertFalse(MediaDownloadPolicy.isAllowedDownloadURL(URL(string: bad)!), bad)
        }
    }

    func testKeyOnlyForExactOrigin() throws {
        func auth(_ s: String) throws -> String? {
            try MediaDownloadPolicy.downloadRequest(url: URL(string: s)!, endpoint: endpoint, apiKey: key, timeout: 5).value(forHTTPHeaderField: "Authorization")
        }
        XCTAssertEqual(try auth("https://api.example.com/files/1"), "Bearer \(key)")
        XCTAssertEqual(try auth("https://API.example.com:443/files/1"), "Bearer \(key)")
        XCTAssertNil(try auth("https://cdn.example.com/files/1"))
        XCTAssertNil(try auth("https://api.example.com:8443/files/1"))
        let local = URL(string: "http://127.0.0.1:8000/v1/x")!
        let r = try MediaDownloadPolicy.downloadRequest(url: URL(string: "http://127.0.0.1:9000/f")!, endpoint: local, apiKey: key, timeout: 5)
        XCTAssertNil(r.value(forHTTPHeaderField: "Authorization"), "port が違えば付けない")
    }

    func testAudioProviderRejectsFileAndHttpURLAndSendsNothing() async throws {
        for bad in ["file:///etc/passwd", "http://evil.example.com/a.mp3", "data:audio/mpeg;base64,AAAA"] {
            let payload = Data("{\"url\":\"\(bad)\"}".utf8)
            let stub = GenerativeMediaProvidersTests.AVStubTransport([(payload, 200)])
            let p = OpenAICompatibleAudioProvider(endpoint: endpoint, model: "m", apiKey: key, transport: stub, outputDirectory: try tmp())
            do {
                _ = try await p.generate(GenerativeMediaRequest(kind: .audio, prompt: "x"))
                XCTFail("通ってはいけない: \(bad)")
            } catch GenerativeMediaError.downloadRejected {
            }
            XCTAssertEqual(stub.requests.count, 1, "取得の通信は起きない: \(bad)")
        }
    }

    func testAudioProviderDoesNotSendKeyToOtherHost() async throws {
        let payload = Data("{\"url\":\"https://cdn.example.com/a.mp3\"}".utf8)
        let stub = GenerativeMediaProvidersTests.AVStubTransport([(payload, 200), (Data("bytes".utf8), 200)])
        let p = OpenAICompatibleAudioProvider(endpoint: endpoint, model: "m", apiKey: key, transport: stub, outputDirectory: try tmp())
        _ = try await p.generate(GenerativeMediaRequest(kind: .audio, prompt: "x"))
        XCTAssertEqual(stub.requests.count, 2)
        XCTAssertNil(stub.requests[1].value(forHTTPHeaderField: "Authorization"))
    }

    func testImageProviderRejectsFileURL() async throws {
        let payload = Data("{\"data\":[{\"url\":\"file:///etc/passwd\"}]}".utf8)
        let stub = GenerativeMediaProvidersTests.AVStubTransport([(payload, 200)])
        let p = OpenAICompatibleImageProvider(endpoint: endpoint, model: "m", apiKey: key, transport: stub, outputDirectory: try tmp())
        do {
            _ = try await p.generate(GenerativeMediaRequest(kind: .image, prompt: "x"))
            XCTFail()
        } catch GenerativeMediaError.downloadRejected {
        }
        XCTAssertEqual(stub.requests.count, 1)
    }

    func testSizeCap() {
        XCTAssertNoThrow(try MediaDownloadPolicy.checkSize(Data(count: 10)))
        XCTAssertThrowsError(try MediaDownloadPolicy.checkSize(Data(count: MediaDownloadPolicy.maxBytes + 1))) {
            XCTAssertEqual($0 as? GenerativeMediaError, .downloadTooLarge(limit: MediaDownloadPolicy.maxBytes))
        }
    }

    func testEndpointSettingRequiresHTTPSUnlessLoopback() {
        for p in [VideoGenerationSettings.endpointProblem, AudioGenerationSettings.endpointProblem,
                  ImageGenerationSettings.endpointProblem, TextGenerationSettings.endpointProblem] {
            XCTAssertNotNil(p("http://example.com/v1"))
            XCTAssertNotNil(p("file:///etc/passwd"))
            XCTAssertNil(p("https://example.com/v1"))
            XCTAssertNil(p("http://127.0.0.1:8080/v1"))
            XCTAssertNil(p("http://[::1]:8080/v1"))
        }
    }
}
