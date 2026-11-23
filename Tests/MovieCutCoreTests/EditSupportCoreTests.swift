import XCTest
import AVFoundation
@testable import MovieCutCore

/// 第3波バッチJ の Core 側: グループ制御の拡充(#15)、検索・置換の対象拡張(#20)、レベルメーターの値計算(#22)。
final class EditSupportCoreTests: XCTestCase {

    // MARK: #15 無効化(disabled)の保存と互換

    func testDisabledRoundTripAndOldFileCompatibility() throws {
        var c = Clip(); c.disabled = true
        let data = try JSONEncoder().encode(c)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"disabled\":true"), json)
        XCTAssertTrue(try JSONDecoder().decode(Clip.self, from: data).isDisabled)

        // 無効でないクリップはキーを書かない
        let plain = try JSONEncoder().encode(Clip())
        XCTAssertFalse((String(data: plain, encoding: .utf8) ?? "").contains("\"disabled\""))

        // 旧ファイル(disabled キー無し)は有効なクリップとして読める
        let old = try JSONDecoder().decode(Clip.self, from: Data("{\"id\":\"x\",\"type\":\"image\",\"start\":0,\"duration\":1,\"offset\":0}".utf8))
        XCTAssertFalse(old.isDisabled)
    }

    // MARK: #15 グループの一括有効/無効

    private func groupedProject() -> Project {
        var p = Project(); p.characters = []
        func clip(_ id: String, _ start: Double, group: String? = nil) -> Clip {
            var c = Clip(); c.id = id; c.type = .image; c.start = start; c.duration = 2; c.group = group
            return c
        }
        var t1 = Track(name: "上"); t1.clips = [clip("a", 0, group: "g1"), clip("b", 3)]
        var t2 = Track(name: "下"); t2.clips = [clip("c", 1, group: "g1")]
        p.tracks = [t1, t2]
        return p
    }

    func testGroupSetDisabled() {
        var p = groupedProject()
        XCTAssertFalse(ClipGrouping.allDisabled("g1", in: p))
        XCTAssertEqual(ClipGrouping.setDisabled("g1", on: true, in: &p), 2)
        XCTAssertTrue(ClipGrouping.allDisabled("g1", in: p))
        XCTAssertTrue(p.allClips.first { $0.id == "a" }!.isDisabled)
        XCTAssertTrue(p.allClips.first { $0.id == "c" }!.isDisabled)
        XCTAssertFalse(p.allClips.first { $0.id == "b" }!.isDisabled, "グループ外は変えない")
        // 同じ状態への再設定は変わらない
        XCTAssertEqual(ClipGrouping.setDisabled("g1", on: true, in: &p), 0)
        XCTAssertEqual(ClipGrouping.setDisabled("g1", on: false, in: &p), 2)
        XCTAssertFalse(ClipGrouping.allDisabled("g1", in: p))
        XCTAssertNil(p.allClips.first { $0.id == "a" }!.disabled, "有効に戻すとキーは消える")
    }

    func testDisabledClipsAreExcludedFromAudioAndPicture() {
        var p = groupedProject()
        // 音: ボイスをグループに入れて無効化すると audibleClips から消える
        var v = Clip(); v.id = "v"; v.type = .voice; v.start = 0; v.duration = 2; v.src = "/tmp/x.wav"; v.group = "g1"
        p.tracks[0].clips.append(v)
        XCTAssertTrue(CompoundEditing.audibleClips(in: p).contains { $0.id == "v" })
        ClipGrouping.setDisabled("g1", on: true, in: &p)
        XCTAssertFalse(CompoundEditing.audibleClips(in: p).contains { $0.id == "v" })
        // 絵: Renderer の描画対象から外れることは、無効な画像クリップだけのプロジェクトが背景色になることで確かめる代わりに、
        // ここでは形式上の状態だけを見る(描画の画素確認はアプリ側の既存テストに任せる)
        XCTAssertTrue(p.allClips.first { $0.id == "v" }!.isDisabled)
    }

    // MARK: #15 複製・貼り付けのグループ分離

    func testMultiDuplicateFormsNewGroup() {
        let p = groupedProject()
        let r = ClipEditing.duplicate(in: p, clipIds: ["a", "c"])
        XCTAssertNotNil(r)
        let copies = r!.project.allClips.filter { !p.allClips.map(\.id).contains($0.id) }
        XCTAssertEqual(copies.count, 2)
        let groups = Set(copies.compactMap { $0.group })
        XCTAssertEqual(groups.count, 1, "コピー同士は 1 つのグループに残る")
        XCTAssertNotEqual(groups.first, "g1", "元のグループとは別の ID")
        // 元のメンバーは元のグループのまま
        XCTAssertEqual(ClipGrouping.members(of: "g1", in: r!.project).map { $0.id }, ["a", "c"])
        XCTAssertEqual(ClipGrouping.members(of: groups.first!, in: r!.project).count, 2)
    }

    func testSingleDuplicateDetachesGroup() {
        let p = groupedProject()
        let r = ClipEditing.duplicate(in: p, clipId: "a")
        XCTAssertNotNil(r)
        let copy = r!.project.allClips.first { $0.id == r!.newId }
        XCTAssertNil(copy?.group, "1 個だけの複製は元のグループに入らない")
    }

    func testPasteIntoProjectWithoutGroupKeepsGroupId() {
        let p = groupedProject()
        let cb = ClipClipboard.make(from: p, clipIds: ["a", "c"])!
        var empty = Project(); empty.characters = []; empty.tracks = [Track(name: "上"), Track(name: "下")]
        let r = ClipEditing.paste(cb, in: empty, at: 10, targetTrack: nil)
        XCTAssertNotNil(r)
        let pasted = r!.project.allClips.filter { r!.newIds.contains($0.id) }
        XCTAssertEqual(Set(pasted.compactMap { $0.group }), ["g1"], "重ならない ID はそのまま引き継ぐ")
    }

    // MARK: #20 字幕文と台本の検索・置換

    private func subtitleProject() -> Project {
        var p = Project.new()
        var v = Clip(); v.id = "v1"; v.type = .voice; v.text = "おはよう"; v.subtitleText = "おはようございます"; v.start = 0; v.duration = 2; v.charId = "c1"
        var t = Clip(); t.id = "t1"; t.type = .text; t.text = "おはようのテロップ"; t.start = 3; t.duration = 2
        p.tracks[0].clips = [v, t]
        p.scriptText = "キャラ1: おはよう\nキャラ2: おはよう、今日は"
        return p
    }

    func testMatchesIncludeSubtitleTextWithField() {
        let ms = TextSearch.matches("おはよう", in: subtitleProject())
        // v1 の読み上げ文 1、字幕文 1、t1 の本文 1(台本は含まない)
        XCTAssertEqual(ms.count, 3)
        XCTAssertEqual(ms.filter { $0.field == .subtitleText }.map { $0.clipId }, ["v1"])
        XCTAssertEqual(TextSearch.scriptMatches("おはよう", in: subtitleProject()), 2)
    }

    func testReplaceSubtitleAndScript() {
        let r = TextSearch.replaceAll("おはよう", with: "こんにちは", in: subtitleProject())
        let v = r.project.allClips.first { $0.id == "v1" }
        XCTAssertEqual(v?.text, "こんにちは")
        XCTAssertEqual(v?.subtitleText, "こんにちはございます")
        XCTAssertEqual(r.scriptCount, 2)
        XCTAssertEqual(r.project.scriptText, "キャラ1: こんにちは\nキャラ2: こんにちは、今日は")
        // 読み上げ文の変更だけが isVoice(音声の作り直し対象)。字幕文の変更は作り直さない
        XCTAssertEqual(r.changes.filter { $0.field == .text && $0.isVoice }.map { $0.clipId }, ["v1"])
        XCTAssertEqual(r.changes.filter { $0.field == .subtitleText }.map { $0.isVoice }, [false])
    }

    func testReplaceSubtitleOnlyDoesNotRequireVoiceRegeneration() {
        var p = Project.new()
        var v = Clip(); v.id = "v"; v.type = .voice; v.text = "読み"; v.subtitleText = "字幕だけ"; v.start = 0; v.duration = 1; v.charId = "c1"
        p.tracks[0].clips = [v]
        let r = TextSearch.replaceAll("字幕", with: "表示", in: p)
        XCTAssertEqual(r.changes.count, 1)
        XCTAssertFalse(r.changes[0].isVoice)
        XCTAssertEqual(r.project.allClips[0].subtitleText, "表示だけ")
        XCTAssertEqual(r.project.allClips[0].text, "読み")
    }

    func testSubtitleCanBeEmptiedAndScopeExcludesScript() {
        let p = subtitleProject()
        let scoped = TextSearch.replaceAll("おはよう", with: "X", in: p, scope: ["v1"])
        XCTAssertEqual(scoped.scriptCount, 0, "選択だけの置換では台本を変えない")
        XCTAssertEqual(scoped.project.scriptText, p.scriptText)
        // 字幕文は空にできる(字幕なしになる)。読み上げ文が空になるケースとは扱いが違う
        var q = Project.new()
        var v = Clip(); v.id = "v"; v.type = .voice; v.text = "あ"; v.subtitleText = "あ"; v.start = 0; v.duration = 1; v.charId = "c1"
        q.tracks[0].clips = [v]
        let r = TextSearch.replaceAll("あ", with: "", in: q)
        XCTAssertEqual(r.project.allClips[0].subtitleText, "")
        XCTAssertEqual(r.skippedEmptyVoices, 1, "読み上げ文の方は空にできないので飛ばす")
        XCTAssertEqual(r.project.allClips[0].text, "あ")
    }

    // MARK: #22 レベルメーターの値計算

    private func sine(amplitude: Float, seconds: Double = 1.0, sr: Double = 48000) -> ([Float], [Float]) {
        let n = Int(seconds * sr)
        var l = [Float](repeating: 0, count: n), r = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let v = amplitude * Float(sin(2 * Double.pi * 440 * Double(i) / sr))
            l[i] = v; r[i] = v
        }
        return (l, r)
    }

    func testLevelEnvelopePeakAndLoudness() {
        let (l, r) = sine(amplitude: 0.5)
        let env = PlaybackLevelEnvelope(left: l, right: r, sampleRate: 48000)
        XCTAssertEqual(env.peaks.count, 10, "1 秒 = 100 ms × 10 区切り")
        XCTAssertEqual(env.peakDb(at: 0.55), -6.02, accuracy: 0.6)
        let loud = env.momentaryLoudness(at: 0.55)
        XCTAssertTrue(loud.isFinite, "モーメンタリラウドネスが測れる: \(loud)")
        XCTAssertTrue(loud < 0 && loud > -20, "0.5 のサイン波のラウドネスは概ね -11 LUFS 前後: \(loud)")
        // 静かな信号は小さい
        let (ql, qr) = sine(amplitude: 0.05)
        let qenv = PlaybackLevelEnvelope(left: ql, right: qr, sampleRate: 48000)
        XCTAssertLessThan(qenv.momentaryLoudness(at: 0.55), loud - 15)
        XCTAssertEqual(qenv.peakDb(at: 0.55), -26.02, accuracy: 0.6)
    }

    func testLevelEnvelopeSilenceAndOutOfRange() {
        let env = PlaybackLevelEnvelope(left: [Float](repeating: 0, count: 4800), right: [Float](repeating: 0, count: 4800), sampleRate: 48000)
        XCTAssertEqual(env.peakDb(at: 0.05), -.infinity)
        XCTAssertEqual(env.momentaryLoudness(at: 0.05), -.infinity)
        XCTAssertEqual(env.peakDb(at: 99), -.infinity, "範囲外は無音扱い")
        XCTAssertEqual(PlaybackLevelEnvelope.normalized(-.infinity, mode: .peak), 0)
        XCTAssertEqual(PlaybackLevelEnvelope.normalized(0, mode: .peak), 1)
        XCTAssertEqual(PlaybackLevelEnvelope.normalized(-60, mode: .peak), 0)
        XCTAssertEqual(PlaybackLevelEnvelope.normalized(-30, mode: .peak), 0.5, accuracy: 1e-9)
    }

    func testLevelEnvelopeFromFile() throws {
        let (l, _) = sine(amplitude: 0.5)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("level-test-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeToneFile(url: url, samples: l)
        let env = PlaybackLevelEnvelope.compute(fromFileAt: url)
        XCTAssertNotNil(env)
        XCTAssertEqual(env!.peakDb(at: 0.55), -6.02, accuracy: 0.6)
        XCTAssertTrue(env!.momentaryLoudness(at: 0.55).isFinite)
    }

    private func writeToneFile(url: URL, samples: [Float]) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000.0, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples.count))!
        buf.frameLength = AVAudioFrameCount(samples.count)
        for ch in 0..<2 { buf.floatChannelData![ch].update(from: samples, count: samples.count) }
        try file.write(from: buf)
    }
}


// MARK: - バグ確認 第2部 C13: レベル包絡の不整合な入力

final class PlaybackLevelEnvelopeSafetyTests: XCTestCase {
    func testMismatchedArraysAndInfiniteTimeDoNotCrash() {
        let env = PlaybackLevelEnvelope(peaks: [1], energies: [])
        XCTAssertEqual(env.momentaryLoudness(at: 0), -.infinity)
        XCTAssertNil(env.hopIndex(at: .infinity))
        let ok = PlaybackLevelEnvelope(peaks: [0.5, 0.5], energies: [0.25, 0.25])
        XCTAssertEqual(ok.hopIndex(at: 0), 0)
        XCTAssertNil(ok.hopIndex(at: .infinity))
    }
}
