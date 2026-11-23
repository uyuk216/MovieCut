import XCTest
@testable import MovieCutCore

/// 話者分離(W3-27 / 監査 #75): 音響特徴の純粋計算・クラスタリング・ラベルの手動修正・
/// 字幕/台本への反映。方式は音響特徴による簡易判定で、学習型分離ではない(限界は
/// `SpeakerDiarizationInfo.limitationNotice` と docs に明示)。
final class SpeakerDiarizationTests: XCTestCase {
    let sampleRate = 16000.0

    private func sine(freq: Double, seconds: Double, amplitude: Float = 0.5) -> [Float] {
        let n = Int(sampleRate * seconds)
        return (0..<n).map { Float(sin(2 * Double.pi * freq * Double($0) / sampleRate)) * amplitude }
    }

    private func features(_ f0: Double, centroid: Double, zcr: Double = 0.05, rms: Double = 0.3) -> AcousticFeatures {
        AcousticFeatures(meanF0: f0, f0Spread: 10, rms: rms, spectralCentroid: centroid, zeroCrossingRate: zcr, duration: 1)
    }

    // MARK: 特徴の抽出

    func testExtractorFindsPitchOfSines() {
        let low = AcousticFeatureExtractor.features(samples: sine(freq: 120, seconds: 0.5), sampleRate: sampleRate, start: 0, end: 0.5)
        XCTAssertEqual(low.meanF0, 120, accuracy: 15)
        XCTAssertEqual(low.rms, 0.5 / sqrt(2.0), accuracy: 0.03)
        let high = AcousticFeatureExtractor.features(samples: sine(freq: 240, seconds: 0.5), sampleRate: sampleRate, start: 0, end: 0.5)
        XCTAssertEqual(high.meanF0, 240, accuracy: 20)
    }

    func testExtractorSilenceAndRanges() {
        // 非有限・巨大な区間でも整数変換で落ちない(認識結果の時刻がそのまま入る経路がある)
        let infEnd = AcousticFeatureExtractor.features(samples: sine(freq: 120, seconds: 0.5), sampleRate: sampleRate, start: 0, end: .infinity)
        XCTAssertEqual(infEnd.rms, 0, "非有限の区間は無音の特徴として扱う")
        let hugeEnd = AcousticFeatureExtractor.features(samples: sine(freq: 120, seconds: 0.5), sampleRate: sampleRate, start: 0, end: 1e30)
        XCTAssertGreaterThan(hugeEnd.rms, 0, "巨大な終端はバッファの末尾に丸めて測る")
        let nanStart = AcousticFeatureExtractor.features(samples: sine(freq: 120, seconds: 0.5), sampleRate: sampleRate, start: .nan, end: 0.5)
        XCTAssertEqual(nanStart.rms, 0)

        let silent = AcousticFeatureExtractor.features(samples: [Float](repeating: 0, count: 8000), sampleRate: sampleRate, start: 0, end: 0.5)
        XCTAssertEqual(silent.meanF0, 0)
        XCTAssertEqual(silent.rms, 0)
        // 範囲外・空は無音の特徴
        let empty = AcousticFeatureExtractor.features(samples: [], sampleRate: sampleRate, start: 0, end: 1)
        XCTAssertEqual(empty.rms, 0)
        // 後半だけを測る
        var samples = sine(freq: 120, seconds: 0.5)
        samples += sine(freq: 240, seconds: 0.5)
        let second = AcousticFeatureExtractor.features(samples: samples, sampleRate: sampleRate, start: 0.5, end: 1.0)
        XCTAssertEqual(second.meanF0, 240, accuracy: 20)
    }

    func testExtractorSpectralBands() {
        // 低い純音は最下帯域に、高めの純音は 1500〜3000Hz の帯域にエネルギーが寄る
        let low = AcousticFeatureExtractor.features(samples: sine(freq: 120, seconds: 0.5), sampleRate: sampleRate, start: 0, end: 0.5)
        XCTAssertEqual(low.spectralBands.count, 4)
        XCTAssertGreaterThan(low.spectralBands[0], 0.85)
        XCTAssertEqual(low.spectralBands.reduce(0, +), 1.0, accuracy: 0.02)
        let mid = AcousticFeatureExtractor.features(samples: sine(freq: 2000, seconds: 0.5), sampleRate: sampleRate, start: 0, end: 0.5)
        XCTAssertGreaterThan(mid.spectralBands[2], 0.7)
        // 無音は帯域が測れない(空)
        let silent = AcousticFeatureExtractor.features(samples: [Float](repeating: 0, count: 8000), sampleRate: sampleRate, start: 0, end: 0.5)
        XCTAssertTrue(silent.spectralBands.isEmpty)
        XCTAssertTrue(silent.isSilent)
    }

    func testExtractorBandsSeparateSamePitchDifferentTimbre() {
        // 同じ基本周波数(150Hz)でも倍音の配分が違えば帯域配分が大きく違う
        func stack(_ harmonics: [(Double, Float)]) -> [Float] {
            let n = Int(sampleRate * 0.5)
            return (0..<n).map { i in
                harmonics.reduce(Float(0)) { acc, h in acc + Float(sin(2 * Double.pi * h.0 * Double(i) / sampleRate)) * h.1 }
            }
        }
        let dark = AcousticFeatureExtractor.features(samples: stack([(150, 0.6), (300, 0.15), (450, 0.08)]), sampleRate: sampleRate, start: 0, end: 0.5)
        let bright = AcousticFeatureExtractor.features(samples: stack([(150, 0.25), (900, 0.3), (1800, 0.45), (2600, 0.35)]), sampleRate: sampleRate, start: 0, end: 0.5)
        // 自己相関の F0 は倍音の強い合成音ではぶれることがある(既知の弱み)ため、
        // ここでは「2 つの山で推定 F0 が近い(=同程度の声の高さ)」ことだけを見る
        XCTAssertGreaterThan(dark.meanF0, 0)
        XCTAssertGreaterThan(bright.meanF0, 0)
        XCTAssertEqual(dark.meanF0, bright.meanF0, accuracy: 30)
        var sq = 0.0
        for i in dark.spectralBands.indices { let d = dark.spectralBands[i] - bright.spectralBands[i]; sq += d * d }
        XCTAssertGreaterThan(sq.squareRoot(), 0.3, "帯域配分の差が声質の違いを捉える")
    }

    func testExtractorCentroidOrdersByBrightness() {
        let bright = AcousticFeatureExtractor.features(samples: sine(freq: 2000, seconds: 0.5), sampleRate: sampleRate, start: 0, end: 0.5)
        let dark = AcousticFeatureExtractor.features(samples: sine(freq: 200, seconds: 0.5), sampleRate: sampleRate, start: 0, end: 0.5)
        XCTAssertGreaterThan(bright.spectralCentroid, dark.spectralCentroid + 500)
    }

    // MARK: クラスタリング

    func testDistanceIdenticalIsZeroAndFarIsLarge() {
        let a = features(120, centroid: 800)
        XCTAssertEqual(AcousticClusterDiarizer.distance(a, a), 0, accuracy: 1e-9)
        let b = features(240, centroid: 1600)
        XCTAssertGreaterThan(AcousticClusterDiarizer.distance(a, b), DiarizationOptions().threshold)
        let near = features(126, centroid: 830)
        XCTAssertLessThan(AcousticClusterDiarizer.distance(a, near), DiarizationOptions().threshold)
    }

    func testDistanceIgnoresVolumeAndUsesSpreadAndBands() {
        // 音量だけが大きく違う同一話者は近く、抑揚(F0のばらつき)が違う話者は遠い
        let a = features(150, centroid: 950)
        var loud = a; loud.rms = 0.5
        var quiet = a; quiet.rms = 0.04
        XCTAssertLessThan(AcousticClusterDiarizer.distance(loud, quiet), 0.1, "音量差は同一性の差にしない")
        var expressive = a; expressive.f0Spread = 50
        var monotone = a; monotone.f0Spread = 8
        XCTAssertGreaterThan(AcousticClusterDiarizer.distance(expressive, monotone), DiarizationOptions().threshold)
        var bandA = a; bandA.spectralBands = [0.72, 0.18, 0.07, 0.03]
        var bandB = a; bandB.spectralBands = [0.28, 0.34, 0.24, 0.14]
        XCTAssertGreaterThan(AcousticClusterDiarizer.distance(bandA, bandB), DiarizationOptions().threshold,
                             "帯域配分だけが違う声質も分ける")
        var bandA2 = a; bandA2.spectralBands = [0.70, 0.19, 0.08, 0.03]
        XCTAssertLessThan(AcousticClusterDiarizer.distance(bandA, bandA2), DiarizationOptions().threshold)
    }

    func testClusteringGroupsSimilarAndSeparatesDifferent() {
        let segments = (0..<4).map { TranscriptSegment(text: "文\($0)", start: Double($0), end: Double($0) + 1) }
        let feats = [features(120, centroid: 800), features(124, centroid: 820),
                     features(240, centroid: 1500), features(236, centroid: 1480)]
        let out = AcousticClusterDiarizer().diarize(segments: segments, features: feats, options: DiarizationOptions())
        XCTAssertEqual(out.map(\.speaker), [0, 0, 1, 1])
        XCTAssertEqual(out.map(\.speakerLabel), ["話者1", "話者1", "話者2", "話者2"])
    }

    func testClusteringRespectsMaxSpeakers() {
        let segments = (0..<3).map { TranscriptSegment(text: "文\($0)", start: Double($0), end: Double($0) + 1) }
        let feats = [features(100, centroid: 600), features(200, centroid: 1200), features(300, centroid: 2000)]
        let out = AcousticClusterDiarizer().diarize(segments: segments, features: feats, options: DiarizationOptions(maxSpeakers: 1))
        XCTAssertEqual(out.map(\.speaker), [0, 0, 0], "上限 1 なら全員が話者1")
        let out2 = AcousticClusterDiarizer().diarize(segments: segments, features: feats, options: DiarizationOptions(maxSpeakers: 2))
        XCTAssertLessThanOrEqual(SpeakerLabels.speakerCount(out2), 2)
    }

    func testClusteringEmptyAndMissingFeatures() {
        XCTAssertTrue(AcousticClusterDiarizer().diarize(segments: [], features: [], options: DiarizationOptions()).isEmpty)
        let segments = [TranscriptSegment(text: "あ", start: 0, end: 1), TranscriptSegment(text: "い", start: 1, end: 2)]
        let out = AcousticClusterDiarizer().diarize(segments: segments, features: [], options: DiarizationOptions())
        XCTAssertEqual(out.map(\.speaker), [0, 0], "特徴が無ければ直前(話者1)に寄せる")
    }

    func testClusteringFromExtractedAudioFeatures() {
        // 低い声 → 高い声 → 低い声 の合成音声から、特徴抽出込みで 2 話者に分かれる
        var samples = sine(freq: 120, seconds: 0.5)
        samples += sine(freq: 240, seconds: 0.5)
        samples += sine(freq: 122, seconds: 0.5)
        let segments = [TranscriptSegment(text: "あ", start: 0, end: 0.5),
                        TranscriptSegment(text: "い", start: 0.5, end: 1.0),
                        TranscriptSegment(text: "う", start: 1.0, end: 1.5)]
        let feats = segments.map { AcousticFeatureExtractor.features(samples: samples, sampleRate: sampleRate, start: $0.start, end: $0.end) }
        let out = AcousticClusterDiarizer().diarize(segments: segments, features: feats, options: DiarizationOptions())
        XCTAssertEqual(out.map(\.speaker), [0, 1, 0])
    }

    // MARK: ラベルの手動修正

    func testRelabelMergeCompact() {
        let segments = (0..<3).map { TranscriptSegment(text: "文\($0)", start: Double($0), end: Double($0) + 1) }
        var d = segments.enumerated().map { DiarizedSegment(segment: $0.element, speaker: [0, 1, 0][$0.offset]) }
        d = SpeakerLabels.relabeled(d, at: 1, toSpeaker: 0)
        XCTAssertEqual(d.map(\.speaker), [0, 0, 0])
        d = SpeakerLabels.relabeled(d, at: 99, toSpeaker: 1)
        XCTAssertEqual(d.map(\.speaker), [0, 0, 0], "範囲外は何もしない")
        var e = segments.enumerated().map { DiarizedSegment(segment: $0.element, speaker: [2, 0, 2][$0.offset]) }
        e = SpeakerLabels.merged(e, from: 2, into: 0)
        XCTAssertEqual(e.map(\.speaker), [0, 0, 0])
        let f = segments.enumerated().map { DiarizedSegment(segment: $0.element, speaker: [3, 1, 3][$0.offset]) }
        XCTAssertEqual(SpeakerLabels.compacted(f).map(\.speaker), [0, 1, 0], "現れた順に振り直す")
    }

    func testSpeakerPrefixRoundTrip() {
        XCTAssertEqual(DiarizationText.prefixed("こんにちは", speaker: 0), "話者1：こんにちは")
        XCTAssertEqual(DiarizationText.prefixed("話者2：こんにちは", speaker: 0), "話者1：こんにちは", "既存のラベルは付け替える")
        XCTAssertEqual(DiarizationText.stripPrefix("話者12: やあ"), "やあ")
        XCTAssertEqual(DiarizationText.stripPrefix("普通の文"), "普通の文")
        XCTAssertTrue(DiarizationText.hasSpeakerPrefix("話者1：文"))
        XCTAssertFalse(DiarizationText.hasSpeakerPrefix("話者の文"))
    }

    // MARK: 字幕・台本への反映

    func testCuesCarryLabelsAndClipOffset() {
        var clip = Clip()
        clip.type = .audio; clip.start = 10; clip.duration = 3
        let d = [DiarizedSegment(segment: TranscriptSegment(text: "こんにちは", start: 0, end: 1), speaker: 0),
                 DiarizedSegment(segment: TranscriptSegment(text: "やあ", start: 1.5, end: 2.5), speaker: 1),
                 DiarizedSegment(segment: TranscriptSegment(text: "はみ出す", start: 2.9, end: 9), speaker: 1)]
        let cues = DiarizationApply.cues(from: d, clip: clip)
        XCTAssertEqual(cues.map(\.text), ["話者1：こんにちは", "話者2：やあ", "話者2：はみ出す"])
        XCTAssertEqual(cues.map(\.start), [10, 11.5, 12.9])
        XCTAssertEqual(cues.last?.end ?? 0, 13, accuracy: 1e-9, "クリップの終わりで切る")
    }

    func testScriptLines() {
        let d = [DiarizedSegment(segment: TranscriptSegment(text: "こんにちは", start: 0, end: 1), speaker: 0),
                 DiarizedSegment(segment: TranscriptSegment(text: "  ", start: 1, end: 2), speaker: 1),
                 DiarizedSegment(segment: TranscriptSegment(text: "やあ", start: 2, end: 3), speaker: 1)]
        XCTAssertEqual(DiarizationApply.scriptLines(from: d), ["話者1: こんにちは", "話者2: やあ"])
    }

    func testApplyToExistingTextClips() {
        var p = Project.new()
        var t1 = Clip(); t1.type = .text; t1.text = "こんにちは"; t1.start = 5; t1.duration = 1
        var t2 = Clip(); t2.type = .text; t2.text = "関係ない"; t2.start = 6; t2.duration = 1
        var voice = Clip(); voice.type = .voice; voice.text = "こんにちは"; voice.start = 5; voice.duration = 1
        p.tracks[0].clips = [t1, t2, voice]
        let d = [DiarizedSegment(segment: TranscriptSegment(text: "こんにちは", start: 0, end: 1), speaker: 1)]
        let n = DiarizationApply.applyToTextClips(d, clipStart: 5, to: &p)
        XCTAssertEqual(n, 1)
        XCTAssertEqual(p.tracks[0].clips[0].text, "話者2：こんにちは")
        XCTAssertEqual(p.tracks[0].clips[1].text, "関係ない")
        XCTAssertEqual(p.tracks[0].clips[2].text, "こんにちは", "文字クリップ以外は変えない")
        // もう一度当てても二重に付かない
        XCTAssertEqual(DiarizationApply.applyToTextClips(d, clipStart: 5, to: &p), 0)
    }

    // MARK: パイプライン(実音声フィクスチャ + 認識器の偽物)

    final class StubTranscriber: Transcriber, @unchecked Sendable {
        var segments: [TranscriptSegment]
        init(_ segments: [TranscriptSegment]) { self.segments = segments }
        func transcribe(audioURL: URL, duration: Double, onProgress: @escaping @Sendable (Double) -> Void) async throws -> [TranscriptSegment] { segments }
    }

    func testPipelineProducesFeaturesAndLabels() async throws {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "aq_reimu", withExtension: "wav", subdirectory: "Fixtures")
                                    ?? Bundle.module.url(forResource: "aq_reimu", withExtension: "wav"))
        var clip = Clip()
        clip.type = .audio; clip.src = fixture.path; clip.start = 0; clip.duration = 1.5
        let stub = StubTranscriber([
            TranscriptSegment(text: "前半", start: 0, end: 0.7),
            TranscriptSegment(text: "後半", start: 0.8, end: 1.5),
        ])
        let run = try await DiarizationPipeline.run(clip: clip, transcriber: stub)
        XCTAssertEqual(run.segments.count, 2)
        XCTAssertEqual(run.features.count, 2)
        XCTAssertEqual(run.diarized.count, 2)
        XCTAssertTrue(run.features.allSatisfy { $0.duration > 0 })
        XCTAssertTrue(run.diarized.allSatisfy { $0.speaker >= 0 })
    }

    func testLimitationNoticeIsHonest() {
        XCTAssertTrue(SpeakerDiarizationInfo.limitationNotice.contains("簡易判定"))
        XCTAssertTrue(SpeakerDiarizationInfo.limitationNotice.contains("学習型の話者分離ではない"))
    }
}
