import XCTest
import AVFoundation
@testable import MovieCutCore

/// Whisper(whisper.cpp)文字起こしのテスト。実物の whisper-cli は使わず、temp に置いた偽の実行ファイル(シェルスクリプト)で確かめる。
final class WhisperTranscriptionTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("whisper-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    // MARK: helpers

    private func json(_ s: String) -> Data { Data(s.utf8) }

    /// 実行可能な偽 whisper-cli を作る(chmod 755)。
    private func makeScript(_ name: String = "whisper-cli", body: String) throws -> String {
        let url = tmp.appendingPathComponent(name)
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    private func makeModel(_ name: String = "ggml-base.bin") throws -> String {
        let url = tmp.appendingPathComponent(name)
        try Data([0]).write(to: url)
        return url.path
    }

    private var fixtureWav: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/aq_reimu.wav")
    }

    private let fixedJSON = """
    {"transcription":[{"offsets":{"from":0,"to":1500},"text":" こんにちは"},{"offsets":{"from":2000,"to":3500},"text":" 世界です"}]}
    """

    /// 引数を記録し、`-of` の値 + ".json" に固定 JSON を書く偽スクリプト本体。
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

    /// 既に 16kHz モノラルの短い WAV(変換を通らない入力)。
    private func dummyAudio() throws -> URL {
        let u = tmp.appendingPathComponent("in16-\(UUID().uuidString).wav")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000.0, AVNumberOfChannelsKey: 1,
                                       AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        let f = try AVAudioFile(forWriting: u, settings: settings)
        let buf = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: 1600))
        buf.frameLength = 1600
        try f.write(from: buf)
        return u
    }

    // MARK: JSON パース

    func testParseBasicOffsetsAndTrim() throws {
        let segs = try WhisperJSONParser.parse(json(fixedJSON))
        XCTAssertEqual(segs.count, 2)
        XCTAssertEqual(segs[0].text, "こんにちは")
        XCTAssertEqual(segs[0].start, 0, accuracy: 1e-9)
        XCTAssertEqual(segs[0].end, 1.5, accuracy: 1e-9)
        XCTAssertEqual(segs[1].text, "世界です")
        XCTAssertEqual(segs[1].start, 2.0, accuracy: 1e-9)
        XCTAssertEqual(segs[1].end, 3.5, accuracy: 1e-9)
    }

    func testParseGroupsTokensIntoPhrases() throws {
        let j = """
        {"transcription":[{"offsets":{"from":0,"to":3000},"text":" 今日は晴れ。明日は雨","tokens":[
          {"text":"今日","offsets":{"from":0,"to":500}},
          {"text":"は","offsets":{"from":500,"to":800}},
          {"text":"晴れ。","offsets":{"from":800,"to":1500}},
          {"text":"明日","offsets":{"from":1600,"to":2200}},
          {"text":"は雨","offsets":{"from":2200,"to":3000}}]}]}
        """
        let segs = try WhisperJSONParser.parse(json(j))
        XCTAssertEqual(segs.map(\.text), ["今日は晴れ。", "明日は雨"])
        XCTAssertEqual(segs[0].start, 0, accuracy: 1e-9)
        XCTAssertEqual(segs[0].end, 1.5, accuracy: 1e-9)
        XCTAssertEqual(segs[1].start, 1.6, accuracy: 1e-9)
        XCTAssertEqual(segs[1].end, 3.0, accuracy: 1e-9)
        XCTAssertEqual(segs[0].words.count, 3)
    }

    func testParseDropsSpecialTokens() throws {
        let j = """
        {"transcription":[{"offsets":{"from":0,"to":1000},"text":" はい","tokens":[
          {"text":"[_BEG_]","offsets":{"from":0,"to":0}},
          {"text":"はい","offsets":{"from":0,"to":900}},
          {"text":"[_TT_45]","offsets":{"from":900,"to":900}}]}]}
        """
        let segs = try WhisperJSONParser.parse(json(j))
        XCTAssertEqual(segs.count, 1)
        XCTAssertEqual(segs[0].text, "はい")
        XCTAssertFalse(segs[0].text.contains("[_"))
    }

    func testParseFallsBackToSegmentOnBrokenToken() throws {
        let j = """
        {"transcription":[{"offsets":{"from":1000,"to":2000},"text":" 猫","tokens":[
          {"text":"\u{FFFD}","offsets":{"from":1000,"to":1500}},
          {"text":"\u{FFFD}","offsets":{"from":1500,"to":2000}}]}]}
        """
        let segs = try WhisperJSONParser.parse(json(j))
        XCTAssertEqual(segs.count, 1)
        XCTAssertEqual(segs[0].text, "猫")
        XCTAssertEqual(segs[0].start, 1.0, accuracy: 1e-9)
        XCTAssertEqual(segs[0].end, 2.0, accuracy: 1e-9)
    }

    func testParseDropsEmptySegments() throws {
        let j = """
        {"transcription":[{"offsets":{"from":0,"to":500},"text":"   "},{"offsets":{"from":500,"to":900},"text":""},{"offsets":{"from":900,"to":1200},"text":"あ"}]}
        """
        let segs = try WhisperJSONParser.parse(json(j))
        XCTAssertEqual(segs.map(\.text), ["あ"])
    }

    func testParseBrokenJSONThrows() {
        for bad in ["", "not json", "{\"transcription\":", "{\"foo\":1}"] {
            XCTAssertThrowsError(try WhisperJSONParser.parse(json(bad)), bad) { e in
                guard case TranscriptionError.failed = e else { return XCTFail("failed 以外: \(e)") }
            }
        }
    }

    // MARK: 16kHz 変換

    func testConverter48kTo16kMono() throws {
        let src = try AVAudioFile(forReading: fixtureWav)
        XCTAssertNotEqual(src.processingFormat.sampleRate, 16000)
        let out = tmp.appendingPathComponent("out16.wav")
        let r = try WhisperAudioConverter.prepare(input: fixtureWav, output: out)
        XCTAssertEqual(r, out)
        let f = try AVAudioFile(forReading: out)
        XCTAssertEqual(f.processingFormat.sampleRate, 16000)
        XCTAssertEqual(f.processingFormat.channelCount, 1)
        let d0 = Double(src.length) / src.processingFormat.sampleRate
        let d1 = Double(f.length) / 16000
        XCTAssertGreaterThan(d0, 0.1)
        XCTAssertEqual(d1, d0, accuracy: 0.02)
    }

    func testConverterReturnsInputWhenAlready16kMono() throws {
        let first = try dummyAudio()
        let second = tmp.appendingPathComponent("b16.wav")
        let r = try WhisperAudioConverter.prepare(input: first, output: second)
        XCTAssertEqual(r, first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
    }

    // MARK: Locator

    func testCandidatesOrder() {
        let bundle = URL(fileURLWithPath: "/B/Resources")
        let support = URL(fileURLWithPath: "/S/root")
        let c = WhisperLocator.candidates(userSetting: "/U/whisper", bundleResources: bundle, supportRoot: support)
        XCTAssertEqual(c, [
            "/U/whisper",
            "/B/Resources/Whisper/whisper-cli",
            "/S/root/Whisper/whisper-cli",
            "/S/root/Whisper/whisper-cpp",
            "/S/root/Whisper/main",
            "/opt/homebrew/bin/whisper-cli",
            "/usr/local/bin/whisper-cli",
            "/opt/homebrew/bin/whisper-cpp",
            "/usr/local/bin/whisper-cpp",
        ])
    }

    func testCandidatesWithoutUserSettingOrBundle() {
        let support = URL(fileURLWithPath: "/S/root")
        XCTAssertEqual(WhisperLocator.candidates(userSetting: nil, bundleResources: nil, supportRoot: support).first, "/S/root/Whisper/whisper-cli")
        XCTAssertEqual(WhisperLocator.candidates(userSetting: "", bundleResources: nil, supportRoot: support).first, "/S/root/Whisper/whisper-cli")
    }

    func testSortedModelNamesPriority() {
        let names = ["ggml-tiny.bin", "readme.txt", "ggml-small.bin", "ggml-large-v3-turbo.bin", "ggml-base.en.bin",
                     "ggml-large-v3.bin", "ggml-medium.bin", "ggml-zzz.bin", "ggml-base.bin", "other.bin"]
        let sorted = WhisperLocator.sortedModelNames(names)
        XCTAssertEqual(sorted, ["ggml-large-v3.bin", "ggml-large-v3-turbo.bin", "ggml-medium.bin", "ggml-small.bin",
                                "ggml-base.bin", "ggml-base.en.bin", "ggml-tiny.bin", "ggml-zzz.bin"])
    }

    func testResolveModelPrefersUserSettingThenSupportFolder() throws {
        let dir = tmp.appendingPathComponent("Whisper")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data([0]).write(to: dir.appendingPathComponent("ggml-tiny.bin"))
        try Data([0]).write(to: dir.appendingPathComponent("ggml-small.bin"))
        XCTAssertEqual(WhisperLocator.resolveModel(userSetting: nil, supportRoot: tmp)?.lastPathComponent, "ggml-small.bin")
        let mine = try makeModel("mine.bin")
        XCTAssertEqual(WhisperLocator.resolveModel(userSetting: mine, supportRoot: tmp)?.path, mine)
        // 存在しない設定は飛ばして次へ
        XCTAssertEqual(WhisperLocator.resolveModel(userSetting: "/nonexistent/x.bin", supportRoot: tmp)?.lastPathComponent, "ggml-small.bin")
        // .bin 以外は不可
        let txt = tmp.appendingPathComponent("m.txt"); try Data([0]).write(to: txt)
        XCTAssertNil(WhisperLocator.validateModel(path: txt.path))
    }

    func testResolveExecutableOrderAndValidation() throws {
        let a = try makeScript("a-cli", body: "exit 0")
        let b = try makeScript("b-cli", body: "exit 0")
        let support = tmp.appendingPathComponent("nosupport")
        XCTAssertEqual(WhisperLocator.resolve(userSetting: a, bundleResources: nil, supportRoot: support)?.lastPathComponent, "a-cli")
        // 設定が無効なら、後ろの候補(ここでは Application Support)へ
        let wdir = support.appendingPathComponent("Whisper")
        try FileManager.default.createDirectory(at: wdir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: b, toPath: wdir.appendingPathComponent("whisper-cli").path)
        XCTAssertEqual(WhisperLocator.resolve(userSetting: "/nonexistent/w", bundleResources: nil, supportRoot: support)?.deletingLastPathComponent().lastPathComponent, "Whisper")
        // 禁止フォルダ内は不可
        XCTAssertNil(WhisperLocator.validate(path: a, forbiddenRoots: [tmp]))
        XCTAssertNil(WhisperLocator.validate(path: "relative/path"))
        XCTAssertNil(WhisperLocator.validate(path: tmp.path + "/../" + tmp.lastPathComponent + "/a-cli"))
    }

    func testValidateFollowsSymlinkToRealFile() throws {
        let real = try makeScript("real-cli", body: "exit 0")
        let link = tmp.appendingPathComponent("link-cli")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: real)
        XCTAssertEqual(WhisperLocator.validate(path: link.path)?.lastPathComponent, "real-cli")
    }

    // MARK: 偽の実行ファイルで transcribe

    func testTranscribeWithFakeExecutable() async throws {
        let record = tmp.appendingPathComponent("args.txt").path
        let exe = try makeScript(body: recordingBody(record: record, jsonText: fixedJSON))
        let model = try makeModel()
        let audio = try dummyAudio()
        let t = WhisperTranscriber(executablePath: exe, modelPath: model, language: "ja")
        XCTAssertNotNil(t.executable)
        XCTAssertNotNil(t.model)

        let segs = try await t.transcribe(audioURL: audio, duration: 3, onProgress: { _ in })
        XCTAssertEqual(segs.map(\.text), ["こんにちは", "世界です"])
        XCTAssertEqual(segs[1].start, 2.0, accuracy: 1e-9)

        let lines = try String(contentsOfFile: record, encoding: .utf8).split(separator: "\n").map(String.init)
        let realModel = URL(fileURLWithPath: model).path
        XCTAssertTrue(lines.contains("-m=\(realModel)"), "\(lines)")
        XCTAssertTrue(lines.contains("-l=ja"), "\(lines)")
        let f = lines.first { $0.hasPrefix("-f=") }
        XCTAssertNotNil(f)
        // 既定は前処理(音量正規化・ノイズ除去)を通した一時ファイルが渡される。入力そのものは書き換えない(前処理の中身は WhisperAccuracyTests で確かめる)
        let passed = f.map { URL(fileURLWithPath: String($0.dropFirst(3))).lastPathComponent }
        XCTAssertNotEqual(passed, audio.lastPathComponent)
        XCTAssertTrue(passed?.hasSuffix("-pre.wav") ?? false, "\(lines)")
        XCTAssertTrue(lines.contains { $0.hasPrefix("-of=") })
    }

    func testTranscribePassesLanguage() async throws {
        let record = tmp.appendingPathComponent("args.txt").path
        let exe = try makeScript(body: recordingBody(record: record, jsonText: fixedJSON))
        let t = WhisperTranscriber(executablePath: exe, modelPath: try makeModel(), language: "en")
        _ = try await t.transcribe(audioURL: try dummyAudio(), duration: 3, onProgress: { _ in })
        let text = try String(contentsOfFile: record, encoding: .utf8)
        XCTAssertTrue(text.contains("-l=en"))
    }

    func testTranscribeReportsProgressFromStderr() async throws {
        let body = """
        out=""
        while [ $# -gt 0 ]; do
          case "$1" in -of) out="$2"; shift 2;; *) shift;; esac
        done
        echo "whisper_print_progress_callback: progress =  50%" >&2
        sleep 1
        echo "whisper_print_progress_callback: progress = 100%" >&2
        cat > "$out.json" <<'JSONEOF'
        \(fixedJSON)
        JSONEOF
        """
        let exe = try makeScript(body: body)
        let t = WhisperTranscriber(executablePath: exe, modelPath: try makeModel())
        final class Box: @unchecked Sendable { let l = NSLock(); var v: [Double] = []; func add(_ x: Double) { l.withLock { v.append(x) } } }
        let box = Box()
        _ = try await t.transcribe(audioURL: try dummyAudio(), duration: 3, onProgress: { box.add($0) })
        let got = box.l.withLock { box.v }
        XCTAssertEqual(got.first ?? -1, 0.05, accuracy: 1e-9)
        XCTAssertEqual(got.last ?? -1, 1, accuracy: 1e-9)
        XCTAssertTrue(got.contains { abs($0 - 0.5) < 1e-9 }, "\(got)")
    }

    func testProgressLineParsing() {
        XCTAssertEqual(WhisperTranscriber.progress(inStderrLine: "whisper_print_progress_callback: progress =  40%") ?? -1, 0.4, accuracy: 1e-9)
        XCTAssertEqual(WhisperTranscriber.progress(inStderrLine: "progress = 100%") ?? -1, 1, accuracy: 1e-9)
        XCTAssertNil(WhisperTranscriber.progress(inStderrLine: "no progress here"))
        XCTAssertNil(WhisperTranscriber.progress(inStderrLine: "progress = 250%"))
        XCTAssertNil(WhisperTranscriber.progress(inStderrLine: "progress = abc"))
    }

    func testArgumentsAndTimeout() {
        let a = WhisperTranscriber.arguments(model: URL(fileURLWithPath: "/m/ggml-base.bin"), wav: URL(fileURLWithPath: "/w/a.wav"),
                                             language: "ja", outputPrefix: URL(fileURLWithPath: "/o/pre"))
        XCTAssertEqual(Array(a.prefix(8)), ["-m", "/m/ggml-base.bin", "-f", "/w/a.wav", "-l", "ja", "-ojf", "-of"])
        XCTAssertTrue(a.contains("/o/pre"))
        XCTAssertEqual(WhisperTranscriber.timeout(forDuration: 0), 600)
        XCTAssertEqual(WhisperTranscriber.timeout(forDuration: 60), 1200)
        XCTAssertEqual(WhisperTranscriber.timeout(forDuration: 100000), 3600)
        XCTAssertEqual(WhisperTranscriber.timeout(forDuration: .nan), 600)
    }

    // MARK: 未配置・失敗

    func testNotInstalled() async throws {
        let t = WhisperTranscriber(executablePath: "/nonexistent/whisper-cli", modelPath: try makeModel())
        XCTAssertNil(t.executable)
        do {
            _ = try await t.transcribe(audioURL: try dummyAudio(), duration: 1, onProgress: { _ in })
            XCTFail("throw するはず")
        } catch TranscriptionError.whisperNotInstalled {
        } catch { XCTFail("\(error)") }
    }

    func testModelMissing() async throws {
        let exe = try makeScript(body: "exit 0")
        let t = WhisperTranscriber(executablePath: exe, modelPath: tmp.appendingPathComponent("none.bin").path)
        XCTAssertNotNil(t.executable)
        XCTAssertNil(t.model)
        do {
            _ = try await t.transcribe(audioURL: try dummyAudio(), duration: 1, onProgress: { _ in })
            XCTFail("throw するはず")
        } catch TranscriptionError.whisperModelMissing {
        } catch { XCTFail("\(error)") }
    }

    func testNonZeroExitFails() async throws {
        let exe = try makeScript(body: "echo 'boom reason' >&2\nexit 1")
        let t = WhisperTranscriber(executablePath: exe, modelPath: try makeModel())
        do {
            _ = try await t.transcribe(audioURL: try dummyAudio(), duration: 1, onProgress: { _ in })
            XCTFail("throw するはず")
        } catch TranscriptionError.failed(let msg) {
            XCTAssertTrue(msg.contains("boom reason"), msg)
        } catch { XCTFail("\(error)") }
    }

    func testMissingJSONOutputFails() async throws {
        let exe = try makeScript(body: "exit 0")
        let t = WhisperTranscriber(executablePath: exe, modelPath: try makeModel())
        do {
            _ = try await t.transcribe(audioURL: try dummyAudio(), duration: 1, onProgress: { _ in })
            XCTFail("throw するはず")
        } catch TranscriptionError.failed {
        } catch { XCTFail("\(error)") }
    }

    func testCancelReturnsQuickly() async throws {
        // exec で sleep に置き換え、terminate 後に stderr を握る孫プロセスを残さない。
        let exe = try makeScript(body: "exec sleep 30")
        let t = WhisperTranscriber(executablePath: exe, modelPath: try makeModel())
        let audio = try dummyAudio()
        let started = Date()
        let task = Task { try await t.transcribe(audioURL: audio, duration: 1, onProgress: { _ in }) }
        try await Task.sleep(nanoseconds: 600_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("throw するはず")
        } catch is CancellationError {
        } catch { XCTFail("\(error)") }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    // MARK: 設定

    func testSettingsRoundTrip() throws {
        let name = "whisper-tests-\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { d.removePersistentDomain(forName: name) }
        XCTAssertNil(SecuritySettings.whisperPath(d))
        XCTAssertNil(SecuritySettings.whisperModelPath(d))
        SecuritySettings.setWhisperPath("/opt/x/whisper-cli", to: d)
        SecuritySettings.setWhisperModelPath("/opt/x/ggml-base.bin", to: d)
        XCTAssertEqual(SecuritySettings.whisperPath(d), "/opt/x/whisper-cli")
        XCTAssertEqual(SecuritySettings.whisperModelPath(d), "/opt/x/ggml-base.bin")
        SecuritySettings.setWhisperPath(nil, to: d)
        XCTAssertNil(SecuritySettings.whisperPath(d))
        XCTAssertEqual(SecuritySettings.whisperModelPath(d), "/opt/x/ggml-base.bin")
        SecuritySettings.setWhisperModelPath("", to: d)
        XCTAssertNil(SecuritySettings.whisperModelPath(d))
    }

    // MARK: エラーメッセージ

    func testNewErrorsHaveJapaneseMessages() {
        for e in [TranscriptionError.whisperNotInstalled, .whisperModelMissing] {
            let m = e.errorDescription ?? ""
            XCTAssertFalse(m.isEmpty)
            XCTAssertTrue(m.contains("Whisper") || m.contains("whisper"))
            XCTAssertNotNil(m.range(of: "[\\p{Hiragana}\\p{Katakana}\\p{Han}]", options: .regularExpression), m)
        }
    }
}
