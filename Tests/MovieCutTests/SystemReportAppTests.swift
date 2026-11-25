import XCTest
@testable import MovieCut

final class SystemReportAppTests: XCTestCase {
    /// ヘルプに「システムレポートを書き出す…」があり、書類がなくても使えて、ショートカットは持たない。
    func testSystemReportMenuItem() {
        let helpItems = AppMenuSpec.help.flatMap { $0 }
        let item = helpItems.first { $0.command == .systemReport }
        XCTAssertNotNil(item)
        XCTAssertEqual(item?.title, "システムレポートを書き出す…")
        XCTAssertNil(item?.shortcut)
        XCTAssertEqual(item?.enabled, true)

        var s = MenuState()
        s.hasDocument = false
        XCTAssertTrue(AppMenuSpec.all(s).contains { $0.command == .systemReport })
        s.hasDocument = true
        XCTAssertTrue(AppMenuSpec.all(s).contains { $0.command == .systemReport })
    }

    /// 既定のファイル名は「MovieCut-SystemReport-<yyyyMMdd-HHmm>.zip」の形。
    func testDefaultFileName() {
        let name = SystemReportExporter.defaultFileName(date: Date(timeIntervalSince1970: 1_764_000_000))
        XCTAssertTrue(name.hasPrefix("MovieCut-SystemReport-"))
        XCTAssertTrue(name.hasSuffix(".zip"))
        XCTAssertEqual(name.count, "MovieCut-SystemReport-20261125-0156.zip".count)
    }
}
