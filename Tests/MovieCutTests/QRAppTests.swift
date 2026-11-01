import XCTest
import AppKit
import MovieCutCore
@testable import MovieCut

/// クリップ ▸ QRコードを追加…(画像クリップとして置く。Undo は 1 回)。
@MainActor
final class QRAppTests: XCTestCase {
    private func undoSteps(_ m: ProjectModel) -> Int { let u = m.effectiveUndoManager; var n = 0; while u.canUndo { u.undo(); n += 1 }; for _ in 0..<n { u.redo() }; return n }

    func testAddsImageClipAtPlayheadWithOneUndo() throws {
        let m = ProjectModel(project: .new())
        m.currentTime = 2
        let id = try XCTUnwrap(m.addQRCode(text: "https://example.com/qr-test"))
        let clip = try XCTUnwrap(m.project.allClips.first { $0.id == id })
        XCTAssertEqual(clip.type, .image)
        XCTAssertEqual(clip.start, 2, accuracy: 1e-9)
        XCTAssertEqual(clip.duration, 5, accuracy: 1e-9)
        let src = try XCTUnwrap(clip.src)
        XCTAssertTrue(FileManager.default.fileExists(atPath: src))
        let data = try Data(contentsOf: URL(fileURLWithPath: src))
        XCTAssertEqual(QRCode.readBack(pngData: data), "https://example.com/qr-test")
        XCTAssertEqual(undoSteps(m), 1)
    }

    func testSameTextUsesSameFileAndEmptyTextAddsNothing() {
        let a = QRCodeStore.imageURL(for: "same-text-check")
        let b = QRCodeStore.imageURL(for: "  same-text-check ")
        XCTAssertNotNil(a)
        XCTAssertEqual(a, b)
        XCTAssertNil(QRCode.pngData(text: ""))
        let m = ProjectModel(project: .new())
        XCTAssertNil(m.addQRCode(text: "   "))
        XCTAssertTrue(m.project.allClips.isEmpty)
    }

    func testMenuItemHasNoShortcutAndIsInClipAddGroup() {
        var s = MenuState(); s.hasDocument = true
        let spec = AppMenuSpec.addQRCode(s)
        XCTAssertEqual(spec.title, "QRコードを追加…")
        XCTAssertNil(spec.shortcut)
        XCTAssertTrue(spec.enabled)
        XCTAssertTrue(AppMenuSpec.clipAdd(s).contains { $0.command == .addQRCode })
    }
}
