import XCTest
import AppKit
import AVFoundation
import YukkuriCore
@testable import YukkuriEditor

/// 失敗する VoiceProvider(音声の作り直しに失敗したとき、古い音声が残ることの確認用)。
final class FailingVoiceProvider: VoiceProvider {
    struct Boom: LocalizedError { var errorDescription: String? { "テスト用の失敗" } }
    func synthesize(character: Character, text: String, in directory: URL) async throws -> VoiceResult { throw Boom() }
}

/// 偽 VOICEVOX(話者一覧の URLProtocol スタブ)。
final class SpeakersStub: URLProtocol {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var requests = 0
    static func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [SpeakersStub.self]
        return URLSession(configuration: c)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        let resp = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class InspectorModelTests: XCTestCase {
    var tone: ToneVoiceProvider!

    private func makeModel() -> ProjectModel {
        let m = ProjectModel(project: .new())
        tone = ToneVoiceProvider(durations: [1.0, 2.5], frequencies: [220, 330])
        let t = tone!
        m.voiceProviderFactory = { _ in t }
        return m
    }

    /// 音声クリップ入りのモデル(Undo の履歴は空)。
    private func modelWithVoices() async -> (ProjectModel, String, String) {
        let m = makeModel()
        let reimu = m.project.characters[0], marisa = m.project.characters[1]
        var p = m.project
        let r = try! await tone.synthesize(character: reimu, text: "あ", in: FileManager.default.temporaryDirectory)
        for (i, ch) in [reimu, marisa, reimu].enumerated() {
            var c = Clip(); c.id = "v\(i)"; c.type = .voice; c.charId = ch.id; c.text = "セリフ\(i)"
            c.src = r.url.path; c.duration = r.duration + 0.15; c.offset = 0.3; c.start = Double(i) * 3; c.volume = 1; c.subtitle = true
            p.tracks[0].clips.append(c)
        }
        m.project = p
        return (m, reimu.id, marisa.id)
    }

    private func undoAll(_ m: ProjectModel) -> Int {
        var n = 0
        while m.effectiveUndoManager.canUndo { m.effectiveUndoManager.undo(); n += 1 }
        return n
    }

    // MARK: 項目の書き換え

    func testClipSettersClampAndNoOpRegistersNothing() {
        let m = makeModel()
        var c = Clip(); c.id = "i"; c.type = .image; c.start = 2; c.duration = 3
        m.project.tracks[0].clips = [c]
        m.selectedClipId = "i"
        m.setClipStart(-5); XCTAssertEqual(m.clip("i")?.start, 0)
        m.setClipDuration(0); XCTAssertEqual(m.clip("i")?.duration, 0.05)
        m.setClipDuration(1.23456); XCTAssertEqual(m.clip("i")?.duration, 1.235)
        m.setClipField(.x, 9); XCTAssertEqual(m.clip("i")?.x, 1)
        m.setClipField(.opacity, -1); XCTAssertEqual(m.clip("i")?.opacity, 0)
        m.setClipProperty(\.blur, to: 12, name: "ぼかし"); XCTAssertEqual(m.clip("i")?.blur, 12)
        let before = m.project
        let um = m.effectiveUndoManager
        m.setClipField(.opacity, 0)               // 同じ値 → 何も増えない
        m.setClipStart(0)
        XCTAssertEqual(m.project, before)
        XCTAssertEqual(undoAll(m), 6)             // 6 回の変更だけが履歴にある
        XCTAssertFalse(um.canUndo)
        XCTAssertEqual(m.clip("i")?.start, 2)
    }

    func testSliderGestureIsOneUndoStepWithLivePreview() {
        let m = makeModel()
        var c = Clip(); c.id = "i"; c.type = .image; c.opacity = 1
        m.project.tracks[0].clips = [c]
        m.selectedClipId = "i"
        m.beginGesture()
        m.liveClipField(.opacity, 0.8)
        XCTAssertEqual(m.clip("i")?.opacity, 0.8)        // ドラッグ中もすぐ反映(プレビューが追従する)
        m.liveClipField(.opacity, 0.5)
        m.liveClipField(.opacity, 0.25)
        XCTAssertFalse(m.effectiveUndoManager.canUndo)    // まだ履歴には積まない
        m.commitGesture(ClipField.opacity.undoName)
        XCTAssertEqual(m.clip("i")?.opacity, 0.25)
        XCTAssertEqual(undoAll(m), 1)                     // 1 回のドラッグ = 1 回の Undo
        XCTAssertEqual(m.clip("i")?.opacity, 1)
        // 動かして元の値に戻したら何も登録されない
        m.beginGesture(); m.liveClipField(.opacity, 0.4); m.liveClipField(.opacity, 1); m.commitGesture("x")
        XCTAssertFalse(m.effectiveUndoManager.canUndo)
        // ジェスチャなしで来た値(キーボード操作)は 1 回の編集
        m.liveClipField(.opacity, 0.9)
        XCTAssertEqual(undoAll(m), 1)
    }

    func testCoalescedEditIsOneUndoStep() {
        let m = makeModel()
        var c = Clip(); c.id = "t"; c.type = .text; c.text = "a"
        m.project.tracks[0].clips = [c]
        m.selectedClipId = "t"
        for s in ["ab", "abc", "abcd"] { m.coalescedClipProperty({ $0.text = s }, name: "文字の変更") }
        XCTAssertEqual(m.clip("t")?.text, "abcd")
        XCTAssertFalse(m.effectiveUndoManager.canUndo)
        m.flushCoalesced()
        XCTAssertEqual(undoAll(m), 1)
        XCTAssertEqual(m.clip("t")?.text, "a")
    }

    func testEngineSwitchViaModelIsUndoable() {
        let m = makeModel()
        let id = m.project.characters[0].id    // 霊夢: aquestalk / 100
        m.characterEngineChanged(charId: id, to: "voicevox")
        let c = m.character(id)!
        XCTAssertEqual(c.engine, "voicevox"); XCTAssertEqual(c.speed, 1); XCTAssertEqual(c.pitch, 0); XCTAssertEqual(c.intonation, 1); XCTAssertEqual(c.speaker, 3)
        m.characterEngineChanged(charId: id, to: "aquestalk")
        XCTAssertEqual(m.character(id)?.speed, 100)
        XCTAssertEqual(undoAll(m), 2)
        XCTAssertEqual(m.character(id)?.engine, "aquestalk")
        // 速さの範囲(エンジンごと)
        m.setCharacterField(.speed, 999, charId: id); XCTAssertEqual(m.character(id)?.speed, 300)
    }

    func testPortraitSetAndClear() {
        let m = makeModel()
        let id = m.project.characters[0].id
        m.setPortrait(charId: id, closed: true, url: URL(fileURLWithPath: "/tmp/a.png"))
        m.setPortrait(charId: id, closed: false, url: URL(fileURLWithPath: "/tmp/b.png"))
        XCTAssertEqual(m.character(id)?.imgClosed, "/tmp/a.png"); XCTAssertEqual(m.character(id)?.imgOpen, "/tmp/b.png")
        m.setPortrait(charId: id, closed: true, url: nil)
        XCTAssertNil(m.character(id)?.imgClosed)
        XCTAssertEqual(undoAll(m), 3)
    }

    // MARK: 選択

    func testSelectionModeSwitching() {
        let m = makeModel()
        XCTAssertEqual(m.inspectorMode, .none)
        var c = Clip(); c.id = "i"; c.type = .image
        m.project.tracks[0].clips = [c]
        m.selectedClipId = "i"
        XCTAssertEqual(m.inspectorMode, .clip("i"))
        let id = m.project.characters[1].id
        m.selectCharacter(id)                         // キャラを選ぶとクリップの選択は外れる
        XCTAssertNil(m.selectedClipId)
        XCTAssertEqual(m.inspectorMode, .character(id))
        m.selectedClipId = "i"                        // クリップを選ぶとキャラの表示を抜ける
        XCTAssertEqual(m.inspectorMode, .clip("i"))
        XCTAssertFalse(m.characterPanelActive)
        m.deleteSelected()                            // 選択を外すとヒント
        XCTAssertEqual(m.inspectorMode, .none)
        m.addCharacter()                              // 追加したキャラはそのまま設定が出る
        XCTAssertEqual(m.inspectorMode, .character(m.project.characters.last!.id))
    }

    // MARK: キャラの削除

    func testDeleteCharacterCascadeSelectionAndUndo() async {
        let (m, reimu, marisa) = await modelWithVoices()
        m.selectedClipId = "v0"
        m.selectCharacter(reimu)
        m.selectedClipId = "v0"
        let before = m.project
        XCTAssertTrue(m.deleteCharacter(reimu))
        XCTAssertEqual(m.project.characters.count, 2)
        XCTAssertEqual(m.project.allClips.map(\.id), ["v1"])           // 霊夢のセリフ(v0, v2)は消え、魔理沙のものは残る
        XCTAssertNil(m.selectedClipId)                                 // 消えたクリップの選択は外れる
        XCTAssertEqual(m.selectedCharId, m.project.characters.first?.id)
        XCTAssertNotEqual(m.selectedCharId, reimu)
        XCTAssertFalse(m.isPlaying)
        XCTAssertEqual(undoAll(m), 1)                                  // 1 回の Undo で、キャラもクリップも戻る
        XCTAssertEqual(m.project, before)
        XCTAssertEqual(m.character(marisa)?.name, "魔理沙")
    }

    func testCannotDeleteLastCharacter() {
        let m = makeModel()
        m.project.characters = [m.project.characters[0]]
        let id = m.project.characters[0].id
        XCTAssertFalse(m.deleteCharacter(id))
        XCTAssertEqual(m.project.characters.count, 1)
        m.requestDeleteCharacter(id)
        XCTAssertNil(m.pendingDeleteCharId)                   // 確認は出さず、理由を出す
        XCTAssertEqual(m.errorTitle, "このキャラは消せません")
        XCTAssertFalse(m.effectiveUndoManager.canUndo)
    }

    func testDeleteConfirmationMentionsLines() async {
        let (m, reimu, _) = await modelWithVoices()
        m.requestDeleteCharacter(reimu)
        XCTAssertEqual(m.pendingDeleteCharId, reimu)
        let conf = m.deleteConfirmation(for: reimu)!
        XCTAssertEqual(conf.title, "霊夢 を消しますか？")
        XCTAssertTrue(conf.message.contains("セリフ 2 個"))
    }

    // MARK: 音声の作り直し

    private func wavLength(_ path: String?) throws -> Double { try RealVoiceProvider.duration(of: URL(fileURLWithPath: try XCTUnwrap(path))) }

    func testChangingVoiceTextRegeneratesAudio() async throws {
        let (m, _, _) = await modelWithVoices()
        let before = m.clip("v0")!
        let ok = await m.setVoiceText("新しいセリフ", clipId: "v0")
        XCTAssertTrue(ok)
        let after = m.clip("v0")!
        XCTAssertEqual(after.text, "新しいセリフ")
        XCTAssertNotEqual(after.src, before.src)
        XCTAssertEqual(after.offset, 0)                                           // 前の切り詰めは引きずらない
        XCTAssertEqual(after.duration, try wavLength(after.src) + 0.15, accuracy: 0.002)
        XCTAssertNil(m.busyMessage)
        XCTAssertEqual(m.effectiveUndoManager.undoActionName, "セリフの変更")
        XCTAssertEqual(undoAll(m), 1)                                             // 文字と音声が 1 回の Undo で戻る
        XCTAssertEqual(m.clip("v0"), before)
    }

    func testChangingCharacterRegeneratesAndSameValueIsNoOp() async throws {
        let (m, reimu, marisa) = await modelWithVoices()
        let again = await m.setVoiceCharacter(reimu, clipId: "v0")         // すでに同じキャラ
        XCTAssertFalse(again)
        let sameText = await m.setVoiceText("セリフ0", clipId: "v0")
        XCTAssertFalse(sameText)
        XCTAssertFalse(m.effectiveUndoManager.canUndo)
        let ok = await m.setVoiceCharacter(marisa, clipId: "v0")
        XCTAssertTrue(ok)
        XCTAssertEqual(m.clip("v0")?.charId, marisa)
        XCTAssertEqual(m.clip("v0")?.offset, 0)
        XCTAssertEqual(m.clip("v0")?.duration ?? 0, try wavLength(m.clip("v0")?.src) + 0.15, accuracy: 0.002)
    }

    func testFailedRegenerationKeepsOldAudioAndAlerts() async {
        let (m, _, _) = await modelWithVoices()
        let before = m.project
        m.voiceProviderFactory = { _ in FailingVoiceProvider() }
        let ok = await m.setVoiceText("失敗するセリフ", clipId: "v0")
        XCTAssertFalse(ok)
        XCTAssertEqual(m.project, before)                      // 音声も文字もそのまま
        XCTAssertEqual(m.errorTitle, "音声を作れませんでした")
        XCTAssertEqual(m.errorMessage, "テスト用の失敗")
        XCTAssertNil(m.busyMessage)
        XCTAssertFalse(m.effectiveUndoManager.canUndo)
        let empty = await m.setVoiceText("  ", clipId: "v0")
        XCTAssertFalse(empty)
        XCTAssertEqual(m.errorTitle, "セリフを入れてください")
    }

    func testRegenerateAllVoicesIsOneUndoStep() async throws {
        let (m, reimu, _) = await modelWithVoices()
        let before = m.project
        let n = await m.regenerateAllVoices(charId: reimu)
        XCTAssertEqual(n, 2)                                    // 霊夢のセリフ(v0, v2)だけ
        for id in ["v0", "v2"] {
            let c = m.clip(id)!
            XCTAssertNotEqual(c.src, before.allClips.first { $0.id == id }?.src)
            XCTAssertEqual(c.offset, 0)
            XCTAssertEqual(c.duration, try wavLength(c.src) + 0.15, accuracy: 0.002)
        }
        XCTAssertEqual(m.clip("v1"), before.allClips.first { $0.id == "v1" })   // 他のキャラは触らない
        XCTAssertEqual(undoAll(m), 1)
        XCTAssertEqual(m.project, before)
        // 1 つ失敗したら全体を変えない
        m.voiceProviderFactory = { _ in FailingVoiceProvider() }
        let failed = await m.regenerateAllVoices(charId: reimu)
        XCTAssertEqual(failed, 0)
        XCTAssertEqual(m.project, before)
        XCTAssertFalse(m.effectiveUndoManager.canUndo)
    }

    func testTestSpeakUsesCharacterSettingsAndReportsErrors() async {
        let m = makeModel()
        var played: [URL] = []
        m.playTestAudio = { played.append($0) }
        let id = m.project.characters[2].id
        let url = await m.testSpeak(charId: id)
        XCTAssertNotNil(url)
        XCTAssertEqual(played, [url!])
        XCTAssertNil(m.busyMessage)
        XCTAssertFalse(m.effectiveUndoManager.canUndo)            // 読み上げは編集ではない
        m.voiceProviderFactory = { _ in FailingVoiceProvider() }
        let bad = await m.testSpeak(charId: id)
        XCTAssertNil(bad)
        XCTAssertEqual(m.errorTitle, "読み上げられませんでした")
    }

    // MARK: 話者一覧

    func testSpeakerCatalogParsesLabelsViaURLProtocolStub() async {
        SpeakersStub.status = 200; SpeakersStub.requests = 0
        SpeakersStub.body = Data(#"[{"name":"ずんだもん","styles":[{"id":3,"name":"ノーマル"},{"id":1,"name":"あまあま"}]},{"name":"四国めたん","styles":[{"id":2,"name":"ノーマル"}]}]"#.utf8)
        let session = SpeakersStub.session()
        let cat = SpeakerCatalog(ensureRunning: { _ in true }, fetch: { try await VoicevoxClient(baseURL: $0, session: session).speakers() })
        XCTAssertEqual(cat.state, .idle)
        await cat.load(baseURL: "http://127.0.0.1:50021")
        XCTAssertEqual(cat.state, .loaded)
        XCTAssertEqual(cat.label(for: 3), "ずんだもん（ノーマル）")
        XCTAssertEqual(cat.label(for: 1), "ずんだもん（あまあま）")
        XCTAssertNil(cat.label(for: 99))
        XCTAssertEqual(cat.choices.count, 3)
        await cat.load(baseURL: "http://127.0.0.1:50021")           // 一度だけ読む
        XCTAssertEqual(SpeakersStub.requests, 1)
    }

    func testSpeakerCatalogFallsBackWhenEngineUnavailable() async {
        SpeakersStub.status = 500; SpeakersStub.requests = 0; SpeakersStub.body = Data("{}".utf8)
        let session = SpeakersStub.session()
        let cat = SpeakerCatalog(ensureRunning: { _ in true }, fetch: { try await VoicevoxClient(baseURL: $0, session: session).speakers() })
        await cat.load(baseURL: "http://127.0.0.1:50021")
        XCTAssertEqual(cat.state, .unavailable)                    // HTTP エラー
        XCTAssertTrue(cat.choices.isEmpty); XCTAssertNil(cat.label(for: 3))
        // エンジンを起動できない
        let down = SpeakerCatalog(ensureRunning: { _ in false }, fetch: { _ in XCTFail("起動できないのに取りに行った"); return [] })
        await down.load(baseURL: "http://127.0.0.1:50021")
        XCTAssertEqual(down.state, .unavailable)
        // 直ったら次の読み込みで一覧になる
        SpeakersStub.status = 200
        SpeakersStub.body = Data(#"[{"name":"ずんだもん","styles":[{"id":3,"name":"ノーマル"}]}]"#.utf8)
        await cat.load(baseURL: "http://127.0.0.1:50021")
        XCTAssertEqual(cat.state, .loaded)
        XCTAssertEqual(cat.label(for: 3), "ずんだもん（ノーマル）")
    }

    // MARK: キー操作の分離(入力欄で S / Delete / Space が効かない)

    func testShortcutsAreIgnoredWhileTypingInRealTextFields() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        let field = NSTextField(frame: NSRect(x: 10, y: 150, width: 200, height: 24))
        let textView = NSTextView(frame: NSRect(x: 10, y: 10, width: 200, height: 100))
        let plain = NSView(frame: NSRect(x: 220, y: 10, width: 50, height: 50))
        win.contentView?.addSubview(field); win.contentView?.addSubview(textView); win.contentView?.addSubview(plain)

        let router = KeyRouter()
        var fired: [KeyCommand] = []
        for c in [KeyCommand.playPause, .split, .delete, .deselect, .stepBack, .toStart] { router.handlers[c] = { fired.append(c); return true } }
        let keys: [(UInt16, KeyCommand)] = [(49, .playPause), (1, .split), (51, .delete), (117, .delete), (53, .deselect), (123, .stepBack), (115, .toStart)]

        // NSTextField を編集中 → 実際のフィールドエディタ(NSTextView)が first responder になる
        XCTAssertTrue(win.makeFirstResponder(field))
        let editor = win.firstResponder
        XCTAssertTrue(editor is NSTextView, "フィールドエディタが first responder: \(String(describing: editor))")
        for (code, _) in keys { XCTAssertFalse(router.dispatch(keyCode: code, modifiers: [], firstResponder: win.firstResponder)) }
        // 複数行の NSTextView
        XCTAssertTrue(win.makeFirstResponder(textView))
        for (code, _) in keys { XCTAssertFalse(router.dispatch(keyCode: code, modifiers: [], firstResponder: win.firstResponder)) }
        XCTAssertTrue(fired.isEmpty)
        // 普通の View ならコマンドとして効く(対照)
        _ = win.makeFirstResponder(plain)
        for (code, cmd) in keys { XCTAssertTrue(router.dispatch(keyCode: code, modifiers: [], firstResponder: plain)); XCTAssertEqual(fired.last, cmd) }
        XCTAssertEqual(fired.count, keys.count)
        // モデルのルーターでも、入力欄では選択中のクリップが消えない
        let m = makeModel()
        var c = Clip(); c.id = "i"; c.type = .image
        m.project.tracks[0].clips = [c]; m.selectedClipId = "i"
        m.installKeyboard()
        defer { m.keyRouter.uninstall() }
        XCTAssertTrue(win.makeFirstResponder(field))
        XCTAssertFalse(m.keyRouter.dispatch(keyCode: 51, modifiers: [], firstResponder: win.firstResponder))
        XCTAssertFalse(m.keyRouter.dispatch(keyCode: 1, modifiers: [], firstResponder: win.firstResponder))
        XCTAssertEqual(m.selectedClipId, "i")
        XCTAssertEqual(m.project.allClips.count, 1)
    }
}
