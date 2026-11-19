import XCTest
import AppKit
import MovieCutCore
@testable import MovieCut

/// 生成メディア(API)の画面側: 未設定時の無効表示、確認 → 生成 → 画像クリップ
/// 配置(Undo 1 回)、確認を断ったら何もしない、未設定ならエラーを出す。
/// プロバイダは偽物に差し替え、実サービスへの通信はしない。
@MainActor
final class GenerativeMediaAppTests: XCTestCase {
    private var scratch: URL!
    private var savedSettings: ImageGenerationSettings!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("genmedia-app-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        savedSettings = ImageGenerationSettings.load()
    }

    override func tearDownWithError() throws {
        savedSettings.save()
        try? FileManager.default.removeItem(at: scratch)
    }

    private func undoSteps(_ m: ProjectModel) -> Int {
        let u = m.effectiveUndoManager
        var n = 0
        while u.canUndo { u.undo(); n += 1 }
        for _ in 0..<n { u.redo() }
        return n
    }

    private func configuredSettings() {
        var s = ImageGenerationSettings()
        s.endpoint = "http://127.0.0.1:8080/v1/images/generations"
        s.model = "local-model"
        s.save()
    }

    func testMenuItemDisabledWhenUnconfiguredAndEnabledWhenConfigured() {
        var s = ImageGenerationSettings()
        s.save()
        let m = ProjectModel(project: .new())
        XCTAssertFalse(m.imageGenerationConfigured)
        XCTAssertFalse(AppMenuSpec.generatedImageItem(MenuState(model: m)).enabled, "未設定のあいだは無効表示")
        XCTAssertEqual(AppMenuSpec.generatedImageItem(MenuState(model: m)).command, .generateImageAPI)
        XCTAssertNil(AppMenuSpec.generatedImageItem(MenuState(model: m)).shortcut, "ショートカットは持たない")
        configuredSettings()
        XCTAssertTrue(m.imageGenerationConfigured)
        XCTAssertTrue(AppMenuSpec.generatedImageItem(MenuState(model: m)).enabled)
        XCTAssertTrue(MenuState(model: m).imageGenerationConfigured)
    }

    func testSettingsMenuItemExists() {
        let spec = AppMenuSpec.imageGenerationSettingsItem(MenuState())
        XCTAssertEqual(spec.command, .imageGenerationSettings)
        XCTAssertEqual(spec.title, "生成メディア(API)の設定…")
    }

    func testGeneratePlacesImageClipWithOneUndoAfterConfirmation() async throws {
        configuredSettings()
        let png = try XCTUnwrap(QRCode.pngData(text: "genmedia-app-test"))
        let fake = FakeImageGenerationProvider(.succeed(png), outputDirectory: scratch)
        let m = ProjectModel(project: .new())
        m.genMediaUI.makeImageProvider = { fake }
        var shown: [(String, String)] = []
        m.genMediaUI.confirmSend = { d, s in shown.append((d, s)); return true }
        m.currentTime = 2
        let id = await m.generateImageViaAPI(prompt: "夕焼けの海")
        let clip = try XCTUnwrap(m.project.allClips.first { $0.id == id })
        XCTAssertEqual(clip.type, .image)
        XCTAssertEqual(clip.start, 2, accuracy: 1e-9)
        XCTAssertEqual(clip.duration, 5, accuracy: 1e-9)
        XCTAssertTrue(AIImageStore.isReadableImage(URL(fileURLWithPath: try XCTUnwrap(clip.src))))
        // 送る前に、送信先・プロンプト・費用の注意を確認している
        XCTAssertEqual(shown.count, 1)
        XCTAssertTrue(shown.first?.0.contains("local-model") ?? false)
        XCTAssertTrue(shown.first?.1.contains("夕焼けの海") ?? false)
        XCTAssertTrue(shown.first?.1.contains("課金されます") ?? false)
        XCTAssertEqual(fake.requests.count, 1)
        XCTAssertEqual(undoSteps(m), 1)
        XCTAssertNil(m.busyMessage)
        XCTAssertEqual(m.statusText, "生成した画像を追加しました")
    }

    func testDeclinedConfirmationGeneratesNothing() async throws {
        configuredSettings()
        let png = try XCTUnwrap(QRCode.pngData(text: "genmedia-declined"))
        let fake = FakeImageGenerationProvider(.succeed(png), outputDirectory: scratch)
        let m = ProjectModel(project: .new())
        m.genMediaUI.makeImageProvider = { fake }
        m.genMediaUI.confirmSend = { _, _ in false }
        let before = m.project.allClips.count
        let id = await m.generateImageViaAPI(prompt: "送らない")
        XCTAssertNil(id)
        XCTAssertEqual(m.project.allClips.count, before)
        XCTAssertEqual(fake.requests.count, 0, "確認を断ったら生成しない")
        XCTAssertEqual(m.statusText, "生成サービスには送りませんでした")
    }

    func testUnconfiguredShowsErrorAndAddsNothing() async throws {
        var s = ImageGenerationSettings()
        s.save()
        let m = ProjectModel(project: .new())
        var asked = 0
        m.genMediaUI.confirmSend = { _, _ in asked += 1; return true }
        let id = await m.generateImageViaAPI(prompt: "絵")
        XCTAssertNil(id)
        XCTAssertEqual(asked, 0, "未設定なら確認の前に止める")
        XCTAssertEqual(m.errorTitle, "生成メディア(API)を使えません")
        XCTAssertTrue(m.project.allClips.isEmpty)
    }

    func testEmptyPromptIsRefusedWithoutConfirmation() async throws {
        configuredSettings()
        let m = ProjectModel(project: .new())
        var asked = 0
        m.genMediaUI.confirmSend = { _, _ in asked += 1; return true }
        let id = await m.generateImageViaAPI(prompt: "  ")
        XCTAssertNil(id)
        XCTAssertEqual(asked, 0)
        XCTAssertEqual(m.statusText, "プロンプトを入れてください")
    }
}
