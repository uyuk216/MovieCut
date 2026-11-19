import XCTest
@testable import MovieCutCore

/// 生成メディア共通連携口: 種類とクリップ種別の対応、依頼の検証、送信前確認の
/// 内容(送信先・プロンプト・費用の注意を含み、キーを含まない)、結果の配置、
/// 偽プロバイダでの生成。実サービスへの通信はしない。
final class GenerativeMediaTests: XCTestCase {

    // MARK: 種類

    func testKindMapsToClipTypeAndDefaultDuration() {
        XCTAssertEqual(GenerativeMediaKind.image.clipType, .image)
        XCTAssertEqual(GenerativeMediaKind.video.clipType, .video)
        XCTAssertEqual(GenerativeMediaKind.audio.clipType, .audio)
        XCTAssertEqual(GenerativeMediaKind.music.clipType, .audio)
        XCTAssertEqual(GenerativeMediaKind.soundscape.clipType, .audio)
        XCTAssertEqual(GenerativeMediaKind.image.defaultDuration, 5)
        XCTAssertEqual(GenerativeMediaKind.allCases.count, 5)
    }

    // MARK: 依頼の検証

    func testRequestValidation() throws {
        try GenerativeMediaRequest(kind: .image, prompt: " 夕焼けの海 ").validate()
        XCTAssertThrowsError(try GenerativeMediaRequest(kind: .image, prompt: "  ").validate()) {
            XCTAssertEqual($0 as? GenerativeMediaError, .emptyPrompt)
        }
        let long = String(repeating: "あ", count: AIImageSettings.maxPromptLength + 1)
        XCTAssertThrowsError(try GenerativeMediaRequest(kind: .video, prompt: long).validate()) {
            XCTAssertEqual($0 as? GenerativeMediaError, .promptTooLong(AIImageSettings.maxPromptLength + 1))
        }
    }

    // MARK: 送信前確認

    func testConfirmationSummaryHasDestinationPromptAndCostNote() {
        let c = GenerativeMediaConfirmation(kind: .image, destination: "https://example.com/v1/images/generations / モデル: m1",
                                            prompt: "夕焼けの海", model: "m1", sizeDescription: "正方形 (1024×1024)")
        XCTAssertTrue(c.summaryText.contains("夕焼けの海"))
        XCTAssertTrue(c.summaryText.contains("m1"))
        XCTAssertTrue(c.summaryText.contains("1024"))
        XCTAssertTrue(c.summaryText.contains("あなたの API アカウントに課金されます") || c.summaryText.contains("あなたが設定した API アカウントに課金されます"))
        XCTAssertTrue(c.summaryText.contains("MovieCut のサーバは経由しません"))
        XCTAssertEqual(c.destination, "https://example.com/v1/images/generations / モデル: m1")
    }

    // MARK: 配置(純粋関数)

    func testPlacementAddsClipAtTimeWithKindClipType() throws {
        var project = Project.new()
        let url = URL(fileURLWithPath: "/tmp/genmedia-test.png")
        let result = GenerativeMediaResult(kind: .image, fileURL: url, duration: 0)
        let ids = GenerativeMediaPlacement.place(result, at: 2, in: &project)
        XCTAssertEqual(ids.count, 1)
        let clip = try XCTUnwrap(project.allClips.first { $0.id == ids[0] })
        XCTAssertEqual(clip.type, .image)
        XCTAssertEqual(clip.start, 2, accuracy: 1e-9)
        XCTAssertEqual(clip.duration, 5, accuracy: 1e-9, "長さ 0 なら種類の既定(画像は 5 秒)")
        XCTAssertEqual(clip.src, url.path)
    }

    func testPlacementUsesExplicitDurationAndClampsNegativeTime() throws {
        var project = Project.new()
        let result = GenerativeMediaResult(kind: .video, fileURL: URL(fileURLWithPath: "/tmp/genmedia-test.mp4"), duration: 3.5)
        let ids = GenerativeMediaPlacement.place(result, at: -1, in: &project)
        let clip = try XCTUnwrap(project.allClips.first { $0.id == ids[0] })
        XCTAssertEqual(clip.type, .video)
        XCTAssertEqual(clip.start, 0, accuracy: 1e-9)
        XCTAssertEqual(clip.duration, 3.5, accuracy: 1e-9)
    }

    // MARK: 偽プロバイダ(共通口)

    func testFakeProviderReturnsResultAndRecordsRequest() async throws {
        let url = URL(fileURLWithPath: "/tmp/genmedia-fake.png")
        let fake = FakeGenerativeMediaProvider(.succeed(url, duration: 4))
        let result = try await fake.generate(GenerativeMediaRequest(kind: .image, prompt: "海", targetStart: 1))
        XCTAssertEqual(result.fileURL, url)
        XCTAssertEqual(result.kind, .image)
        XCTAssertEqual(result.placementDuration, 4)
        XCTAssertEqual(fake.requests.count, 1)
        XCTAssertEqual(fake.requests.first?.prompt, "海")
        XCTAssertTrue(fake.supports(.video))
    }

    func testFakeProviderRejectsUnsupportedKindAndFailurePropagates() async {
        let url = URL(fileURLWithPath: "/tmp/genmedia-fake.png")
        let imageOnly = FakeGenerativeMediaProvider(.succeed(url, duration: 1), supportedKinds: [.image])
        do {
            _ = try await imageOnly.generate(GenerativeMediaRequest(kind: .video, prompt: "海"))
            XCTFail("扱えない種類は失敗する")
        } catch {
            XCTAssertEqual(error as? GenerativeMediaError, .unsupportedKind(.video))
        }
        let failing = FakeGenerativeMediaProvider(.fail(.emptyResponse))
        do {
            _ = try await failing.generate(GenerativeMediaRequest(kind: .image, prompt: "海"))
            XCTFail("失敗が伝わる")
        } catch {
            XCTAssertEqual(error as? GenerativeMediaError, .emptyResponse)
        }
    }
}
