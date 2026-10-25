import XCTest
import AppKit
import UniformTypeIdentifiers
@testable import MovieCut

/// 新しい `.mcpjc` と、旧 `.ymproj`(読み込みだけ)、ウィンドウのタブ無効化。
final class DocumentTypeTests: XCTestCase {
    // 適合関係(ymproj → mcpjc → json)と拡張子は Info.plist(.app の中)が登録するので、
    // swift test では見えない。.app での確認は MC_DEBUG_DOCS で行う。
    func testTypeIdentifiers() {
        XCTAssertEqual(UTType.mcpjc.identifier, "jp.local.moviecut.project")
        XCTAssertEqual(UTType.ymproj.identifier, "jp.local.yukkuri-editor.project")
    }

    func testReadsBothButWritesOnlyTheNewType() {
        XCTAssertEqual(ProjectDocument.readableContentTypes, [.mcpjc, .ymproj])
        XCTAssertEqual(ProjectDocument.writableContentTypes, [.mcpjc])
        XCTAssertFalse(ProjectDocument.writableContentTypes.contains(.ymproj), "旧形式には書き戻さない")
    }

    func testTabbingIsDisabled() {
        AppWindowPolicy.disableTabbing()
        XCTAssertFalse(NSWindow.allowsAutomaticWindowTabbing)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled, .closable], backing: .buffered, defer: true)
        AppWindowPolicy.apply(to: w)
        XCTAssertEqual(w.tabbingMode, .disallowed)
    }
}
