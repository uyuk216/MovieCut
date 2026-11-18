import XCTest
import AVFoundation
import MovieCutCore
@testable import MovieCut

/// 第3波バッチJ のアプリ側: グループの有効/無効と複合化(#15)、検索・置換の字幕文・台本(#20)、
/// ショートカット実装済みの確認(#21)、再生レベルメーターの配線(#22)。
@MainActor
final class EditSupportAppTests: XCTestCase {

    // MARK: #15 グループの有効/無効(モデル経由・Undo 1 回)

    private func makeGroupedModel() -> ProjectModel {
        let m = ProjectModel(project: .new())
        var a = Clip(); a.id = "a"; a.type = .image; a.start = 0; a.duration = 2
        var b = Clip(); b.id = "b"; b.type = .image; b.start = 3; b.duration = 2
        var c = Clip(); c.id = "c"; c.type = .text; c.start = 1; c.duration = 2
        m.project.tracks[0].clips = [a, b]
        if m.project.tracks.count < 2 { m.project.tracks.append(Track(name: "下")) }
        m.project.tracks[1].clips = [c]
        m.setSelection(ClipSelection(ids: ["a", "c"], primary: "a"))
        XCTAssertTrue(m.groupSelectedClips())
        return m
    }

    private func undoCount(_ m: ProjectModel) -> Int {
        let u = m.effectiveUndoManager
        var n = 0
        while u.canUndo { u.undo(); n += 1 }
        for _ in 0..<n { u.redo() }
        return n
    }

    func testToggleGroupDisabledIsOneUndoAndFollowsGroup() {
        let m = makeGroupedModel()
        let before = undoCount(m)
        m.selectOnly("a")   // グループの 1 個だけ選んでも全員が対象
        XCTAssertTrue(m.toggleGroupDisabledSelected())
        XCTAssertTrue(m.clip("a")?.isDisabled ?? false)
        XCTAssertTrue(m.clip("c")?.isDisabled ?? false, "レイヤーをまたいで全員が無効になる")
        XCTAssertFalse(m.clip("b")?.isDisabled ?? true, "グループ外は変えない")
        XCTAssertTrue(m.selectionGroupAllDisabled)
        XCTAssertEqual(undoCount(m), before + 1, "まとめて 1 回の Undo")
        // もう一度で有効に戻る
        XCTAssertTrue(m.toggleGroupDisabledSelected())
        XCTAssertFalse(m.clip("a")?.isDisabled ?? true)
        XCTAssertFalse(m.clip("c")?.isDisabled ?? true)
    }

    func testGroupMenuSpecs() {
        let m = makeGroupedModel()
        let s = MenuState(model: m)
        let items = AppMenuSpec.clipEdit(s)
        let group = items.first { $0.command == .groupClips }
        XCTAssertNotNil(group)
        XCTAssertTrue(items.contains { $0.command == .ungroupClips && $0.enabled })
        XCTAssertTrue(items.contains { $0.command == .groupToCompound && $0.enabled })
        XCTAssertEqual(AppMenuSpec.groupDisabledItem(s).title, "グループを無効にする")
        m.selectOnly("a")
        XCTAssertTrue(m.toggleGroupDisabledSelected())
        let s2 = MenuState(model: m)
        XCTAssertEqual(AppMenuSpec.groupDisabledItem(s2).title, "グループを有効にする", "全員が無効ならラベルが有効化に変わる")
        // グループの無いプロジェクトでは無効
        let plain = ProjectModel(project: Project.new())
        let s3 = MenuState(model: plain)
        XCTAssertFalse(AppMenuSpec.clipEdit(s3).first { $0.command == .ungroupClips }?.enabled ?? true)
        XCTAssertTrue(AppMenuSpec.all(s3).contains { $0.command == .groupClips }, "到達可能性(メニューに実在する)")
    }

    func testCompoundSelectedGroupCompositesGroupMembers() {
        let m = makeGroupedModel()
        m.selectOnly("c")
        XCTAssertTrue(m.compoundSelectedGroup(), "グループの 1 個を選ぶだけで全員が複合化される")
        let compounds = m.project.allClips.filter { $0.type == .compound }
        XCTAssertEqual(compounds.count, 1)
        XCTAssertEqual(compounds.first?.tracks?.flatMap { $0.clips }.count, 2, "中身はグループの 2 個")
        XCTAssertEqual(m.project.allClips.count, 2, "残りは b と複合クリップ")
        m.effectiveUndoManager.undo()
        XCTAssertEqual(m.project.allClips.count, 3, "Undo で元に戻る")
        XCTAssertEqual(m.clip("a")?.group, "group1")
    }

    // MARK: #20 字幕文・台本の置換(モデル経由)

    func testReplaceSubtitleAndScriptThroughModelIsOneUndoWithoutRegeneratingVoice() async {
        var p = Project.new()
        let charId = p.characters[0].id
        var v = Clip(); v.id = "v1"; v.type = .voice; v.text = "読みの文"; v.subtitleText = "字幕の文です"; v.start = 0; v.duration = 2; v.charId = charId; v.src = "/tmp/none.wav"
        p.tracks[0].clips = [v]
        p.scriptText = "キャラ1: 字幕の文を台本にも"
        let m = ProjectModel(project: p)
        m.notices = OneTimeNotices()
        m.voiceProviderFactory = { _ in ToneVoiceProvider(durations: [1.0], frequencies: [330]) }
        let before = m.project
        // 字幕文に 1 件 + 台本に 1 件(読み上げ文には一致なし)
        XCTAssertEqual(m.findTextMatchCount("字幕の文", selectionOnly: false, options: TextSearch.Options()), 2)
        let n = await m.replaceAllText("字幕の文", with: "差し替え", options: TextSearch.Options(), selectionOnly: false)
        XCTAssertEqual(n, 2)
        XCTAssertEqual(m.project.allClips.first { $0.id == "v1" }?.subtitleText, "差し替えです")
        XCTAssertEqual(m.project.scriptText, "キャラ1: 差し替えを台本にも")
        XCTAssertEqual(m.project.allClips.first { $0.id == "v1" }?.src, "/tmp/none.wav", "字幕文だけの変更では音声を作り直さない")
        XCTAssertEqual(undoCount(m), 1)
        m.effectiveUndoManager.undo()
        XCTAssertEqual(m.project, before)
    }

    // MARK: #21 ショートカットカスタマイズは実装済み(証拠の固定)

    func testShortcutCustomizationIsWired() {
        // 保存先(ShortcutStore)・変更画面(ShortcutSheet)・実効マップ(KeyRouter)の 3 点が揃っていることを固定する
        let suite = "edit-support-shortcut-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ShortcutStore(defaults: defaults)
        store.setPlainOverride(.init(keyCode: 7, display: "X"), for: .split)
        XCTAssertEqual(KeyRouter.effectiveKeyMap(store: store)[7], .split)
        XCTAssertTrue(ShortcutList.plainKeyDefs.contains { $0.command == .split })
        XCTAssertGreaterThan(ShortcutList.menuRows().count, 20, "メニュー項目のショートカットも一覧・変更の対象")
    }

    // MARK: #22 再生レベルメーターの配線

    func testPlaybackLevelEnvelopeIsPreparedFromMix() async throws {
        var p = Project.new()
        var c = Clip(); c.type = .voice; c.src = "/tmp/a.wav"; c.start = 0; c.duration = 5
        p.tracks[0].clips = [c]
        let m = ProjectModel(project: p)
        let backend = FakeBackend(), clock = FakeClock()
        let controller = PlaybackController(model: m, backend: backend, clock: clock, debounce: 0, mixer: { _, url in
            try Self.writeTone(to: url, amplitude: 0.5, seconds: 2)
            return 5
        })
        controller.timerFallback = false
        m.playback = controller
        controller.play()
        await controller.preparation?.value
        let env = try XCTUnwrap(controller.levelEnvelope, "ミックスの用意と一緒にレベルが測られる")
        XCTAssertEqual(env.peakDb(at: 0.55), -6.02, accuracy: 0.6)
        XCTAssertTrue(env.momentaryLoudness(at: 0.55).isFinite)
    }

    /// 48 kHz ステレオ CAF のトーンを書く(ミックスの代わり)。
    static func writeTone(to url: URL, amplitude: Float, seconds: Double) throws {
        let sr = 48000.0
        // AudioMixer の書き出しと同じ設定(48 kHz / Float32 / 非インターリーブ)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sr, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let n = Int(seconds * sr)
        let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(n))!
        buf.frameLength = AVAudioFrameCount(n)
        for i in 0..<n {
            let v = amplitude * Float(sin(2 * Double.pi * 440 * Double(i) / sr))
            buf.floatChannelData![0][i] = v
            buf.floatChannelData![1][i] = v
        }
        try file.write(from: buf)
    }
}
