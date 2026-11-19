import XCTest
import AVFoundation
@testable import MovieCutCore

/// Whisper の精度まわり: デコード設定と VAD の引数、既定の言語 auto、日英混在の保持、前処理(正規化・ノイズ除去)、モデルのカタログ。
/// 実物の whisper-cli は使わず、偽の実行ファイル(シェルスクリプト)と合成の WAV で確かめる。
final class WhisperAccuracyTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("whisper-accuracy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    // MARK: helpers

    private func makeScript(body: String) throws -> String {
        let url = tmp.appendingPathComponent("whisper-cli")
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    private func makeModel(_ name: String = "ggml-base.bin") throws -> String {
        let url = tmp.appendingPathComponent(name)
        try Data([0]).write(to: url)
        return url.path
    }

    /// 引数を記録し、`-of` の値 + ".json" に固定の JSON を書く偽スクリプト。
    private func recordingBody(record: String, jsonText: String) -> String {
        """
        out=""
        : > "\(record)"
        while [ $# -gt 0 ]; do
          case "$1" in
            -m|-f|-l|-of) echo "$1=$2" >> "\(record)"; [ "$1" = "-of" ] && out="$2"; shift 2;;
            *) shift;;
          esac
        done
        cat > "$out.json" <<'JSONEOF'
        \(jsonText)
        JSONEOF
        """
    }

    /// 16kHz モノラルの WAV を書く(float の配列 → 16bit)。
    private func writeWAV16k(_ samples: [Float], to url: URL) throws {
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000.0, AVNumberOfChannelsKey: 1,
                                       AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        let f = try AVAudioFile(forWriting: url, settings: settings)
        let fmt = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let buf = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(samples.count)))
        buf.frameLength = AVAudioFrameCount(samples.count)
        let data = try XCTUnwrap(buf.floatChannelData)
        for (i, v) in samples.enumerated() { data[0][i] = v }
        try f.write(from: buf)
    }

    /// WAV を読んで(フレーム数, 先頭チャンネルのピーク, サンプルレート)を返す。
    private func inspect(_ url: URL) throws -> (frames: Int, peak: Float, rate: Double) {
        let f = try AVAudioFile(forReading: url)
        let n = Int(f.length)
        guard n > 0 else { return (0, 0, f.processingFormat.sampleRate) }
        let buf = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(n)))
        try f.read(into: buf, frameCount: AVAudioFrameCount(n))
        let data = try XCTUnwrap(buf.floatChannelData)
        var peak: Float = 0
        for i in 0..<Int(buf.frameLength) { peak = max(peak, abs(data[0][i])) }
        return (Int(buf.frameLength), peak, f.processingFormat.sampleRate)
    }

    private func sine(seconds: Double, amplitude: Float, hz: Double = 440) -> [Float] {
        let n = Int(16000 * seconds)
        return (0..<n).map { amplitude * Float(sin(2 * Double.pi * hz * Double($0) / 16000)) }
    }

    private func args(options: WhisperOptions) -> [String] {
        WhisperTranscriber.arguments(model: URL(fileURLWithPath: "/m/ggml-large-v3.bin"), wav: URL(fileURLWithPath: "/w/a.wav"),
                                     language: "auto", outputPrefix: URL(fileURLWithPath: "/o/pre"), options: options)
    }

    // MARK: 引数(デコード設定・VAD)

    func testOptionsArgumentsAddDecodeFlagsAfterTheOldEightInOrder() {
        let a = args(options: WhisperOptions(vad: nil))
        XCTAssertEqual(Array(a.prefix(8)), ["-m", "/m/ggml-large-v3.bin", "-f", "/w/a.wav", "-l", "auto", "-ojf", "-of"])
        XCTAssertEqual(valueAfter("-bs", in: a), "5")
        XCTAssertEqual(valueAfter("-bo", in: a), "5")
        XCTAssertEqual(valueAfter("-tp", in: a), "0.0")
        XCTAssertTrue(a.contains("-sns"), "既定は記号・音楽記号を抑える")
        XCTAssertFalse(a.contains("--vad"), "VAD 無効のときは入らない")
        XCTAssertFalse(a.contains("-vm"))
    }

    func testSuppressFlagFollowsOptions() {
        let a = args(options: WhisperOptions(suppressNonSpeechTokens: false, vad: nil))
        XCTAssertFalse(a.contains("-sns"))
    }

    func testVADArgumentsAppearOnlyWhenEnabled() {
        let vad = WhisperVADOptions(model: URL(fileURLWithPath: "/v/ggml-silero-v5.1.2.bin"), threshold: 0.4,
                                    minSpeechMs: 300, minSilenceMs: 150, speechPadMs: 40)
        let a = args(options: WhisperOptions(vad: vad))
        XCTAssertTrue(a.contains("--vad"))
        XCTAssertEqual(valueAfter("-vm", in: a), "/v/ggml-silero-v5.1.2.bin")
        XCTAssertEqual(valueAfter("-vt", in: a), "0.4")
        XCTAssertEqual(valueAfter("-vspd", in: a), "300")
        XCTAssertEqual(valueAfter("-vsd", in: a), "150")
        XCTAssertEqual(valueAfter("-vp", in: a), "40")
        XCTAssertEqual(Array(a.prefix(8)), ["-m", "/m/ggml-large-v3.bin", "-f", "/w/a.wav", "-l", "auto", "-ojf", "-of"])
    }

    private func valueAfter(_ flag: String, in a: [String]) -> String? {
        guard let i = a.firstIndex(of: flag), a.indices.contains(i + 1) else { return nil }
        return a[i + 1]
    }

    // MARK: 既定の言語・VAD の自動検出

    func testDefaultLanguageIsAuto() async throws {
        let record = tmp.appendingPathComponent("args.txt").path
        let fixed = #"{"transcription":[{"offsets":{"from":0,"to":1000},"text":" はい"}]}"#
        let exe = try makeScript(body: recordingBody(record: record, jsonText: fixed))
        let t = WhisperTranscriber(executablePath: exe, modelPath: try makeModel(), vadModelPath: "/nonexistent/vad.bin")
        XCTAssertEqual(t.language, "auto")
        let audio = tmp.appendingPathComponent("in.wav")
        try writeWAV16k(sine(seconds: 0.2, amplitude: 0.1), to: audio)
        _ = try await t.transcribe(audioURL: audio, duration: 1, onProgress: { _ in })
        let text = try String(contentsOfFile: record, encoding: .utf8)
        XCTAssertTrue(text.contains("-l=auto"), text)
    }

    func testVADModelFoundInSupportFolderIsResolvedAndExplicitPathWins() throws {
        let support = tmp.appendingPathComponent("support")
        let dir = support.appendingPathComponent("Whisper")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data([0]).write(to: dir.appendingPathComponent("ggml-large-v3.bin"))
        XCTAssertNil(WhisperLocator.resolveVADModel(supportRoot: support), "VAD モデルが無いときは nil")
        try Data([0]).write(to: dir.appendingPathComponent("ggml-silero-v5.1.2.bin"))
        XCTAssertEqual(WhisperLocator.resolveVADModel(supportRoot: support)?.lastPathComponent, "ggml-silero-v5.1.2.bin")

        let exe = try makeScript(body: "exit 0")
        let explicit = tmp.appendingPathComponent("my-vad.bin")
        try Data([0]).write(to: explicit)
        let t = WhisperTranscriber(executablePath: exe, modelPath: try makeModel(), vadModelPath: explicit.path)
        XCTAssertEqual(t.options.vad?.model.path, explicit.path, "明示指定が優先される")
    }

    func testVADIsEnabledWhenFoundAndOptionsKeepValues() throws {
        let exe = try makeScript(body: "exit 0")
        let vadFile = tmp.appendingPathComponent("ggml-silero-test.bin")
        try Data([0]).write(to: vadFile)
        let t = WhisperTranscriber(executablePath: exe, modelPath: try makeModel(), options: WhisperOptions(beamSize: 3), vadModelPath: vadFile.path)
        XCTAssertEqual(t.options.beamSize, 3)
        XCTAssertEqual(t.options.vad?.threshold, 0.5)
        XCTAssertEqual(t.options.vad?.minSpeechMs, 250)
    }

    // MARK: 日英混在

    func testMixedJapaneseEnglishTokensStayEnglish() throws {
        let j = """
        {"transcription":[{"offsets":{"from":0,"to":2000},"text":" 今日は Meeting をします","tokens":[
          {"text":"今日","offsets":{"from":0,"to":500}},
          {"text":"は","offsets":{"from":500,"to":700}},
          {"text":" Meeting","offsets":{"from":700,"to":1200}},
          {"text":"を","offsets":{"from":1200,"to":1400}},
          {"text":"します","offsets":{"from":1400,"to":2000}}]}]}
        """
        let segs = try WhisperJSONParser.parse(Data(j.utf8))
        let joined = segs.map(\.text).joined()
        XCTAssertTrue(joined.contains("Meeting"), joined)
        XCTAssertTrue(joined.contains("今日は"), joined)
        XCTAssertFalse(joined.contains("\u{FFFD}"))
        XCTAssertFalse(joined.contains("ミーティング"), "カタカナ化されない")
    }

    // MARK: 前処理

    func testPreprocessingRaisesQuietPeakToAboutMinus1dBWithSameFrames() throws {
        let input = tmp.appendingPathComponent("quiet.wav")
        try writeWAV16k(sine(seconds: 1, amplitude: 0.1), to: input)
        let before = try inspect(input)
        let output = tmp.appendingPathComponent("quiet-pre.wav")
        let r = try WhisperPreprocessing.prepare(input: input, output: output)
        XCTAssertEqual(r, output)
        let after = try inspect(output)
        XCTAssertEqual(after.frames, before.frames, "フレーム数は変えない(時刻がずれない)")
        XCTAssertEqual(after.rate, 16000)
        XCTAssertEqual(after.peak, WhisperPreprocessing.targetPeak, accuracy: 0.03, "ピークが -1 dBFS 付近まで上がる")
        XCTAssertLessThanOrEqual(after.peak, 1)
    }

    func testPreprocessingSilenceStaysSilentAndSameLength() throws {
        let input = tmp.appendingPathComponent("silent.wav")
        try writeWAV16k([Float](repeating: 0, count: 8000), to: input)
        let output = tmp.appendingPathComponent("silent-pre.wav")
        XCTAssertNoThrow(try WhisperPreprocessing.prepare(input: input, output: output))
        let after = try inspect(output)
        XCTAssertEqual(after.frames, 8000)
        XCTAssertEqual(after.peak, 0)
    }

    func testPreprocessingDoesNotTouchInputFile() throws {
        let input = tmp.appendingPathComponent("keep.wav")
        try writeWAV16k(sine(seconds: 0.5, amplitude: 0.1), to: input)
        let before = try Data(contentsOf: input)
        _ = try WhisperPreprocessing.prepare(input: input, output: tmp.appendingPathComponent("keep-pre.wav"))
        XCTAssertEqual(try Data(contentsOf: input), before)
    }

    func testPreprocessingOffSendsOriginalFileName() async throws {
        let record = tmp.appendingPathComponent("args.txt").path
        let fixed = #"{"transcription":[{"offsets":{"from":0,"to":1000},"text":" あ"}]}"#
        let exe = try makeScript(body: recordingBody(record: record, jsonText: fixed))
        let t = WhisperTranscriber(executablePath: exe, modelPath: try makeModel(), vadModelPath: "/nonexistent/vad.bin", preprocessing: false)
        let audio = tmp.appendingPathComponent("raw16.wav")
        try writeWAV16k(sine(seconds: 0.2, amplitude: 0.1), to: audio)
        _ = try await t.transcribe(audioURL: audio, duration: 1, onProgress: { _ in })
        let text = try String(contentsOfFile: record, encoding: .utf8)
        XCTAssertTrue(text.contains("-f=\(audio.path)"), text)
    }

    // MARK: モデルのカタログ

    func testCatalogRecommendsLargeV3WithOfficialURL() {
        XCTAssertEqual(WhisperModelCatalog.recommended.id, "large-v3")
        XCTAssertEqual(WhisperModelCatalog.recommended.fileName, "ggml-large-v3.bin")
        XCTAssertEqual(WhisperModelCatalog.recommended.downloadURL.absoluteString,
                       "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3.bin")
        XCTAssertEqual(WhisperModelCatalog.downloadURL(forFileName: "ggml-base.bin")?.absoluteString,
                       "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin")
        XCTAssertEqual(WhisperModelCatalog.model(forFileName: "ggml-large-v3-turbo.bin")?.id, "large-v3-turbo")
        XCTAssertNil(WhisperModelCatalog.model(forFileName: "ggml-unknown.bin"))
        XCTAssertNil(WhisperModelCatalog.downloadURL(forFileName: "ggml-unknown.bin"))
    }

    func testCatalogListsSixModelsAllHTTPSAndNamed() {
        XCTAssertEqual(WhisperModelCatalog.models.map(\.id), ["tiny", "base", "small", "medium", "large-v3-turbo", "large-v3"])
        for m in WhisperModelCatalog.models {
            XCTAssertEqual(m.downloadURL.scheme, "https")
            XCTAssertTrue(m.downloadURL.absoluteString.hasSuffix("/" + m.fileName), m.id)
            XCTAssertTrue(m.fileName.hasPrefix("ggml-") && m.fileName.hasSuffix(".bin"), m.id)
            XCTAssertGreaterThan(m.approximateMB, 0)
        }
    }
}
