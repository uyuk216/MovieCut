import XCTest
import AVFoundation
import MovieCutCore
@testable import MovieCut

/// VST3 再生配線のアプリ側検証(ラウンド3)。
/// - 再生キャッシュ鍵(`AudioCacheKey`)に VST3 の選択・パラメータ・状態が反映されること。
/// - 既定ミキサーを使う再生コントローラが、VST3 スロットの追加でミックスを作り直すこと
///   (鍵が変わらなければ作り直しは走らないので、鍵への組み込みと再生経路の結線を同時に固定する)。
/// 実プラグイン・実ブリッジ・キーチェーンには触らない(この Mac に無いプラグインの指定はバイパスで、
/// ミックス自体は通常どおり作られる)。
@MainActor
final class VST3WiringAppTests: XCTestCase {

    private func audioProject() -> Project {
        var c = Clip(); c.id = "a"; c.type = .audio; c.src = "/tmp/a.wav"; c.start = 0; c.duration = 2; c.srcDuration = 2
        var t = Track(name: "L"); t.clips = [c]
        var p = Project(); p.tracks = [t]
        return p
    }

    func testAudioCacheKeyChangesWithVST3Settings() {
        let dates: (String) -> Date? = { _ in Date(timeIntervalSinceReferenceDate: 1000) }
        let base = audioProject()
        let k0 = AudioCacheKey.make(for: base, fileDate: dates)
        func key(_ mutate: (inout Project) -> Void) -> AudioCacheKey {
            var q = base; mutate(&q); return AudioCacheKey.make(for: q, fileDate: dates)
        }
        // スロット追加で変わる(他の fx が無く isActive でなくても)
        let withSlot = key { $0.tracks[0].clips[0].audioFx = AudioFx(vst3: [AudioFx.VST3Slot(bundleID: "com.example.fakegain", name: "FakeGain")]) }
        XCTAssertNotEqual(withSlot, k0, "VST3 スロットの追加で再生鍵が変わる")
        // パラメータ変更で変わる
        let withParam = key { $0.tracks[0].clips[0].audioFx = AudioFx(vst3: [AudioFx.VST3Slot(bundleID: "com.example.fakegain", name: "FakeGain", params: ["0": 0.5])]) }
        XCTAssertNotEqual(withParam, withSlot, "パラメータ変更で鍵が変わる")
        XCTAssertNotEqual(withParam, k0)
        // 状態チャンクの追加でも変わる
        let withState = key { $0.tracks[0].clips[0].audioFx = AudioFx(vst3: [AudioFx.VST3Slot(bundleID: "com.example.fakegain", name: "FakeGain", params: ["0": 0.5], state: Data([1, 2, 3]).base64EncodedString())]) }
        XCTAssertNotEqual(withState, withParam, "状態チャンクの変更で鍵が変わる")
        // 別のプラグイン選択でも変わる
        let other = key { $0.tracks[0].clips[0].audioFx = AudioFx(vst3: [AudioFx.VST3Slot(bundleID: "com.example.other", name: "Other")]) }
        XCTAssertNotEqual(other, withSlot)
        // 無効化したスロットだけなら、スロット無しと同じ鍵(音が同じだから)
        let disabled = key { $0.tracks[0].clips[0].audioFx = AudioFx(vst3: [AudioFx.VST3Slot(bundleID: "com.example.fakegain", name: "FakeGain", enabled: false)]) }
        XCTAssertEqual(disabled, k0, "無効なスロットは鍵に影響しない")
    }

    /// 振幅つき WAV を一時フォルダに書く(アプリ側テスト用の最小ヘルパー)。
    private func writeTone(_ url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = 48000
        let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames))!
        buf.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames {
            let v = Float(0.3 * sin(2 * .pi * 440 * Double(i) / 48000))
            buf.floatChannelData![0][i] = v; buf.floatChannelData![1][i] = v
        }
        try file.write(from: buf)
    }

    func testPlaybackRebuildsWhenVST3SlotIsAdded() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("vst3wiring-app-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let tone = tmp.appendingPathComponent("tone.wav")
        try writeTone(tone)

        var p = Project.new()
        var c = Clip(); c.id = "a"; c.type = .audio; c.src = tone.path; c.start = 0; c.duration = 1; c.srcDuration = 1
        p.tracks[0].clips = [c]
        let m = ProjectModel(project: p)
        m.notices = OneTimeNotices()
        let playback = m.playback!   // 既定ミキサー(AppServices の VST3 プロバイダ経由)を使う本体
        playback.warmUp()
        // 初回のミックスができるまで待つ
        for _ in 0..<100 where playback.rebuildCount < 1 { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertGreaterThanOrEqual(playback.rebuildCount, 1, "初回ミックスが作られる")
        let before = playback.rebuildCount

        // VST3 スロットを追加すると、再生鍵が変わってミックスが作り直される
        m.setAudioFx({ _ = AudioFxEditing.addVST3Slot(&$0, bundleID: "com.example.fakegain", name: "FakeGain") },
                     name: ProjectModel.vst3UndoName, clipId: "a")
        for _ in 0..<100 where playback.rebuildCount <= before { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertGreaterThan(playback.rebuildCount, before, "VST3 追加で再生ミックスが作り直される(鍵への組み込みの証拠)")
        m.shutdown()
    }

    func testAppServicesProviderMatchesStandardScan() {
        // アプリの生成元は Core の標準スキャンと一致する 1 本だけ(二重実装しない)。
        XCTAssertEqual(AppServices.vst3EffectProvider.audioEffectDescriptors.map { $0.id },
                       VST3Scanner.scanStandard().usablePlugins.map { $0.audioEffectID })
    }
}
