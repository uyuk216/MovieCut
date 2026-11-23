import XCTest
@testable import MovieCutCore

/// VOICEVOX モーラタイミング(パーサ・timedFrames・サイドカー・visemes の優先経路)と LipSync のカタカナ対応。
final class VoicevoxMoraTests: XCTestCase {
    var tmp: URL!
    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("vvmora-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    /// accent_phrases 2 つ。1 つ目: こ(k+o) ん(N) + pause。2 つ目: ち(ch+i) っ(cl) ス(無声化 U、子音 s)。
    func fixture(speed: Double? = 1, pre: Double? = 0.1, pauseScale: Double? = 0.5) -> Data {
        var q: [String: Any] = [
            "accent_phrases": [
                ["moras": [
                    ["text": "コ", "consonant": "k", "consonant_length": 0.05, "vowel": "o", "vowel_length": 0.10],
                    ["text": "ン", "consonant": NSNull(), "consonant_length": NSNull(), "vowel": "N", "vowel_length": 0.08],
                ], "pause_mora": ["text": "、", "vowel": "pau", "vowel_length": 0.4]],
                ["moras": [
                    ["text": "チ", "consonant": "ch", "consonant_length": 0.04, "vowel": "i", "vowel_length": 0.06],
                    ["text": "ッ", "consonant": NSNull(), "vowel": "cl", "vowel_length": 0.1],
                    ["text": "ス", "consonant": "s", "consonant_length": 0.05, "vowel": "U", "vowel_length": 0.05],
                ]],
            ] as [[String: Any]],
            "postPhonemeLength": 0.5,
        ]
        if let s = speed { q["speedScale"] = s }
        if let p = pre { q["prePhonemeLength"] = p }
        if let p = pauseScale { q["pauseLengthScale"] = p }
        return try! JSONSerialization.data(withJSONObject: q)
    }

    func testParserVowelsAndTimes() {
        let segs = VoicevoxMora.parse(fixture())
        XCTAssertEqual(segs.map(\.vowel), [.o, .closed, .closed, .i, .closed, .u])
        let lens = [0.15, 0.08, 0.2, 0.10, 0.1, 0.10]
        var t = 0.1
        for (s, l) in zip(segs, lens) {
            XCTAssertEqual(s.start, t, accuracy: 1e-9)
            XCTAssertEqual(s.end, t + l, accuracy: 1e-9)
            t += l
        }
    }

    func testParserSpeedPreAndPauseScale() {
        let fast = VoicevoxMora.parse(fixture(speed: 2, pre: 0.2, pauseScale: 1))
        // 先頭の無音も話速で割られる(エンジンは前後無音を足してから speedScale を掛ける)。
        XCTAssertEqual(fast[0].start, 0.1, accuracy: 1e-9)               // 0.2 / 2
        XCTAssertEqual(fast[0].end, 0.1 + 0.075, accuracy: 1e-9)          // 0.15 / 2
        XCTAssertEqual(fast[2].end - fast[2].start, 0.4 / 2, accuracy: 1e-9) // pause 1.0 倍 / 速度 2
        // speedScale が 0 以下・欠落は 1
        let zero = VoicevoxMora.parse(fixture(speed: 0))
        let missing = VoicevoxMora.parse(fixture(speed: nil))
        XCTAssertEqual(zero, VoicevoxMora.parse(fixture(speed: 1)))
        XCTAssertEqual(missing, zero)
        // pre 欠落は 0 始まり
        XCTAssertEqual(VoicevoxMora.parse(fixture(pre: nil))[0].start, 0, accuracy: 1e-9)
    }

    /// 疑問形の語尾上げ: is_interrogative かつ末尾モーラが有声(pitch > 0)なら、同じ母音の 0.15 秒が末尾に付く。
    func testParserInterrogativeUpspeak() {
        func q(interrogative: Bool, pitch: Double, speed: Double = 1) -> Data {
            let query: [String: Any] = [
                "accent_phrases": [
                    ["moras": [
                        ["text": "カ", "consonant": "k", "consonant_length": 0.05, "vowel": "a", "vowel_length": 0.10, "pitch": pitch],
                    ], "is_interrogative": interrogative],
                ] as [[String: Any]],
                "speedScale": speed,
                "prePhonemeLength": 0,
            ]
            return try! JSONSerialization.data(withJSONObject: query)
        }
        // 有声の疑問形: 本体 0.15 + 語尾上げ 0.15 = 2 区間とも母音 a
        let up = VoicevoxMora.parse(q(interrogative: true, pitch: 5.0))
        XCTAssertEqual(up.count, 2)
        XCTAssertEqual(up[1].vowel, .a)
        XCTAssertEqual(up[1].start, 0.15, accuracy: 1e-9)
        XCTAssertEqual(up[1].end, 0.30, accuracy: 1e-9)
        // 話速 2 では語尾上げも半分になる
        let upFast = VoicevoxMora.parse(q(interrogative: true, pitch: 5.0, speed: 2))
        XCTAssertEqual(upFast.count, 2)
        XCTAssertEqual(upFast[1].end - upFast[1].start, 0.075, accuracy: 1e-9)
        // 無声(pitch 0)・疑問形でない場合は付かない
        XCTAssertEqual(VoicevoxMora.parse(q(interrogative: true, pitch: 0)).count, 1)
        XCTAssertEqual(VoicevoxMora.parse(q(interrogative: false, pitch: 5.0)).count, 1)
    }

    func testParserBrokenIsEmpty() {
        XCTAssertTrue(VoicevoxMora.parse(Data("not json".utf8)).isEmpty)
        XCTAssertTrue(VoicevoxMora.parse(Data("[1,2]".utf8)).isEmpty)
        XCTAssertTrue(VoicevoxMora.parse(Data("{\"accent_phrases\":[]}".utf8)).isEmpty)
        XCTAssertTrue(VoicevoxMora.parse(Data()).isEmpty)
    }

    func testTimedFrames() {
        let segs = [TimedViseme(vowel: .a, start: 0.1, end: 0.2), TimedViseme(vowel: .i, start: 0.2, end: 0.3)]
        let f = LipSync.timedFrames(segments: segs, frameCount: 24)
        XCTAssertEqual(f.count, 24)
        // 1/60 秒コマ: コマ k の中央 = (k+0.5)/60。0.1 秒 = コマ 6 の開始(中央 0.1083)、0.2 秒 = コマ 12 の開始
        XCTAssertEqual(f[5], .closed)   // 中央 0.0917 < 0.1
        XCTAssertEqual(f[6], .a)
        XCTAssertEqual(f[11], .a)       // 中央 0.1917 < 0.2
        XCTAssertEqual(f[12], .i)
        XCTAssertEqual(f[17], .i)
        XCTAssertEqual(f[18], .closed)  // 中央 0.3083 >= 0.3
        XCTAssertEqual(f[0], .closed)
        // 空区間・空配列・区間がコマ数の外
        XCTAssertEqual(LipSync.timedFrames(segments: [], frameCount: 5), [Viseme](repeating: .closed, count: 5))
        XCTAssertEqual(LipSync.timedFrames(segments: [TimedViseme(vowel: .u, start: 0.1, end: 0.1)], frameCount: 24), [Viseme](repeating: .closed, count: 24))
        XCTAssertEqual(LipSync.timedFrames(segments: [TimedViseme(vowel: .u, start: 5, end: 6)], frameCount: 24), [Viseme](repeating: .closed, count: 24))
        XCTAssertTrue(LipSync.timedFrames(segments: segs, frameCount: 0).isEmpty)
        // コマ数を超える区間は切り詰める
        XCTAssertEqual(LipSync.timedFrames(segments: [TimedViseme(vowel: .e, start: 0, end: 10)], frameCount: 3), [.e, .e, .e])
    }

    func testSidecarRoundTrip() throws {
        let segs = VoicevoxMora.parse(fixture())
        let data = try XCTUnwrap(VoicevoxMora.encodeSidecar(segs))
        let back = try XCTUnwrap(VoicevoxMora.decodeSidecar(data))
        XCTAssertEqual(back.map(\.vowel), segs.map(\.vowel))
        for (a, b) in zip(back, segs) {
            XCTAssertEqual(a.start, b.start, accuracy: 1e-12)
            XCTAssertEqual(a.end, b.end, accuracy: 1e-12)
        }
        XCTAssertEqual(VoicevoxMora.sidecarURL(forWav: "/x/a.wav").path, "/x/a.wav.visemes.json")
        // 壊れている・版違い・空は nil
        XCTAssertNil(VoicevoxMora.decodeSidecar(Data("xx".utf8)))
        XCTAssertNil(VoicevoxMora.decodeSidecar(Data("{\"version\":2,\"segments\":[{\"v\":\"a\",\"s\":0,\"e\":1}]}".utf8)))
        XCTAssertNil(VoicevoxMora.decodeSidecar(Data("{\"version\":1,\"segments\":[]}".utf8)))
        XCTAssertNil(VoicevoxMora.decodeSidecar(Data("{\"version\":1,\"segments\":[{\"v\":\"zz\",\"s\":0,\"e\":1}]}".utf8)))
    }

    func testVisemesPrefersSidecarAndFallsBack() throws {
        let wav = tmp.appendingPathComponent("v.wav")
        try AudioFixture.writeSine(wav, segments: [(1, 0.3)])
        let text = "あいうえお"
        let assets = RenderAssets()
        let before = try XCTUnwrap(assets.visemes(src: wav.path, text: text, offset: 0, duration: 1))
        // サイドカー無し = 従来のエンベロープ比例と同じ
        let env = try XCTUnwrap(assets.mouthEnvelope(for: wav.path))
        let legacy = LipSync.frames(moras: LipSync.moras(of: text), envelope: env, range: 0..<Int(ceil(1 * 60.0)))
        XCTAssertEqual(before, legacy)

        // サイドカーを置くと(新しい RenderAssets でも同じ RenderAssets でも)優先される
        let segs = [TimedViseme(vowel: .u, start: 0.5, end: 0.6)]
        try XCTUnwrap(VoicevoxMora.encodeSidecar(segs)).write(to: VoicevoxMora.sidecarURL(forWav: wav.path))
        let after = try XCTUnwrap(assets.visemes(src: wav.path, text: text, offset: 0, duration: 1))
        XCTAssertEqual(after.count, env.count)
        XCTAssertEqual(after, LipSync.timedFrames(segments: segs, frameCount: env.count))
        XCTAssertEqual(after[33], .u)
        XCTAssertEqual(after[10], .closed)

        // 範囲(offset/duration)の外は閉じ
        let ranged = try XCTUnwrap(RenderAssets().visemes(src: wav.path, text: text, offset: 0, duration: 0.55))
        XCTAssertEqual(ranged.count, env.count)
        XCTAssertEqual(ranged[31], .u)
        XCTAssertEqual(ranged[35], .closed)

        // 壊れたサイドカーは従来と同じ
        try Data("broken".utf8).write(to: VoicevoxMora.sidecarURL(forWav: wav.path))
        XCTAssertEqual(RenderAssets().visemes(src: wav.path, text: text, offset: 0, duration: 1), legacy)
    }

    // MARK: 壊れたサイドカー(レビューブロッカー修正の回帰)

    func testDecodeSidecarRejectsMalformedTimelines() {
        func dec(_ json: String) -> [TimedViseme]? { VoicevoxMora.decodeSidecar(Data(json.utf8)) }
        // 巨大だが有限な値(従来は timedFrames の Int 変換でトラップした)
        XCTAssertNil(dec("{\"version\":1,\"segments\":[{\"v\":\"a\",\"s\":0,\"e\":1e100}]}"))
        // 負・逆転・重なり・開始順でない・上限超え
        XCTAssertNil(dec("{\"version\":1,\"segments\":[{\"v\":\"a\",\"s\":-0.1,\"e\":1}]}"))
        XCTAssertNil(dec("{\"version\":1,\"segments\":[{\"v\":\"a\",\"s\":1,\"e\":0.5}]}"))
        XCTAssertNil(dec("{\"version\":1,\"segments\":[{\"v\":\"a\",\"s\":0,\"e\":1},{\"v\":\"i\",\"s\":0.5,\"e\":1.5}]}"))
        XCTAssertNil(dec("{\"version\":1,\"segments\":[{\"v\":\"a\",\"s\":1,\"e\":2},{\"v\":\"i\",\"s\":0,\"e\":0.5}]}"))
        XCTAssertNil(dec("{\"version\":1,\"segments\":[{\"v\":\"a\",\"s\":0,\"e\":86401}]}"))
        // 版は整数の 1 ちょうどのみ(1.5 / true を 1 とみなさない)
        XCTAssertNil(dec("{\"version\":1.5,\"segments\":[{\"v\":\"a\",\"s\":0,\"e\":1}]}"))
        XCTAssertNil(dec("{\"version\":true,\"segments\":[{\"v\":\"a\",\"s\":0,\"e\":1}]}"))
        // 接触する区間(end == 次の start)と長さ 0 は正常
        XCTAssertNotNil(dec("{\"version\":1,\"segments\":[{\"v\":\"a\",\"s\":0,\"e\":1},{\"v\":\"i\",\"s\":1,\"e\":1},{\"v\":\"u\",\"s\":1,\"e\":2}]}"))
    }

    func testTimedFramesWithHugeValuesDoNotCrash() {
        let huge = LipSync.timedFrames(segments: [TimedViseme(vowel: .a, start: 0, end: 1e100)], frameCount: 24)
        XCTAssertEqual(huge, [Viseme](repeating: .a, count: 24), "巨大な終端は全コマ分へクランプ")
        let beyond = LipSync.timedFrames(segments: [TimedViseme(vowel: .a, start: 1e100, end: 2e100)], frameCount: 24)
        XCTAssertEqual(beyond, [Viseme](repeating: .closed, count: 24))
        let weird = LipSync.timedFrames(segments: [
            TimedViseme(vowel: .a, start: .nan, end: 1),
            TimedViseme(vowel: .i, start: 0, end: .infinity),
            TimedViseme(vowel: .u, start: -1e100, end: -1),
            TimedViseme(vowel: .e, start: -5, end: 0.1),
        ], frameCount: 12)
        XCTAssertEqual(weird.count, 12)
        XCTAssertEqual(weird[0], .e, "負の開始は 0 にクランプされる")
        XCTAssertEqual(weird[11], .closed, "非有限の区間は効かない")
    }

    func testVisemesFallsBackWithMalformedSidecarFile() throws {
        let wav = tmp.appendingPathComponent("v2.wav")
        try AudioFixture.writeSine(wav, segments: [(1, 0.3)])
        let text = "あいうえお"
        let env = try XCTUnwrap(RenderAssets().mouthEnvelope(for: wav.path))
        let legacy = LipSync.frames(moras: LipSync.moras(of: text), envelope: env, range: 0..<Int(ceil(1 * 60.0)))
        for bad in ["{\"version\":1,\"segments\":[{\"v\":\"a\",\"s\":0,\"e\":1e100}]}",
                    "{\"version\":1,\"segments\":[{\"v\":\"a\",\"s\":1,\"e\":0.5}]}"] {
            try Data(bad.utf8).write(to: VoicevoxMora.sidecarURL(forWav: wav.path))
            XCTAssertEqual(RenderAssets().visemes(src: wav.path, text: text, offset: 0, duration: 1), legacy, "壊れたサイドカーは従来のエンベロープ比例に戻る")
        }
    }

    // MARK: LipSync カタカナ

    func testKatakanaMatchesHiragana() {
        let pairs = [("コンニチハ", "こんにちは"), ("キャット", "きゃっと"), ("シュークリーム", "しゅーくりーむ"),
                     ("ファイト", "ふぁいと"), ("ヴァイオリン", "ゔぁいおりん"), ("ティー", "てぃー")]
        for (k, h) in pairs {
            XCTAssertEqual(LipSync.moras(ofHiragana: k), LipSync.moras(ofHiragana: h), k)
            XCTAssertFalse(LipSync.moras(ofHiragana: k).isEmpty, k)
        }
        XCTAssertEqual(LipSync.moras(ofHiragana: "コンニチハ"), [.o, .closed, .i, .i, .a])
    }

    func testHiraganaMorasUnchanged() {
        XCTAssertEqual(LipSync.moras(ofHiragana: "こんにちは"), [.o, .closed, .i, .i, .a])
        XCTAssertEqual(LipSync.moras(ofHiragana: "きゃっと"), [.a, .closed, .o])
        XCTAssertEqual(LipSync.moras(ofHiragana: "おかあさーん"), [.o, .a, .a, .a, .a])  // 末尾の ん は除かれる
        XCTAssertEqual(LipSync.moras(ofHiragana: "、あ。"), [.a])
    }
}
