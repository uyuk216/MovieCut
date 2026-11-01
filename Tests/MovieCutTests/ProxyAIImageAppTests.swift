import XCTest
import AppKit
import MovieCutCore
@testable import MovieCut

/// プロキシ(表示のチェック・出力の作成の有効)と、クリップ ▸ AIで画像を作る(確認・画像クリップ・Undo 1 回)。
@MainActor
final class ProxyAIImageAppTests: XCTestCase {
    private var scratch: URL!
    private var savedProxy = false

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("proxy-app-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        savedProxy = ProxySettings.enabled()
    }

    override func tearDownWithError() throws {
        ProxySettings.set(savedProxy)
        try? FileManager.default.removeItem(at: scratch)
    }

    private func undoSteps(_ m: ProjectModel) -> Int {
        let u = m.effectiveUndoManager
        var n = 0
        while u.canUndo { u.undo(); n += 1 }
        for _ in 0..<n { u.redo() }
        return n
    }

    func testProxyToggleMenuShowsCheckmarkFromSetting() {
        ProxySettings.set(false)
        XCTAssertEqual(AppMenuSpec.previewProxy(MenuState(model: nil)).checked, false)
        ProxySettings.set(true)
        XCTAssertEqual(AppMenuSpec.previewProxy(MenuState(model: nil)).checked, true)
        XCTAssertEqual(AppMenuSpec.previewProxy(MenuState(model: nil)).command, .previewProxyToggle)
        XCTAssertNil(AppMenuSpec.previewProxy(MenuState(model: nil)).shortcut, "ショートカットは持たない")
    }

    func testMakeProxiesNeedsAVideoClip() throws {
        let m = ProjectModel(project: .new())
        XCTAssertFalse(MenuState(model: m).canMakeProxies)
        XCTAssertFalse(AppMenuSpec.makeProxies(MenuState(model: m)).enabled)
        XCTAssertNil(AppMenuSpec.makeProxies(MenuState()).shortcut)
    }

    func testAIImageAddsImageClipAtPlayheadWithOneUndo() async throws {
        // 無害なコマンド: 標準入力を捨てて、用意した PNG を出力先へコピーするだけ
        let src = scratch.appendingPathComponent("made.png")
        try XCTUnwrap(QRCode.pngData(text: "ai-app-test")).write(to: src)
        let script = scratch.appendingPathComponent("gen.sh")
        try "#!/bin/sh\ncat > /dev/null\ncp '\(src.path)' \"$1\"\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let m = ProjectModel(project: .new())
        var shown: [(String, String)] = []
        m.aiUI.confirmSend = { d, p in shown.append((d, p)); return true }
        m.currentTime = 2
        let id = await m.generateAIImage(prompt: "夕焼けの海", commandLine: script.path)
        let clip = try XCTUnwrap(m.project.allClips.first { $0.id == id })
        XCTAssertEqual(clip.type, .image)
        XCTAssertEqual(clip.start, 2, accuracy: 1e-9)
        XCTAssertEqual(clip.duration, 5, accuracy: 1e-9)
        XCTAssertTrue(AIImageStore.isReadableImage(URL(fileURLWithPath: try XCTUnwrap(clip.src))))
        // 送る前に、送信先と内容を確認している
        XCTAssertEqual(shown.count, 1)
        XCTAssertEqual(shown.first?.1, "夕焼けの海")
        XCTAssertEqual(undoSteps(m), 1)
        XCTAssertNil(m.busyMessage)
    }

    func testDeclinedConfirmSendsNothingAndAddsNothing() async throws {
        let m = ProjectModel(project: .new())
        m.aiUI.confirmSend = { _, _ in false }
        let before = m.project.allClips.count
        let id = await m.generateAIImage(prompt: "送らない", commandLine: "/usr/bin/true")
        XCTAssertNil(id)
        XCTAssertEqual(m.project.allClips.count, before)
        XCTAssertEqual(m.statusText, "AI には送りませんでした")
    }

    func testEmptyPromptAndMissingCommandAreRefusedWithoutSending() async throws {
        let m = ProjectModel(project: .new())
        var asked = 0
        m.aiUI.confirmSend = { _, _ in asked += 1; return true }
        let blank = await m.generateAIImage(prompt: "  ", commandLine: "/usr/bin/true")
        let missing = await m.generateAIImage(prompt: "絵", commandLine: "/no/such/tool-xyz")
        XCTAssertNil(blank)
        XCTAssertNil(missing)
        XCTAssertEqual(asked, 0, "確認の前に止める")
        XCTAssertEqual(m.errorTitle, "AI で画像を作れません")
    }
}
