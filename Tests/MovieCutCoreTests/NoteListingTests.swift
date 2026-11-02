import XCTest
@testable import MovieCutCore

final class NoteListingTests: XCTestCase {
    private func project() -> Project {
        var a = Clip(); a.id = "a"; a.type = .text; a.start = 2; a.duration = 1; a.note = "直す, 後で"
        var b = Clip(); b.id = "b"; b.type = .text; b.start = 0; b.duration = 1
        var c = Clip(); c.id = "c"; c.type = .text; c.start = 1; c.duration = 1; c.note = "先頭\"引用\""
        var top = Track(name: "上"); top.clips = [a, b]
        var low = Track(name: "下"); low.clips = [c]
        var p = Project(); p.tracks = [top, low]
        return p
    }

    func testOnlyClipsWithNotesInStartOrder() {
        let e = NoteListing.entries(in: project())
        XCTAssertEqual(e.map(\.clipId), ["c", "a"], "注記のないクリップは出さない・開始時刻順")
        XCTAssertEqual(e[0].trackName, "下")
    }

    func testTextIsOneLinePerNote() {
        XCTAssertEqual(NoteListing.text(NoteListing.entries(in: project())), "1.000 秒 [下] 先頭\"引用\"\n2.000 秒 [上] 直す, 後で\n")
        XCTAssertEqual(NoteListing.text([]), "")
    }

    func testCSVQuotesAndKeepsBOM() {
        let csv = NoteListing.csv(NoteListing.entries(in: project()))
        XCTAssertTrue(csv.hasPrefix("\u{FEFF}レイヤー,開始(秒),注記\r\n"))
        XCTAssertTrue(csv.contains("下,1.000,\"先頭\"\"引用\"\"\"\r\n"))
        XCTAssertTrue(csv.contains("上,2.000,\"直す, 後で\"\r\n"))
    }
}
