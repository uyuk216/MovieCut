import XCTest
import AppKit
import MovieCutCore
@testable import MovieCut

/// 自動ホワイトバランス: メニューの項目表・無効の理由・ショートカットなし、モデルの操作(1 回の Undo、何も変わらなければ履歴に載せない)。
@MainActor
final class AutoWhiteBalanceAppTests: XCTestCase {
    private func tmpPNG(_ r: Int, _ g: Int, _ b: Int) throws -> String {
        let size = 40
        let c = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1))
        c.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("awb-app-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("c.png")
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, c.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url.path
    }

    private func makeModel(rgb: (Int, Int, Int)) throws -> ProjectModel {
        var img = Clip(); img.id = "a"; img.type = .image; img.src = try tmpPNG(rgb.0, rgb.1, rgb.2); img.start = 0; img.duration = 4; img.scale = 4
        var txt = Clip(); txt.id = "t"; txt.type = .text; txt.text = "x"; txt.start = 5; txt.duration = 2
        var p = Project.new(); p.fps = 30
        p.tracks[0].clips = [img, txt]
        let m = ProjectModel(project: p)
        m.notices = OneTimeNotices()
        return m
    }

    private func settle(_ m: ProjectModel, until: () -> Bool) async {
        for _ in 0..<200 where !until() { try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    func testMenuItemEnabledOnlyForImageOrVideoAndHasReasonAndNoShortcut() {
        var s = MenuState()
        s.hasDocument = true
        XCTAssertFalse(AppMenuSpec.autoWhiteBalanceItem(s).enabled)
        XCTAssertEqual(AppMenuSpec.disabledReason(for: AppMenuSpec.autoWhiteBalanceItem(s), state: s), "画像か動画のクリップを選んでください")
        s.canAutoColor = true
        let it = AppMenuSpec.autoWhiteBalanceItem(s)
        XCTAssertTrue(it.enabled); XCTAssertNil(it.shortcut); XCTAssertEqual(it.command, .autoWhiteBalance)
        XCTAssertNil(AppMenuSpec.disabledReason(for: it, state: s))
        XCTAssertTrue(AppMenuSpec.all(s).contains { $0.command == .autoWhiteBalance })
        var locked = s; locked.isLocked = true
        XCTAssertFalse(AppMenuSpec.autoWhiteBalanceItem(locked).enabled)
    }

    func testMenuStateFlagFollowsSelection() throws {
        let m = try makeModel(rgb: (150, 128, 108))
        m.selectedClipId = "a"
        XCTAssertTrue(MenuState(model: m).canAutoColor)
        m.selectedClipId = "t"
        XCTAssertFalse(MenuState(model: m).canAutoColor, "文字クリップは対象外")
        m.selectedClipId = nil
        XCTAssertFalse(MenuState(model: m).canAutoColor)
    }

    func testPerformAddsWhiteBalanceInOneUndoStep() async throws {
        let m = try makeModel(rgb: (150, 128, 108))
        m.selectedClipId = "a"; m.currentTime = 1
        let u = m.effectiveUndoManager
        AppMenu.perform(.autoWhiteBalance, model: m)
        await settle(m) { !(m.clip("a")?.effects.isEmpty ?? true) }
        let fx = try XCTUnwrap(m.clip("a")?.effects.first)
        XCTAssertEqual(fx.kind, "whiteBalance")
        XCTAssertLessThan(fx.value("temperature"), -0.3, "暖色かぶりは色温度 − で直す")
        XCTAssertEqual(u.undoActionName, ProjectModel.autoWhiteBalanceUndoName)
        var n = 0
        while u.canUndo { u.undo(); n += 1 }
        XCTAssertEqual(n, 1)
        XCTAssertTrue(m.clip("a")!.effects.isEmpty)
        // 2 回目(やり直し後)も同じ値
        u.redo()
        XCTAssertEqual(m.clip("a")!.effects.count, 1)
    }

    func testNeutralImageChangesNothingAndRegistersNoUndo() async throws {
        let m = try makeModel(rgb: (128, 128, 128))
        m.selectedClipId = "a"; m.currentTime = 1
        let u = m.effectiveUndoManager
        AppMenu.perform(.autoWhiteBalance, model: m)
        await settle(m) { m.statusText.contains("灰色") }
        XCTAssertTrue(m.clip("a")!.effects.isEmpty)
        XCTAssertFalse(u.canUndo)
        XCTAssertTrue(m.statusText.contains("すでにほぼ灰色"))
    }

    func testRunningAgainOnTheCorrectedClipDoesNotStackEffects() async throws {
        let m = try makeModel(rgb: (150, 128, 108))
        m.selectedClipId = "a"; m.currentTime = 1
        AppMenu.perform(.autoWhiteBalance, model: m)
        await settle(m) { !(m.clip("a")?.effects.isEmpty ?? true) }
        let first = m.clip("a")!.effects
        AppMenu.perform(.autoWhiteBalance, model: m)
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(m.clip("a")!.effects, first, "測るときはエフェクトを外すので、同じ値になり、重ならない")
    }
}
