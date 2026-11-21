import XCTest
@testable import MovieCut

final class MenuDisabledReasonTests: XCTestCase {
    private func check(_ s: MenuState, file: StaticString = #filePath, line: UInt = #line) -> (enabled: Int, disabled: Int) {
        var e = 0, d = 0
        for spec in AppMenuSpec.all(s) {
            let r = AppMenuSpec.disabledReason(for: spec, state: s)
            if spec.enabled {
                e += 1
                XCTAssertNil(r, "\(spec.command) は有効なのに理由がある", file: file, line: line)
            } else {
                d += 1
                XCTAssertFalse((r ?? "").isEmpty, "\(spec.command) の理由が空", file: file, line: line)
            }
        }
        return (e, d)
    }

    func testNoDocumentEveryDisabledItemHasReason() {
        let s = MenuState()
        let n = check(s)
        XCTAssertGreaterThan(n.disabled, 50)
        let settings = AppMenuSpec.settings(s)
        XCTAssertTrue(settings.enabled, "設定… はアプリ設定なのでプロジェクト無しでも有効")
        XCTAssertNil(AppMenuSpec.disabledReason(for: settings, state: s), "有効なので無効理由は不要")
        // 理由の仕組み自体は健在: プロジェクトが必要な項目には従来どおりの理由が出る
        let vs = AppMenuSpec.videoSettings(s)
        XCTAssertEqual(AppMenuSpec.disabledReason(for: vs, state: s), "プロジェクトを開いてから使えます")
    }

    func testLockedReason() {
        var s = MenuState(); s.hasDocument = true; s.isLocked = true
        _ = check(s)
        XCTAssertEqual(AppMenuSpec.disabledReason(for: AppMenuSpec.videoSettings(s), state: s), "書き出し中・音声生成中は使えません")
    }

    func testDocumentWithoutSelectionReasons() {
        var s = MenuState(); s.hasDocument = true
        let n = check(s)
        XCTAssertGreaterThan(n.enabled, 0); XCTAssertGreaterThan(n.disabled, 20)
        let dup = AppMenuSpec.all(s).first { $0.command == .duplicate }!
        XCTAssertEqual(AppMenuSpec.disabledReason(for: dup, state: s), "クリップを選んでから実行します")
        s.hasSelection = true
        let dup2 = AppMenuSpec.all(s).first { $0.command == .duplicate }!
        XCTAssertNil(AppMenuSpec.disabledReason(for: dup2, state: s))
    }

    func testEnabledAboutHasNoReason() {
        XCTAssertNil(AppMenuSpec.disabledReason(for: AppMenuSpec.about, state: MenuState()))
    }
}
