import XCTest
@testable import MovieCutCore

/// 2026-11-24 のバグ確認で見つけた不具合の回帰テスト(小さなもの)。
final class BugHuntFollowupsTests: XCTestCase {
    /// CSV のセル判定が Windows 改行(\r\n)を見落とさないこと。Swift の Character では
    /// "\r\n" が1文字になり、"\n" とも "\r" とも一致しないため引用符が付かず行が壊れていた。
    func testCSVCellQuotesCRLF() {
        XCTAssertEqual(ClipListingExport.csvCell("a\r\nb"), "\"a\r\nb\"")
        XCTAssertEqual(ClipListingExport.csvCell("a\nb"), "\"a\nb\"")
        XCTAssertEqual(ClipListingExport.csvCell("a,b"), "\"a,b\"")
        XCTAssertEqual(ClipListingExport.csvCell("abc"), "abc")
    }

    /// 連番の取り込みキャッシュ鍵で fps を整数に切り捨てないこと(29 と 29.97 が同じ鍵になり、
    /// 古い APNG が再利用されていた)。
    func testImageSequenceCacheKeyDistinguishesFractionalFPS() {
        let seq = ImageSequence(directory: "/nonexistent", prefix: "f_", suffix: "", ext: "png", digits: 4,
                                frames: [.init(path: "/nonexistent/f_0001.png", number: 1),
                                         .init(path: "/nonexistent/f_0002.png", number: 2)],
                                missingNumbers: [])
        XCTAssertNotEqual(ImageSequenceImporter.cacheKey(sequence: seq, fps: 29),
                          ImageSequenceImporter.cacheKey(sequence: seq, fps: 29.97))
        XCTAssertEqual(ImageSequenceImporter.cacheKey(sequence: seq, fps: 29.97),
                       ImageSequenceImporter.cacheKey(sequence: seq, fps: 29.97))
    }
}
