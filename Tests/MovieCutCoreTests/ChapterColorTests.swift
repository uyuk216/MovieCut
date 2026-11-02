import XCTest
@testable import MovieCutCore

/// 色を選んでチャプターにする(`Chapters.make(from:color:)`)。
final class ChapterColorTests: XCTestCase {
    func marker(_ t: Double, _ name: String, _ color: String? = nil) -> Marker {
        var m = Marker(time: t, name: name); m.color = color; return m
    }

    var markers: [Marker] {
        [marker(0, "導入", "red"), marker(20, "余談"), marker(45, "本題1", "red"), marker(80, "メモ", "blue"),
         marker(120, "本題2", "red"), marker(150, "未知", "magenta")]
    }

    func testColorFilterKeepsOnlyThatColorInTimeOrder() {
        let r = Chapters.make(from: markers.reversed(), color: .red)
        XCTAssertEqual(r.text, "0:00 導入\n0:45 本題1\n2:00 本題2")
        XCTAssertEqual(r.count, 3)
        XCTAssertTrue(r.warnings.isEmpty)
    }

    func testNilColorIsAllMarkersAndUnchanged() {
        XCTAssertEqual(Chapters.make(from: markers), Chapters.make(from: markers, color: nil))
        XCTAssertEqual(Chapters.make(from: markers).count, 6)
    }

    func testUnsetAndUnknownColorsCountAsDefaultTeal() {
        let r = Chapters.make(from: markers, color: .teal)
        XCTAssertEqual(r.text, "0:00 イントロ\n0:20 余談\n2:30 未知", "未設定と未知の色は既定のティール")
        XCTAssertEqual(Chapters.colorCounts(markers), [.red: 3, .teal: 2, .blue: 1])
    }

    func testColorWithoutMarkersGivesEmptyResultAndWarning() {
        let r = Chapters.make(from: markers, color: .purple)
        XCTAssertEqual(r.count, 0); XCTAssertEqual(r.text, "")
        XCTAssertEqual(r.warnings, ["紫のマーカーがありません"])
    }

    func testIntroAndYouTubeWarningsStillApplyToTheFilteredList() {
        let r = Chapters.make(from: markers, color: .blue)
        XCTAssertEqual(r.text, "0:00 イントロ\n1:20 メモ")
        XCTAssertTrue(r.warnings.contains { $0.contains("3 つ以上") })
    }
}
