import XCTest
@testable import MovieCutCore

/// AIラフカット(第 1 版): プロンプト・読み取り・検証・組み立て・汎用クライアント
/// (通信は差し替え)・モック。実サービスへの通信はしない(認証情報も扱わない)。
final class RoughCutTests: XCTestCase {

    // MARK: 部品

    private func sourceClip(id: String = "c1", window: (Double, Double) = (10, 70), track: Int = 0) -> RoughCutSourceClip {
        RoughCutSourceClip(clipId: id, label: "素材\(id).mp4", trackIndex: track,
                           windowStart: window.0, windowEnd: window.1,
                           segments: [TranscriptSegment(text: "こんにちは", start: 12, end: 15),
                                      TranscriptSegment(text: "面白い話", start: 30, end: 40)])
    }

    private func project() -> Project {
        var p = Project.new()
        p.tracks = [Track(name: "映像"), Track(name: "音声")]
        var v = Clip(); v.id = "v1"; v.type = .video; v.src = "/tmp/a.mp4"; v.start = 0; v.duration = 60; v.offset = 10
        var a = Clip(); a.id = "a1"; a.type = .audio; a.src = "/tmp/b.wav"; a.start = 0; a.duration = 30; a.offset = 0
        p.tracks[0].clips = [v]
        p.tracks[1].clips = [a]
        return p
    }

    private struct StubTransport: TextGenerationTransport {
        let data: Data
        let status: Int
        func send(_ request: URLRequest) async throws -> (Data, Int) { (data, status) }
    }

    private func chatJSON(_ content: String) -> Data {
        let obj: [String: Any] = ["choices": [["message": ["role": "assistant", "content": content]]]]
        return try! JSONSerialization.data(withJSONObject: obj)
    }

    // MARK: プロンプト

    func testPromptContainsInstructionTargetClipsAndTranscript() {
        let r = RoughCutRequest(instruction: "面白いところだけ", targetDuration: 30, clips: [sourceClip()])
        let built = RoughCutPrompt.build(r)
        XCTAssertFalse(built.truncated)
        XCTAssertTrue(built.prompt.contains("面白いところだけ"))
        XCTAssertTrue(built.prompt.contains("約 30.0 秒"))
        XCTAssertTrue(built.prompt.contains("[clip: c1]"))
        XCTAssertTrue(built.prompt.contains("使える範囲: 10.0〜70.0 秒"))
        XCTAssertTrue(built.prompt.contains("[12.0-15.0] こんにちは"))
        XCTAssertTrue(built.prompt.contains("JSON だけ"))
    }

    func testPromptTruncatesLongTranscript() {
        let many = (0..<2000).map { TranscriptSegment(text: "これは長い文字起こしの文です\($0)", start: Double($0) * 3, end: Double($0) * 3 + 2) }
        let c = RoughCutSourceClip(clipId: "big", label: "big.mp4", trackIndex: 0, windowStart: 0, windowEnd: 6000, segments: many)
        let built = RoughCutPrompt.build(RoughCutRequest(instruction: "x", clips: [c]))
        XCTAssertTrue(built.truncated)
        XCTAssertLessThanOrEqual(built.prompt.count, RoughCutPrompt.maxInputCharacters + 1500)
    }

    // MARK: 読み取り

    func testParsePlainJSON() throws {
        let text = #"{"summary": "要約です", "segments": [{"clip": "c1", "start": 12, "end": 15.5, "title": "つかみ"}, {"clip": "c1", "start": 30, "end": 40}]}"#
        let got = try RoughCutPrompt.parse(text)
        XCTAssertEqual(got.summary, "要約です")
        XCTAssertEqual(got.segments, [
            RoughCutSegment(clipId: "c1", start: 12, end: 15.5, title: "つかみ"),
            RoughCutSegment(clipId: "c1", start: 30, end: 40, title: nil),
        ])
    }

    func testParseFencesProseAndStringNumbers() throws {
        let text = """
        もちろんです。プランはこちらです。
        ```json
        {"segments": [{"clip": "c1", "start": "12.5", "end": "20"}]}
        ```
        以上です。
        """
        let got = try RoughCutPrompt.parse(text)
        XCTAssertEqual(got.segments, [RoughCutSegment(clipId: "c1", start: 12.5, end: 20, title: nil)])
        XCTAssertNil(got.summary)
    }

    func testParseSkipsBrokenEntries() throws {
        let text = #"{"segments": [{"clip": "c1", "start": 1, "end": 2}, {"start": 3, "end": 4}, {"clip": "c1", "start": "x", "end": 9}, {"clip": "c1", "start": 5, "end": 8}]}"#
        let got = try RoughCutPrompt.parse(text)
        XCTAssertEqual(got.segments.map(\.start), [1, 5])
    }

    func testParseGarbageThrows() {
        for bad in ["", "すみません、できません。", "{}", #"{"segments": []}"#, #"{"segments": [{"start": 1}]}"#] {
            XCTAssertThrowsError(try RoughCutPrompt.parse(bad), bad) {
                guard case RoughCutError.unparsable = $0 else { return XCTFail("\($0)") }
            }
        }
    }

    // MARK: 検証

    func testValidationClampsToWindow() {
        let v = RoughCutValidation.validate([RoughCutSegment(clipId: "c1", start: 0, end: 100)], clips: [sourceClip()])
        XCTAssertEqual(v.kept, [RoughCutSegment(clipId: "c1", start: 10, end: 70)])
        XCTAssertEqual(v.dropped, 0)
    }

    func testValidationDropsShortUnknownAndOverlapping() {
        let segs = [
            RoughCutSegment(clipId: "c1", start: 12, end: 20),     // 残る
            RoughCutSegment(clipId: "c1", start: 15, end: 25),     // 重なりで落ちる
            RoughCutSegment(clipId: "c1", start: 30, end: 30.3),   // 短くて落ちる
            RoughCutSegment(clipId: "ghost", start: 0, end: 10),   // 知らないクリップで落ちる
            RoughCutSegment(clipId: "c1", start: 65, end: 90),     // 丸めて残る(65〜70)
            RoughCutSegment(clipId: "c1", start: 200, end: 300),   // 範囲外で丸めたら長さ 0 → 落ちる
        ]
        let v = RoughCutValidation.validate(segs, clips: [sourceClip()])
        XCTAssertEqual(v.kept, [
            RoughCutSegment(clipId: "c1", start: 12, end: 20),
            RoughCutSegment(clipId: "c1", start: 65, end: 70),
        ])
        XCTAssertEqual(v.dropped, 4)
    }

    func testPlanningEmptyAfterValidationThrows() {
        XCTAssertThrowsError(try RoughCutPlanning.plan(fromResponse: #"{"segments": [{"clip": "ghost", "start": 0, "end": 10}]}"#, clips: [sourceClip()])) {
            guard case RoughCutError.emptyPlan(let dropped) = $0 else { return XCTFail("\($0)") }
            XCTAssertEqual(dropped, 1)
        }
    }

    // MARK: プロバイダ(通信は差し替え)

    func testProviderRoundTripWithStubTransport() async throws {
        let content = #"{"summary": "s", "segments": [{"clip": "c1", "start": 12, "end": 20}, {"clip": "c1", "start": 18, "end": 30}]}"#
        let provider = OpenAICompatibleRoughCutProvider(endpoint: URL(string: "https://example.com/v1/chat/completions")!,
                                                        model: "m", transport: StubTransport(data: chatJSON(content), status: 200))
        let plan = try await provider.generateRoughCut(RoughCutRequest(instruction: "短く", clips: [sourceClip()]))
        XCTAssertEqual(plan.segments, [RoughCutSegment(clipId: "c1", start: 12, end: 20)])
        XCTAssertEqual(plan.droppedCount, 1, "重なった 2 件目が落ちたことを数える")
        XCTAssertEqual(plan.summary, "s")
        XCTAssertEqual(plan.totalDuration, 8)
    }

    func testProviderHTTPError() async {
        let provider = OpenAICompatibleRoughCutProvider(endpoint: URL(string: "https://example.com/v1")!, model: "m",
                                                        transport: StubTransport(data: Data("bad".utf8), status: 500))
        do {
            _ = try await provider.generateRoughCut(RoughCutRequest(instruction: "x", clips: [sourceClip()]))
            XCTFail("失敗するはず")
        } catch let e as TextGenerationError {
            guard case .http(500, _) = e else { return XCTFail("\(e)") }
        } catch { XCTFail("\(error)") }
    }

    func testProviderNoSourcesThrows() async {
        let provider = OpenAICompatibleRoughCutProvider(endpoint: URL(string: "https://example.com/v1")!, model: "m",
                                                        transport: StubTransport(data: Data(), status: 200))
        do {
            _ = try await provider.generateRoughCut(RoughCutRequest(instruction: "x", clips: []))
            XCTFail("失敗するはず")
        } catch let e as RoughCutError {
            XCTAssertEqual(e, .noSources)
        } catch { XCTFail("\(error)") }
    }

    func testUnconfiguredSettingsThrowNotConfigured() {
        let s = TextGenerationSettings()
        XCTAssertThrowsError(try s.makeRoughCutProvider()) {
            guard case TextGenerationError.notConfigured = $0 else { return XCTFail("\($0)") }
        }
    }

    func testFakeProviderRawGoesThroughParseAndValidation() async throws {
        let fake = FakeRoughCutProvider(.raw(#"{"segments": [{"clip": "c1", "start": 12, "end": 20}]}"#))
        let req = RoughCutRequest(instruction: "短く", targetDuration: 10, clips: [sourceClip()])
        let plan = try await fake.generateRoughCut(req)
        XCTAssertEqual(plan.segments.count, 1)
        XCTAssertEqual(fake.requests, [req])
    }

    // MARK: 対象の収集

    func testCollectEligibleClipsWithTranscripts() {
        let p = project()
        let transcripts: [String: [TranscriptSegment]] = [
            "v1": [TranscriptSegment(text: "範囲外", start: 0, end: 5),
                   TranscriptSegment(text: "中身", start: 20, end: 25),
                   TranscriptSegment(text: "末尾", start: 65, end: 75)],
            "a1": [TranscriptSegment(text: "音声", start: 1, end: 4)],
        ]
        let got = RoughCutSources.collect(project: p, transcripts: { transcripts[$0.id] })
        XCTAssertEqual(got.map(\.clipId), ["v1", "a1"])
        XCTAssertEqual(got[0].trackIndex, 0)
        XCTAssertEqual(got[0].windowStart, 10)
        XCTAssertEqual(got[0].windowEnd, 70)
        XCTAssertEqual(got[0].segments.map(\.text), ["中身", "末尾"], "窓と重なる文だけ(部分的に重なる末尾も含む)")
        XCTAssertEqual(got[0].label, "a.mp4")
        XCTAssertEqual(got[1].trackIndex, 1)
    }

    func testCollectSkipsIneligibleAndUntranscribed() {
        var p = project()
        var text = Clip(); text.id = "t1"; text.type = .text; text.start = 0; text.duration = 5
        var fast = Clip(); fast.id = "f1"; fast.type = .video; fast.src = "/tmp/c.mp4"; fast.start = 0; fast.duration = 10; fast.speed = 2
        p.tracks[0].clips += [text, fast]
        let got = RoughCutSources.collect(project: p, transcripts: { $0.id == "a1" ? nil : [TranscriptSegment(text: "x", start: 20, end: 25)] })
        XCTAssertEqual(got.map(\.clipId), ["v1"], "テキスト・速度つき・文字起こし無しは対象外")
    }

    // MARK: 組み立て

    func testBuilderMakesSceneMirroringTracks() {
        let p = project()
        let plan = RoughCutPlan(segments: [
            RoughCutSegment(clipId: "v1", start: 20, end: 30, title: "本編"),
            RoughCutSegment(clipId: "a1", start: 5, end: 8),
            RoughCutSegment(clipId: "v1", start: 40, end: 45),
        ])
        let scene = RoughCutBuilder.makeScene(plan: plan, in: p, name: "AIラフカット")
        let s = try! XCTUnwrap(scene)
        XCTAssertEqual(s.name, "AIラフカット")
        XCTAssertEqual(s.tracks.map(\.name), ["映像", "音声"])
        let vClips = s.tracks[0].clips
        XCTAssertEqual(vClips.count, 2)
        XCTAssertEqual(vClips[0].offset, 20); XCTAssertEqual(vClips[0].duration, 10); XCTAssertEqual(vClips[0].start, 0)
        XCTAssertEqual(vClips[1].offset, 40); XCTAssertEqual(vClips[1].duration, 5); XCTAssertEqual(vClips[1].start, 10)
        XCTAssertEqual(s.tracks[1].clips.count, 1)
        XCTAssertEqual(s.tracks[1].clips[0].offset, 5); XCTAssertEqual(s.tracks[1].clips[0].duration, 3)
        XCTAssertNotEqual(vClips[0].id, "v1", "複製は新しい ID")
        XCTAssertEqual(p.scenes.count, 0, "プロジェクト自体は変えない")
        XCTAssertEqual(p.tracks[0].clips[0].offset, 10, "元のクリップは変えない")
    }

    func testBuilderDropsKeyframesAndTransitions() {
        var p = project()
        p.tracks[0].clips[0].keyframes = ["x": [Keyframe(t: 1, v: 0.5)]]
        let plan = RoughCutPlan(segments: [RoughCutSegment(clipId: "v1", start: 20, end: 30)])
        let s = RoughCutBuilder.makeScene(plan: plan, in: p, name: "x")
        XCTAssertTrue(s!.tracks[0].clips[0].keyframes.isEmpty)
    }

    func testBuilderEmptyPlanReturnsNil() {
        XCTAssertNil(RoughCutBuilder.makeScene(plan: RoughCutPlan(segments: []), in: project(), name: "x"))
        XCTAssertNil(RoughCutBuilder.makeScene(plan: RoughCutPlan(segments: [RoughCutSegment(clipId: "ghost", start: 0, end: 5)]), in: project(), name: "x"))
    }
}
