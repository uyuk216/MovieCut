import XCTest
@testable import MovieCutCore

/// AquesTalk の「話す速さ」を生成音声へ反映する後処理(`VoiceTimeStretch`)のテスト。
/// - 速さ 100・未指定では無変換で、実プレイヤーの参照 WAV とバイト一致すること(互換条件)。
/// - 速さ 130 で内蔵・プラグイン両経路の出力の尺が一致し、100 の約 1/1.3 になること(等価性)。
/// - 速さ 50 / 200 でも尺が期待どおりに変わること。
/// 実プレイヤーが要る確認は既存テストの流儀どおり未インストール時は skip、
/// それ以外は say 代用(プレイヤー不在の指定)で実際に合成して確認する。
final class AquesTalkSpeedTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("aqspeed-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private func freshCache(_ name: String) -> VoiceCache { VoiceCache(directory: tmp.appendingPathComponent(name)) }
    private func builtinSay(cache: VoiceCache) -> AquesTalkSynthesizer { AquesTalkSynthesizer(cache: cache, playerPath: "/nonexistent/aq") }
    private func pluginSay(cache: VoiceCache) -> AquesTalkPluginSynthesizer { AquesTalkPluginSynthesizer(cache: cache, playerPath: "/nonexistent/aq") }

    private func duration(_ url: URL) throws -> Double { try RealVoiceProvider.duration(of: url) }

    // 伸縮が要る速さの判定(100・未指定・不正値は無変換)
    func testNeedsStretch() {
        XCTAssertFalse(VoiceTimeStretch.needsStretch(speed: nil))
        XCTAssertFalse(VoiceTimeStretch.needsStretch(speed: 100))
        XCTAssertFalse(VoiceTimeStretch.needsStretch(speed: 0))
        XCTAssertFalse(VoiceTimeStretch.needsStretch(speed: -130))
        XCTAssertTrue(VoiceTimeStretch.needsStretch(speed: 130))
        XCTAssertTrue(VoiceTimeStretch.needsStretch(speed: 50))
        XCTAssertTrue(VoiceTimeStretch.needsStretch(speed: 200))
        XCTAssertTrue(VoiceTimeStretch.needsStretch(speed: 300))
    }

    // say 代用で実際に合成し、速さが尺に効くこと(内蔵)
    func testSpeedChangesDurationBuiltin() async throws {
        let synth = builtinSay(cache: freshCache("b"))
        let text = "ゆっくりしていってね"
        let d100 = try duration(try await synth.synthesize(text: text, voice: "女声1", speed: 100))
        let d130 = try duration(try await synth.synthesize(text: text, voice: "女声1", speed: 130))
        let d50 = try duration(try await synth.synthesize(text: text, voice: "女声1", speed: 50))
        let d200 = try duration(try await synth.synthesize(text: text, voice: "女声1", speed: 200))
        XCTAssertGreaterThan(d100, 0.5)
        XCTAssertEqual(d130, d100 / 1.3, accuracy: d100 * 0.08, "130% で尺が約 1/1.3")
        XCTAssertEqual(d50, d100 * 2, accuracy: d100 * 0.16, "50% で尺が約 2 倍")
        XCTAssertEqual(d200, d100 / 2, accuracy: d100 * 0.08, "200% で尺が約半分")
    }

    // say 代用で実際に合成し、速さが尺に効くこと(プラグイン)
    func testSpeedChangesDurationPlugin() async throws {
        let synth = pluginSay(cache: freshCache("p"))
        let text = "ゆっくりしていってね"
        let d100 = try duration(try await synth.synthesize(text: text, voice: "女声1", speed: 100))
        let d130 = try duration(try await synth.synthesize(text: text, voice: "女声1", speed: 130))
        let d50 = try duration(try await synth.synthesize(text: text, voice: "女声1", speed: 50))
        let d200 = try duration(try await synth.synthesize(text: text, voice: "女声1", speed: 200))
        XCTAssertGreaterThan(d100, 0.5)
        XCTAssertEqual(d130, d100 / 1.3, accuracy: d100 * 0.08, "130% で尺が約 1/1.3")
        XCTAssertEqual(d50, d100 * 2, accuracy: d100 * 0.16, "50% で尺が約 2 倍")
        XCTAssertEqual(d200, d100 / 2, accuracy: d100 * 0.08, "200% で尺が約半分")
    }

    // 等価性: 速さ 130 で内蔵とプラグインの出力の尺が一致する(別キャッシュでそれぞれ生成)
    func testSpeed130EquivalenceBuiltinVsPlugin() async throws {
        let text = "ゆっくりしていってね"
        let b = builtinSay(cache: freshCache("eb"))
        let p = pluginSay(cache: freshCache("ep"))
        let b100 = try duration(try await b.synthesize(text: text, voice: "女声1", speed: 100))
        let b130 = try duration(try await b.synthesize(text: text, voice: "女声1", speed: 130))
        let p130 = try duration(try await p.synthesize(text: text, voice: "女声1", speed: 130))
        XCTAssertEqual(b130, p130, accuracy: 0.05, "速さ 130 で内蔵とプラグインの尺が一致")
        XCTAssertEqual(p130, b100 / 1.3, accuracy: b100 * 0.08, "プラグインも 100 の約 1/1.3")
    }

    // 互換性: 実プレイヤーで速さ未指定は無変換 = 参照 WAV とバイト一致(内蔵・プラグインとも)
    func testRealPlayerSpeedNilMatchesElectronReference() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: AquesTalkSynthesizer.playerPath), "AquesTalkPlayer 未インストール")
        let ref = try XCTUnwrap(Bundle.module.url(forResource: "aq_reimu", withExtension: "wav", subdirectory: "Fixtures"))
        let expected = try Data(contentsOf: ref)
        let b = AquesTalkSynthesizer(cache: freshCache("rb"))
        let p = AquesTalkPluginSynthesizer(cache: freshCache("rp"))
        let bu = try await b.synthesize(text: "ゆっくりしていってね", voice: "女声1", speed: nil)
        XCTAssertEqual(try Data(contentsOf: bu), expected, "内蔵: 速さ未指定は無変換で参照 WAV とバイト一致")
        let pu = try await p.synthesize(text: "ゆっくりしていってね", voice: "女声1", speed: nil)
        XCTAssertEqual(try Data(contentsOf: pu), expected, "プラグイン: 速さ未指定は無変換で参照 WAV とバイト一致")
    }

    // 実プレイヤー + 速さ 130: 尺が参照の約 1/1.3 になり、内蔵・プラグインで一致する
    func testRealPlayerSpeed130Duration() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: AquesTalkSynthesizer.playerPath), "AquesTalkPlayer 未インストール")
        let ref = try XCTUnwrap(Bundle.module.url(forResource: "aq_reimu", withExtension: "wav", subdirectory: "Fixtures"))
        let refDur = try duration(ref)
        let b = AquesTalkSynthesizer(cache: freshCache("rb130"))
        let p = AquesTalkPluginSynthesizer(cache: freshCache("rp130"))
        let bd = try duration(try await b.synthesize(text: "ゆっくりしていってね", voice: "女声1", speed: 130))
        let pd = try duration(try await p.synthesize(text: "ゆっくりしていってね", voice: "女声1", speed: 130))
        XCTAssertEqual(bd, refDur / 1.3, accuracy: refDur * 0.05, "内蔵: 130% で参照の約 1/1.3")
        XCTAssertEqual(pd, refDur / 1.3, accuracy: refDur * 0.05, "プラグイン: 130% で参照の約 1/1.3")
        XCTAssertEqual(bd, pd, accuracy: 0.02, "内蔵とプラグインの尺が一致")
    }
}
